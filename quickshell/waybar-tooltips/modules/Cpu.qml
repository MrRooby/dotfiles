// custom/cpu: usage, clocks, load, package power and power profile.
//
// Read straight from the kernel, sampled once a second while the popup is
// open (the popup is created on open and destroyed on close):
//   usage    /proc/stat, the delta between two snapshots (idle + iowait)
//   clocks   /proc/cpuinfo, one read for every thread
//   load     /proc/loadavg, which also carries running/total tasks
//   power    amdgpu's hwmon PPT rail; on this APU it covers the whole
//            package, cores included (RAPL's energy_uj is root-only)
//   profile  power-profiles over D-Bus (tlp-pd); turbo is performance
//            plus the ryzen-limits flag, as in power-profile.sh

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs

Column {
	id: view

	property var d: null
	property var prevStat: null
	// the popup stays hidden until this is true (first sample is 250 ms in)
	readonly property bool ready: d !== null
	readonly property int threads: d ? d.threads.length : 0

	width: 350
	spacing: 7

	FileView { id: procStat; path: "/proc/stat"; blockLoading: true }
	FileView { id: procInfo; path: "/proc/cpuinfo"; blockLoading: true }
	FileView { id: procLoad; path: "/proc/loadavg"; blockLoading: true }
	FileView {
		id: turboFlag
		path: "/run/ryzen-limits/turbo"
		blockLoading: true
		printErrors: false
	}

	// amdgpu's hwmon number changes between boots. One FileView per
	// candidate: re-pointing a single one inside the same call keeps
	// returning the first file it read.
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
	FileView {
		id: power
		path: view.powerPath
		blockLoading: true
		printErrors: false
	}

	Component.onCompleted: {
		for (let i = 0; i < hwmons.count; i++) {
			if (hwmons.objectAt(i).text().trim() === "amdgpu") {
				powerPath = "/sys/class/hwmon/hwmon" + i + "/power1_input";
				break;
			}
		}
	}

	// false until there are two snapshots to compare
	function sample() {
		procStat.reload();
		const cur = {};
		for (const line of procStat.text().split("\n")) {
			if (!line.startsWith("cpu"))
				continue;
			const f = line.trim().split(/\s+/);
			const v = f.slice(1).map(Number);
			cur[f[0]] = [v.reduce((a, b) => a + b, 0), v[3] + v[4]];
		}
		const prev = prevStat;
		prevStat = cur;
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
		if (powerPath !== "") {
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

		d = {
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
		running: true
		repeat: true
		triggeredOnStart: true
		// the first call only takes a snapshot: take the second one soon
		// instead of a full second later
		onTriggered: if (!view.sample()) quickSample.restart()
	}
	Timer {
		id: quickSample
		interval: 250
		onTriggered: view.sample()
	}

	function ghz(khz) {
		return khz > 0 ? (khz / 1e6).toFixed(2) : "-";
	}

	// ---- view -------------------------------------------------------------

	// headline: total and power profile
	Item {
		width: parent.width
		implicitHeight: total.implicitHeight

		Label {
			id: total
			text: (view.d?.total ?? 0) + "%"
			color: Theme.ramp(view.d?.total ?? 0)
			font.pixelSize: Theme.headSize
			font.bold: true
		}

		// the active power profile, drawn like the active profile button in
		// the bar: inverted, in that profile's colour
		Chip {
			readonly property string profile: view.d?.profile ?? ""
			readonly property var info: ({
				"turbo":       { icon: "", label: "Turbo", key: "pp-turbo" },
				"performance": { icon: "", label: "Performance", key: "pp-performance" },
				"balanced":    { icon: "\u{f029a}", label: "Balanced", key: "pp-balanced" },
				"power-saver": { icon: "\u{f032a}", label: "Power saver", key: "pp-saver" }
			})[profile] ?? { icon: "\u{f0f85}", label: profile || "unknown", key: "" }

			visible: profile !== ""
			anchors.right: parent.right
			anchors.verticalCenter: total.verticalCenter
			icon: info.icon
			text: info.label
			tint: Theme.color(info.key, Theme.accent)
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

		Label { text: "Load"; color: Theme.dim }
		Label {
			font.bold: true
			text: view.d ? view.d.load.map(v => v.toFixed(2)).join("  ·  ") : "-"
		}
		Label { text: "Clock"; color: Theme.dim }
		Label {
			font.bold: true
			text: view.d ? view.ghz(view.d.avg_khz) + " GHz avg  ·  "
				+ view.ghz(view.d.max_khz) + " peak" : "-"
		}
		Label { text: "Package"; color: Theme.dim }
		Label {
			font.bold: true
			text: view.d?.watts != null ? view.d.watts.toFixed(1) + " W" : "n/a"
		}
		Label { text: "Tasks"; color: Theme.dim }
		Label {
			font.bold: true
			text: view.d ? view.d.running + " running of " + view.d.tasks : "-"
		}
	}

	Rule { width: parent.width }

	// threads, two columns: 0..7 left, 8..15 right
	Grid {
		width: parent.width
		rows: Math.ceil(view.threads / 2)
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
					color: Theme.dim
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
					color: Theme.ramp(cell.t.use)
				}
				Label {
					text: view.ghz(cell.t.khz)
					color: Theme.dim
				}
			}
		}
	}
}
