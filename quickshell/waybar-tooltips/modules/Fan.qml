// custom/fan: ThinkPad fan speed, the level it runs at, the temperature the
// controller watches, and thinkfan's curve with the active step marked.
//
// Read straight from the kernel every 2 s while the popup is open, the same
// sources as fan.sh:
//   speed     thinkpad_acpi's hwmon fan1_input / fan2_input (hwmon found by
//             name), /proc/acpi/ibm/fan's "speed:" as a fallback
//   level     /proc/acpi/ibm/fan, "level:"
//   curve     /etc/thinkfan.conf: sensor name, indices and the
//             [level, lower, upper] triples; 255 means no upper limit
//   temp      the sensor thinkfan.conf names, else k10temp / coretemp /
//             thinkpad temp1_input
//   control   thinkfan if /run/thinkfan.pid points at a live "thinkfan",
//             firmware if the level is auto, manual otherwise
//   profile   /sys/firmware/acpi/platform_profile

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	property var d: null
	readonly property bool ready: d !== null
	property string align: "center"

	width: 370
	spacing: 7

	// ---- sources ----------------------------------------------------------

	FileView { id: procFan; path: "/proc/acpi/ibm/fan"; blockLoading: true; printErrors: false }
	FileView { id: conf; path: "/etc/thinkfan.conf"; blockLoading: true; printErrors: false }
	FileView { id: profileFile; path: "/sys/firmware/acpi/platform_profile"; blockLoading: true; printErrors: false }
	FileView { id: pidFile; path: "/run/thinkfan.pid"; blockLoading: true; printErrors: false }

	// hwmon numbers change between boots: one FileView per candidate name
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

	// paths are only known after the lookups above; a FileView re-pointed
	// within one JS call still returns the old file, so they are set in
	// onCompleted / one poll ahead and read on a later one
	property string fan1Path: ""
	property string fan2Path: ""
	property string tempPath: ""
	property string pid: ""
	FileView { id: fan1; path: view.fan1Path; blockLoading: true; printErrors: false }
	FileView { id: fan2; path: view.fan2Path; blockLoading: true; printErrors: false }
	FileView { id: tempFile; path: view.tempPath; blockLoading: true; printErrors: false }
	FileView {
		id: commFile
		path: view.pid !== "" ? "/proc/" + view.pid + "/comm" : ""
		blockLoading: true
		printErrors: false
	}

	property var curve: ({ name: "", idx: 1, levels: [] })

	function read(fv) {
		if (fv.path === "")
			return "";
		fv.reload();
		const t = fv.text();
		return fv.loaded ? t.trim() : "";
	}

	// fan.sh's regexes, line by line with comments stripped
	function parseConf(text) {
		const out = { name: "", idx: 1, levels: [] };
		for (let line of text.split("\n")) {
			line = line.split("#")[0];
			let m;
			if ((m = /name:\s*([A-Za-z0-9_]+)/.exec(line)) && out.name === "") {
				out.name = m[1];
			} else if ((m = /indices:\s*\[\s*([0-9]+)/.exec(line))) {
				out.idx = parseInt(m[1]);
			} else if ((m = /[\[(]\s*"?([^,"]+)"?\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*[\])]/.exec(line))) {
				let l = m[1];
				if (l.startsWith("level "))
					l = l.slice(6);
				l = l.replace(/ +$/, "");
				out.levels.push({ lvl: l, lo: parseInt(m[2]), hi: parseInt(m[3]) });
			}
		}
		return out;
	}

	function readPid() {
		const p = read(pidFile);
		return /^[0-9]+$/.test(p) ? p : "";
	}

	Component.onCompleted: {
		curve = parseConf(read(conf));

		const names = [];
		for (let i = 0; i < hwmons.count; i++)
			names.push(hwmons.objectAt(i).text().trim());
		const dir = i => "/sys/class/hwmon/hwmon" + i + "/";

		const tp = names.indexOf("thinkpad");
		if (tp >= 0) {
			fan1Path = dir(tp) + "fan1_input";
			fan2Path = dir(tp) + "fan2_input";
		}
		for (const want of [curve.name, "k10temp", "coretemp", "thinkpad"]) {
			if (want === "")
				continue;
			const i = names.indexOf(want);
			if (i < 0)
				continue;
			tempPath = dir(i) + "temp" + (want === curve.name ? curve.idx : 1) + "_input";
			break;
		}
		pid = readPid();
		kick.start();
	}

	function levelName(l) {
		return l === "auto" ? "Auto"
			: l === "full-speed" ? "Full speed"
			: l === "disengaged" ? "Disengaged"
			: l === "" ? "" : "Level " + l;
	}

	function poll() {
		// thinkfan's pid moved: re-point comm and read it on the next pass
		const p = readPid();
		if (p !== pid) {
			pid = p;
			kick.start();
			return;
		}

		let rpm = read(fan1);
		const rpm2 = parseInt(read(fan2)) || 0;
		let level = "";
		for (const line of read(procFan).split("\n")) {
			const f = line.trim().split(/\s+/);
			if (f[0] === "speed:" && rpm === "")
				rpm = f[1] ?? "";
			else if (f[0] === "level:")
				level = f[1] ?? "";
		}

		const t = parseInt(read(tempFile));
		const temp = isNaN(t) ? null : Math.trunc(t / 1000);

		const control = pid !== "" && read(commFile) === "thinkfan" ? "thinkfan"
			: level === "auto" ? "firmware" : "manual";

		const cur = curve.levels.findIndex(s => s.lvl === level);

		d = {
			rpm: parseInt(rpm) || 0,
			rpm2: rpm2,
			level: level,
			temp: temp,
			control: control,
			profile: read(profileFile),
			cur: cur
		};
	}

	Timer {
		id: kick
		interval: 10
		onTriggered: view.poll()
	}
	Timer {
		interval: 2000
		running: true
		repeat: true
		onTriggered: view.poll()
	}

	readonly property var step: d && d.cur >= 0 ? curve.levels[d.cur] : null
	readonly property bool showCurve: d !== null && d.control === "thinkfan" && curve.levels.length > 0

	// ---- view -------------------------------------------------------------

	// headline: speed, and the level in the accent
	Item {
		width: parent.width
		implicitHeight: speed.implicitHeight

		Row {
			id: speed
			spacing: 6
			Label {
				id: rpmText
				text: view.d?.rpm ?? 0
				font.pixelSize: Theme.headSize
				font.bold: true
			}
			Label {
				anchors.baseline: rpmText.baseline
				text: "RPM"
				color: Theme.dim
				font.pixelSize: Theme.chipSize
				font.bold: true
			}
		}

		Chip {
			visible: (view.d?.level ?? "") !== ""
			anchors.right: parent.right
			anchors.verticalCenter: speed.verticalCenter
			icon: "\u{efa7}"
			text: view.levelName(view.d?.level ?? "")
			tint: Theme.accent
		}
	}

	Rule { width: parent.width }

	Grid {
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "CPU"; color: Theme.dim; visible: view.d?.temp != null }
		Label {
			visible: view.d?.temp != null
			font.bold: true
			text: (view.d?.temp ?? "-") + " °C"
		}
		// the upper bound of a step is where the fan speeds up, the lower
		// bound where it slows down again
		Label { text: "Speeds up at"; color: Theme.dim; visible: view.step !== null && view.step.hi < 255 }
		Label {
			visible: view.step !== null && view.step.hi < 255
			font.bold: true
			text: (view.step?.hi ?? "") + " °C"
		}
		Label { text: "Slows down at"; color: Theme.dim; visible: view.step !== null && view.step.lo > 0 }
		Label {
			visible: view.step !== null && view.step.lo > 0
			font.bold: true
			text: (view.step?.lo ?? "") + " °C"
		}
		Label { text: "Second fan"; color: Theme.dim; visible: (view.d?.rpm2 ?? 0) > 0 }
		Label {
			visible: (view.d?.rpm2 ?? 0) > 0
			font.bold: true
			text: (view.d?.rpm2 ?? 0) + " RPM"
		}
		Label { text: "Control"; color: Theme.dim }
		Label { font.bold: true; text: view.d?.control ?? "-" }
		Label { text: "Profile"; color: Theme.dim; visible: (view.d?.profile ?? "") !== "" }
		Label {
			visible: (view.d?.profile ?? "") !== ""
			font.bold: true
			text: view.d?.profile ?? ""
		}
	}

	Rule { width: parent.width; visible: view.showCurve }

	// thinkfan's curve: one bar per step over a shared temperature axis, the
	// overlap between neighbours is the hysteresis; the line is the current
	// temperature, the accent row the active step
	Item {
		id: chart
		visible: view.showCurve
		width: parent.width
		implicitHeight: steps.implicitHeight + axis.height + 4

		readonly property int nameW: 84
		readonly property int rangeW: 96
		readonly property int gap: 10
		readonly property real trackX: nameW + gap
		readonly property real trackW: width - nameW - rangeW - 2 * gap

		// axis span: the finite bounds (0 and 255 are open ends) and the
		// current temperature, padded and rounded to 10 °C
		readonly property var span: {
			const v = [];
			for (const s of view.curve.levels) {
				if (s.lo > 0) v.push(s.lo);
				if (s.hi < 255) v.push(s.hi);
			}
			if (view.d?.temp != null) v.push(view.d.temp);
			if (v.length === 0) return [0, 100];
			const lo = Math.floor((Math.min(...v) - 5) / 10) * 10;
			const hi = Math.ceil((Math.max(...v) + 5) / 10) * 10;
			return [lo, Math.max(hi, lo + 10)];
		}
		function xOf(t) {
			const f = (t - span[0]) / (span[1] - span[0]);
			return trackX + trackW * Math.max(0, Math.min(1, f));
		}

		Column {
			id: steps
			width: parent.width
			spacing: 3

			Repeater {
				model: view.curve.levels

				Item {
					id: stepRow
					required property var modelData
					required property int index
					readonly property bool hot: index === (view.d?.cur ?? -1)
					readonly property var s: modelData

					width: steps.width
					implicitHeight: name.implicitHeight

					Label {
						id: name
						width: chart.nameW
						text: view.levelName(stepRow.s.lvl)
						color: stepRow.hot ? Theme.accent : Theme.dim
						font.bold: stepRow.hot
					}
					Rectangle {
						x: chart.trackX
						width: chart.trackW
						height: 6
						anchors.verticalCenter: name.verticalCenter
						color: Theme.dim
						opacity: 0.12
					}
					Rectangle {
						readonly property real x0: stepRow.s.lo <= 0 ? chart.trackX : chart.xOf(stepRow.s.lo)
						readonly property real x1: stepRow.s.hi >= 255 ? chart.trackX + chart.trackW : chart.xOf(stepRow.s.hi)
						x: x0
						width: Math.max(2, x1 - x0)
						height: 6
						anchors.verticalCenter: name.verticalCenter
						color: stepRow.hot ? Theme.accent : Theme.dim
						opacity: stepRow.hot ? 1 : 0.55
					}
					Label {
						anchors.right: parent.right
						width: chart.rangeW
						horizontalAlignment: Text.AlignRight
						text: stepRow.s.hi >= 255 ? stepRow.s.lo + " °C +"
							: stepRow.s.lo <= 0 ? "up to " + stepRow.s.hi + " °C"
							: stepRow.s.lo + " – " + stepRow.s.hi + " °C"
						color: stepRow.hot ? Theme.accent : Theme.fg
						font.bold: true
					}
				}
			}
		}

		// current temperature
		Rectangle {
			visible: view.d?.temp != null
			x: chart.xOf(view.d?.temp ?? 0) - 1
			y: -2
			width: 2
			height: steps.height + 4
			color: Theme.fg
			Behavior on x { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
		}

		// 10 °C ticks under the tracks
		Item {
			id: axis
			y: steps.height + 4
			width: parent.width
			height: 14

			Repeater {
				model: Math.round((chart.span[1] - chart.span[0]) / 10) + 1

				Text {
					required property int index
					readonly property int t: chart.span[0] + index * 10
					x: chart.xOf(t) - implicitWidth / 2
					text: t + "°"
					color: Theme.dim
					font.family: Theme.font
					font.pixelSize: Theme.fontSize - 2
				}
			}
		}
	}
}
