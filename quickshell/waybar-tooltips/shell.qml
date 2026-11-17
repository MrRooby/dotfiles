// Interactive tooltips for waybar modules.
//
//   qs -c waybar-tooltips
//
// Something tells this shell when the pointer enters and leaves a waybar
// module, over $XDG_RUNTIME_DIR/waybar-tooltips.sock, one line per event:
//
//   enter <module> <monitor-x> <monitor-y> <module-x> <module-width> <bar-height>
//       from the fast-tooltip shim preloaded into waybar
//       (waybar/tools/fast-tooltip.c), which hides the GTK tooltip
//   enter <module> [output-name]
//       from waybar's own on-enter (PR #5312), which gives no position, so
//       the popup centres under that output's bar
//   leave
//
// The popup opens straight under the bar and stays while the pointer is on
// the module or on the popup, so it can be read, selected and clicked.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower

ShellRoot {
	id: root

	readonly property string font: "JetBrainsMono Nerd Font Mono"

	// what the last enter reported
	property string module: ""
	property int monX: 0
	property int monY: 0
	property int modX: 0
	property int modW: 0

	property bool overModule: false
	property bool overPopup: false
	property bool open: false

	// Opening is instant; closing waits a few ms only so the pointer can
	// cross from waybar onto the popup (leave arrives before enter).
	onOverModuleChanged: sync()
	onOverPopupChanged: sync()
	function sync() {
		if (overModule || overPopup) {
			closeTimer.stop();
			open = true;
		} else {
			closeTimer.restart();
		}
	}
	Timer {
		id: closeTimer
		interval: 80
		onTriggered: root.open = root.overModule || root.overPopup
	}

	SocketServer {
		active: true
		path: Quickshell.env("XDG_RUNTIME_DIR") + "/waybar-tooltips.sock"
		handler: Socket {
			parser: SplitParser {
				onRead: line => {
					const p = line.trim().split(" ");
					if (p[0] === "enter" && p.length >= 6) {
						root.module = p[1];
						root.monX = +p[2];
						root.monY = +p[3];
						root.modX = +p[4];
						root.modW = +p[5];
						root.overModule = true;
					} else if (p[0] === "enter" && p.length >= 2) {
						const s = Quickshell.screens.find(s => s.name === p[2])
							?? Quickshell.screens[0];
						root.module = p[1];
						root.monX = s.x;
						root.monY = s.y;
						root.modX = s.width / 2;
						root.modW = 0;
						root.overModule = true;
					} else if (p[0] === "leave") {
						root.overModule = false;
					}
				}
			}
		}
	}

	// ---- theme ------------------------------------------------------------

	// waybar's palette: the @define-color lines of current-theme.css, with
	// @references followed until a hex falls out. Watched, so switching the
	// waybar theme recolours the popup as well.
	property var palette: ({})
	FileView {
		path: Quickshell.env("HOME") + "/.config/waybar/current-theme.css"
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			// (no String.matchAll in Qt's JS engine)
			const raw = {};
			const re = /@define-color\s+([\w-]+)\s+([^;]+);/g;
			const css = text();
			let m;
			while ((m = re.exec(css)) !== null)
				raw[m[1]] = m[2].trim();
			const out = {};
			for (const k in raw) {
				let v = raw[k];
				for (let i = 0; i < 10 && v && v.startsWith("@"); i++)
					v = raw[v.slice(1)];
				if (v && /^#[0-9a-fA-F]{3,8}$/.test(v))
					out[k] = v;
			}
			root.palette = out;
		}
	}
	function themed(key, fallback) {
		return palette[key] ?? fallback;
	}
	readonly property color bg: themed("tooltip-bg", "#11111b")
	readonly property color fg: themed("tooltip-fg", "#d8cab8")
	readonly property color dim: themed("tooltip-dim", "#9b9b9b")
	readonly property color ok: themed("tooltip-ok", "#57AE3A")
	readonly property color warm: themed("warning", "#f9e2af")
	readonly property color crit: themed("critical", "#f38ba8")
	readonly property color accent: themed("tooltip-br", "#CE6B29")

	// green while there is room, warm once it works, red when pegged; the
	// 75/90 lines are the ones states.css colours the bar module with
	function ramp(pct) {
		return pct >= 90 ? crit : pct >= 75 ? warm : ok;
	}

	// ---- data: custom-cpu -------------------------------------------------

	// Read straight from the kernel, sampled only while the popup is open:
	//   usage    /proc/stat, the delta between two snapshots (idle + iowait)
	//   clocks   /proc/cpuinfo, one read for every thread
	//   load     /proc/loadavg, which also carries running/total tasks
	//   power    amdgpu's hwmon PPT rail; on this APU it covers the whole
	//            package, cores included (RAPL's energy_uj is root-only)
	//   profile  power-profiles over D-Bus (tlp-pd); turbo is performance
	//            plus the ryzen-limits flag, as in power-profile.sh

	property var cpuData: null
	property var prevStat: null
	property real prevAt: 0

	FileView { id: procStat; path: "/proc/stat"; blockLoading: true }
	FileView { id: procInfo; path: "/proc/cpuinfo"; blockLoading: true }
	FileView { id: procLoad; path: "/proc/loadavg"; blockLoading: true }
	FileView {
		id: turboFlag
		path: "/run/ryzen-limits/turbo"
		blockLoading: true
		printErrors: false
	}

	// amdgpu's hwmon number changes between boots, so look it up once. One
	// FileView per candidate: re-pointing a single one inside the same call
	// keeps returning the first file it read.
	property string powerPath: ""
	Instantiator {
		id: hwmons
		model: 32
		delegate: FileView {
			required property int index
			path: "/sys/class/hwmon/hwmon" + index + "/name"
			blockLoading: true
			printErrors: false
		}
	}
	Component.onCompleted: {
		for (let i = 0; i < hwmons.count; i++) {
			if (hwmons.objectAt(i).text().trim() === "amdgpu") {
				powerPath = "/sys/class/hwmon/hwmon" + i + "/power1_input";
				break;
			}
		}
	}
	FileView {
		id: power
		path: root.powerPath
		blockLoading: true
		printErrors: false
	}

	// Returns false until there are two snapshots to compare. A snapshot
	// older than a few seconds is dropped rather than used: it would report
	// the average over the whole time the popup was closed.
	function sample() {
		const now = Date.now();
		procStat.reload();
		const cur = {};
		for (const line of procStat.text().split("\n")) {
			if (!line.startsWith("cpu"))
				continue;
			const f = line.trim().split(/\s+/);
			const v = f.slice(1).map(Number);
			cur[f[0]] = [v.reduce((a, b) => a + b, 0), v[3] + v[4]];
		}
		const prev = prevStat && now - prevAt < 3000 ? prevStat : null;
		prevStat = cur;
		prevAt = now;
		if (!prev)
			return false;

		const use = key => {
			if (!prev[key])
				return 0;
			const dt = cur[key][0] - prev[key][0];
			const di = cur[key][1] - prev[key][1];
			return dt > 0 ? Math.round(100 * (dt - di) / dt) : 0;
		};

		procInfo.reload();
		const khz = procInfo.text().split("\n")
			.filter(l => l.startsWith("cpu MHz"))
			.map(l => Math.round(parseFloat(l.split(":")[1]) * 1000));

		const threads = [];
		for (let n = 0; cur["cpu" + n]; n++)
			threads.push({ use: use("cpu" + n), khz: khz[n] ?? 0 });

		procLoad.reload();
		const la = procLoad.text().trim().split(/\s+/);
		const tasks = (la[3] ?? "0/0").split("/").map(Number);

		let watts = null;
		if (root.powerPath !== "") {
			power.reload();
			const uw = parseInt(power.text());
			if (uw > 0)
				watts = uw / 1e6;
		}

		const p = PowerProfiles.profile;
		let profile = p === PowerProfile.Performance ? "performance"
			: p === PowerProfile.Balanced ? "balanced"
			: p === PowerProfile.PowerSaver ? "power-saver" : "unknown";
		turboFlag.reload();
		turboFlag.text();
		if (profile === "performance" && turboFlag.loaded)
			profile = "turbo";

		cpuData = {
			total: use("cpu"),
			profile: profile,
			load: la.slice(0, 3).map(Number),
			running: tasks[0],
			tasks: tasks[1],
			avg_khz: khz.length ? khz.reduce((a, b) => a + b, 0) / khz.length : 0,
			max_khz: Math.max(0, ...khz),
			watts: watts,
			threads: threads
		};
		return true;
	}

	Timer {
		interval: 1000
		running: root.open && root.module === "custom-cpu"
		repeat: true
		triggeredOnStart: true
		// no fresh snapshot to compare against: take the second one soon
		// instead of a full second later
		onTriggered: if (!root.sample()) quickSample.restart()
	}
	Timer {
		id: quickSample
		interval: 250
		onTriggered: root.sample()
	}

	function ghz(khz) {
		return khz > 0 ? (khz / 1e6).toFixed(2) : "-";
	}

	// ---- building blocks --------------------------------------------------

	// a meter: dim trough, fill in the colour of the value it shows
	component Meter: Item {
		id: meter
		property real value: 0
		implicitHeight: 6
		Rectangle {
			anchors.fill: parent
			color: root.dim
			opacity: 0.18
		}
		Rectangle {
			height: parent.height
			width: parent.width * Math.max(0, Math.min(100, meter.value)) / 100
			color: root.ramp(meter.value)
			Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
			Behavior on color { ColorAnimation { duration: 250 } }
		}
	}

	component Rule: Rectangle {
		implicitHeight: 1
		color: root.dim
		opacity: 0.35
	}

	component Label: Text {
		color: root.fg
		font.family: root.font
		font.pixelSize: 13
	}

	// ---- view: custom-cpu -------------------------------------------------

	Component {
		id: cpuView

		Column {
			id: view
			readonly property var d: root.cpuData
			readonly property int threads: d ? d.threads.length : 0
			readonly property int rows: Math.ceil(threads / 2)
			width: 380
			spacing: 10

			// headline: total and power profile
			Item {
				width: parent.width
				implicitHeight: total.implicitHeight

				Label {
					id: total
					text: (view.d?.total ?? 0) + "%"
					color: root.ramp(view.d?.total ?? 0)
					font.pixelSize: 28
					font.bold: true
				}
				// the active power profile, drawn like the active profile
				// button in the bar: inverted, in that profile's colour
				Rectangle {
					readonly property string profile: view.d?.profile ?? ""
					readonly property var info: ({
						"turbo":       { icon: "\uf135", label: "Turbo" },
						"performance": { icon: "\uf0e7", label: "Performance" },
						"balanced":    { icon: "\u{f029a}", label: "Balanced" },
						"power-saver": { icon: "\u{f032a}", label: "Power saver" }
					})[profile] ?? { icon: "\u{f0f85}", label: profile || "unknown" }

					visible: profile !== ""
					anchors.right: parent.right
					anchors.verticalCenter: total.verticalCenter
					implicitWidth: chip.implicitWidth + 20
					implicitHeight: chip.implicitHeight + 8
					color: root.themed(({
						"turbo": "pp-turbo",
						"performance": "pp-performance",
						"balanced": "pp-balanced",
						"power-saver": "pp-saver"
					})[profile] ?? "", root.accent)
					Behavior on color { ColorAnimation { duration: 250 } }

					Row {
						id: chip
						anchors.centerIn: parent
						spacing: 8
						Label {
							text: parent.parent.info.icon
							color: root.bg
							font.pixelSize: 16
						}
						Label {
							text: parent.parent.info.label
							color: root.bg
							font.pixelSize: 15
							font.bold: true
						}
					}
				}
			}

			Meter {
				width: parent.width
				implicitHeight: 8
				value: view.d?.total ?? 0
			}

			Rule { width: parent.width }

			// package figures, dim label / bright value
			Grid {
				columns: 2
				columnSpacing: 16
				rowSpacing: 3

				Label { text: "Load"; color: root.dim }
				Label {
					font.bold: true
					text: view.d ? view.d.load.map(v => v.toFixed(2)).join("  ·  ") : "-"
				}
				Label { text: "Clock"; color: root.dim }
				Label {
					font.bold: true
					text: view.d ? root.ghz(view.d.avg_khz) + " GHz avg  ·  "
						+ root.ghz(view.d.max_khz) + " peak" : "-"
				}
				Label { text: "Package"; color: root.dim }
				Label {
					font.bold: true
					text: view.d?.watts != null ? view.d.watts.toFixed(1) + " W" : "n/a"
				}
				Label { text: "Tasks"; color: root.dim }
				Label {
					font.bold: true
					text: view.d ? view.d.running + " running of " + view.d.tasks : "-"
				}
			}

			Rule { width: parent.width }

			// threads, two columns: 0..7 left, 8..15 right
			Grid {
				width: parent.width
				rows: view.rows
				flow: Grid.TopToBottom
				columnSpacing: 22
				rowSpacing: 4

				Repeater {
					model: view.threads

					Row {
						id: cell
						required property int index
						readonly property var t: view.d.threads[index]
						spacing: 8

						Label {
							text: String(cell.index).padStart(2, "0")
							color: root.dim
						}
						Meter {
							width: 64
							anchors.verticalCenter: parent.verticalCenter
							value: cell.t.use
						}
						Label {
							width: 32
							horizontalAlignment: Text.AlignRight
							text: cell.t.use + "%"
							color: root.ramp(cell.t.use)
						}
						Label {
							text: root.ghz(cell.t.khz)
							color: root.dim
						}
					}
				}
			}
		}
	}

	readonly property Component view: module === "custom-cpu" && cpuData ? cpuView : null

	// ---- popup ------------------------------------------------------------

	Variants {
		model: Quickshell.screens

		PanelWindow {
			id: popup
			required property var modelData
			screen: modelData

			visible: root.open && root.view !== null
				&& modelData.x === root.monX && modelData.y === root.monY

			// top-left anchored, zone 0: the compositor puts it right under
			// waybar's exclusive zone; the margin centres it on the module
			anchors.top: true
			anchors.left: true
			exclusiveZone: 0
			margins.left: Math.max(0, Math.min(modelData.width - implicitWidth,
				root.modX + root.modW / 2 - implicitWidth / 2))
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.namespace: "waybar-tooltip"

			implicitWidth: box.implicitWidth
			implicitHeight: box.implicitHeight
			color: "transparent"

			Rectangle {
				id: box
				implicitWidth: content.implicitWidth + 28
				implicitHeight: content.implicitHeight + 24
				color: root.bg
				border.color: root.accent
				border.width: 2

				HoverHandler { onHoveredChanged: root.overPopup = hovered }

				Loader {
					id: content
					x: 14
					y: 12
					sourceComponent: root.view
				}
			}
		}
	}
}
