// custom/temperature: the CPU reading, then every temperature sensor the
// kernel exposes, grouped by chip, each drawn against its own limit.
//
// Mirrors scripts/temperature.sh, read straight from sysfs every 2 s while
// the popup is open:
//   chips    /sys/class/hwmon/hwmon*/{name,temp*_input,_label,_crit,_max},
//            device/model for NVMe; readings of exactly 0 are empty slots
//   zones    /sys/class/thermal/thermal_zone*/{type,temp,trip_point_0_temp},
//            only those no hwmon chip already mirrors
//   limits   the lowest sane crit/max the sensor declares (0 < v < 200 °C),
//            else the category fallback; NVMe "Composite" is dropped and
//            hands its limits to the drive's real sensors
//   dupes    the script measures which sensors mirror each other and keeps
//            the counts in $XDG_RUNTIME_DIR/waybar-temperature.state; this
//            reads that file (never writes it) and hides the same rows
// Colours go by the fraction of each sensor's own limit: red from 90 %,
// warm from 75 %.

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	property string align: "center"
	property var d: null
	readonly property bool ready: d !== null

	width: 370
	spacing: 7

	readonly property int maxHwmon: 32
	readonly property int maxZone: 16

	// ---- discovery ----------------------------------------------------------
	// One FileView per candidate file (re-pointing one inside a call keeps
	// returning the old file), in stages so that past the first only files
	// that exist get one: names, then inputs, then labels/limits.

	// stage 1: hwmon names and NVMe models, zone type/trip
	Instantiator {
		id: names
		model: view.maxHwmon
		delegate: FileView {
			required property int index
			path: "/sys/class/hwmon/hwmon" + index + "/name"
			blockLoading: true
			printErrors: false
		}
	}
	Instantiator {
		id: models
		model: view.maxHwmon
		delegate: FileView {
			required property int index
			path: "/sys/class/hwmon/hwmon" + index + "/device/model"
			blockLoading: true
			printErrors: false
		}
	}
	Instantiator {
		id: zoneTypes
		model: view.maxZone
		delegate: FileView {
			required property int index
			path: "/sys/class/thermal/thermal_zone" + index + "/type"
			blockLoading: true
			printErrors: false
		}
	}
	Instantiator {
		id: zoneTrips
		model: view.maxZone
		delegate: FileView {
			required property int index
			path: "/sys/class/thermal/thermal_zone" + index + "/trip_point_0_temp"
			blockLoading: true
			printErrors: false
		}
	}

	// Which temp*_input files exist and can be read: one grep when the popup
	// opens. Probing them with FileViews instead logs a warning that
	// printErrors does not silence for every slot the ThinkPad EC lists but
	// fails with ENXIO (temp8 here), and the temp numbers are not contiguous
	// (k10temp skips temp4), so the glob is the honest list.
	Process {
		running: true
		command: ["sh", "-c", "cd /sys/class/hwmon && grep -sl . hwmon*/temp*_input; true"]
		stdout: StdioCollector {
			onStreamFinished: view.discover(text)
		}
	}

	// stage 2: the readable temp*_input files, then zone temps
	property var inputPaths: []
	Instantiator {
		id: inputs
		model: view.inputPaths
		delegate: FileView {
			required property string modelData
			path: modelData
			blockLoading: true
			printErrors: false
		}
	}

	// stage 3: label, crit, max of every input (static)
	property var metaPaths: []
	Instantiator {
		id: metas
		model: view.metaPaths
		delegate: FileView {
			required property string modelData
			path: modelData
			blockLoading: true
			printErrors: false
		}
	}

	FileView {
		id: dupeState
		path: Quickshell.env("XDG_RUNTIME_DIR") + "/waybar-temperature.state"
		blockLoading: true
		printErrors: false
	}

	// sensors: static description of each candidate, in the script's order
	// (category, chip index, temp number); `slot` indexes `inputs`
	property var sensors: []

	function readInt(fv) {
		const t = fv.text().trim();
		return /^-?[0-9]+$/.test(t) ? parseInt(t) : null;
	}

	// category, heading detail and fallback limit (°C), as group_of() does
	function groupOf(name, model) {
		if (/^(coretemp|k10temp|zenpower|cpu_thermal)$/.test(name))
			return { prio: 1, cat: "CPU", detail: name, alert: 95 };
		if (/^(amdgpu|radeon|nouveau|nvidia|i915|xe|gpu_thermal)$/.test(name))
			return { prio: 2, cat: "GPU", detail: name, alert: 95 };
		if (name === "nvme")
			return { prio: 3, cat: "SSD", detail: model || "nvme", alert: 75 };
		if (name === "drivetemp")
			return { prio: 3, cat: "Disk", detail: "drivetemp", alert: 60 };
		if (/^(iwlwifi|mt76|rtw|brcm)|^ath.*k|^phy[0-9]/.test(name))
			return { prio: 4, cat: "Wi-Fi", detail: name, alert: 95 };
		if (/^acpitz/.test(name))
			return { prio: 6, cat: "ACPI zone", detail: name, alert: 90 };
		if (name === "thinkpad")
			return { prio: 7, cat: "ThinkPad EC", detail: "", alert: 90 };
		if (/^(BAT|bat)|battery/.test(name))
			return { prio: 8, cat: "Battery", detail: name, alert: 60 };
		return { prio: 5, cat: name, detail: "", alert: 90 };
	}

	function discover(listing) {
		const chips = {};
		const chipNames = {};
		for (let i = 0; i < view.maxHwmon; i++) {
			const name = names.objectAt(i).text().trim();
			if (name === "")
				continue;
			chipNames[name] = true;
			chips[i] = { idx: i, name: name, g: groupOf(name, models.objectAt(i).text().trim()) };
		}

		// "hwmon5/temp1_input" lines, in chip then temp order
		const found = [];
		for (const line of listing.split("\n")) {
			const m = /^hwmon([0-9]+)\/temp([0-9]+)_input$/.exec(line.trim());
			if (m && chips[m[1]])
				found.push({ c: chips[m[1]], n: parseInt(m[2]) });
		}
		found.sort((a, b) => a.c.idx - b.c.idx || a.n - b.n);

		const zones = [];
		for (let z = 0; z < view.maxZone; z++) {
			const type = zoneTypes.objectAt(z).text().trim();
			if (type === "")
				continue;
			// mirrored into hwmon under its type ('-' becomes '_' there)
			if (chipNames[type] || chipNames[type.replace(/-/g, "_")])
				continue;
			// a zone with no usable trip parks it below absolute zero
			let trip = readInt(zoneTrips.objectAt(z));
			if (trip !== null && !(trip > 0 && trip < 200000))
				trip = null;
			zones.push({ z: z, type: type, trip: trip });
		}

		const paths = [];
		const meta = [];
		for (const f of found) {
			const base = "/sys/class/hwmon/hwmon" + f.c.idx + "/temp" + f.n;
			paths.push(base + "_input");
			meta.push(base + "_label", base + "_crit", base + "_max");
		}
		for (const zn of zones)
			paths.push("/sys/class/thermal/thermal_zone" + zn.z + "/temp");
		inputPaths = paths;
		metaPaths = meta;

		// the lowest limit declared: a warning sits below its critical and
		// is the point worth acting on; absurd parked values are ignored
		const list = [];
		found.forEach((f, k) => {
			const label = metas.objectAt(3 * k).text().trim();
			let limit = null;
			for (const off of [1, 2]) {
				const v = readInt(metas.objectAt(3 * k + off));
				if (v === null || !(v > 0 && v < 200000))
					continue;
				if (limit === null || v < limit)
					limit = v;
			}
			list.push({
				prio: f.c.g.prio, chip: f.c.idx, cat: f.c.g.cat, detail: f.c.g.detail,
				group: f.c.g.cat + "|" + f.c.g.detail,
				label: label || "temp" + f.n, labelled: label !== "",
				limit: limit, alert: f.c.g.alert,
				key: f.c.name.replace(/ /g, "_") + ":temp" + f.n,
				slot: k
			});
		});
		zones.forEach((zn, k) => {
			list.push({
				prio: 6, chip: 99, cat: "Thermal zone", detail: zn.type,
				group: "Thermal zone|" + zn.type,
				label: "thermal_zone" + zn.z, labelled: false,
				limit: zn.trip, alert: 90,
				key: "zone:" + zn.type.replace(/ /g, "_"),
				slot: found.length + k
			});
		});
		// category, then chip, then temp number, as the script sorts
		list.sort((a, b) => a.prio - b.prio || a.chip - b.chip || a.slot - b.slot);
		sensors = list;

		sample();
		poll.running = true;
	}

	// ---- one poll -----------------------------------------------------------

	function sample() {
		const rows = [];
		for (const s of sensors) {
			const fv = inputs.objectAt(s.slot);
			fv.reload();
			const m = readInt(fv);
			if (m === null || m === 0)
				continue;
			rows.push(Object.assign({}, s, { milli: m }));
		}
		if (rows.length === 0) {
			d = { rows: [], groups: [] };
			return;
		}

		const dupe = rows.map(() => false);

		// Composite is computed, not measured: drop it, pass its limits on
		rows.forEach((r, i) => {
			if (r.label !== "Composite")
				return;
			dupe[i] = true;
			if (r.limit === null)
				return;
			for (const o of rows)
				if (o.group === r.group && o.limit === null)
					o.limit = r.limit;
		});

		// pairs the script has seen agree often enough to be one sensor
		const hits = {};
		dupeState.reload();
		for (const line of dupeState.text().split("\n")) {
			const f = line.trim().split(/\s+/);
			if (f.length === 4 && /^[0-9]+$/.test(f[2]) && /^[0-9]+$/.test(f[3]))
				hits[f[0] + " " + f[1]] = [parseInt(f[2]), parseInt(f[3])];
		}
		const survives = (a, b) => {
			if (a.labelled !== b.labelled)
				return a.labelled;
			if ((a.limit !== null) !== (b.limit !== null))
				return a.limit !== null;
			return a.prio <= b.prio;
		};
		for (let i = 0; i < rows.length; i++) {
			for (let j = i + 1; j < rows.length; j++) {
				const hm = hits[rows[i].key + " " + rows[j].key]
					?? hits[rows[j].key + " " + rows[i].key];
				if (!hm || hm[0] < 30 || hm[1] * 5 > hm[0])
					continue;
				if (dupe[i] || dupe[j])
					continue;
				const keepI = survives(rows[i], rows[j]);
				const w = keepI ? rows[i] : rows[j];
				const l = keepI ? rows[j] : rows[i];
				dupe[keepI ? j : i] = true;
				if (w.limit === null)
					w.limit = l.limit;
			}
		}

		const keep = rows.filter((r, i) => !dupe[i]);
		for (const r of keep) {
			r.thr = r.limit ?? r.alert * 1000;
			r.pct = Math.max(0, Math.min(100, 100 * r.milli / r.thr));
			r.over = r.milli >= r.thr;
			r.hot = false;
		}

		let hot = keep[0];
		for (const r of keep)
			if (r.milli > hot.milli)
				hot = r;
		hot.hot = true;

		// the bar's reading: die/package sensor, any CPU chip, the EC's CPU,
		// a zone, else the hottest
		let cpu = null;
		for (const want of ["Tdie", "Tctl", "Package id 0"]) {
			cpu = keep.find(r => r.cat === "CPU" && r.label === want) ?? null;
			if (cpu)
				break;
		}
		cpu = cpu ?? keep.find(r => r.cat === "CPU")
			?? keep.find(r => r.cat === "ThinkPad EC" && r.label === "CPU")
			?? keep.find(r => r.cat === "ACPI zone" || r.cat === "Thermal zone")
			?? hot;

		// group blocks, with the limit shown once if all rows agree on it
		const groups = [];
		for (const r of keep) {
			let g = groups.length ? groups[groups.length - 1] : null;
			if (!g || g.key !== r.group) {
				g = { key: r.group, cat: r.cat, detail: r.detail, limit: undefined, rows: [] };
				groups.push(g);
			}
			const lim = Math.round(r.thr / 1000);
			g.limit = g.limit === undefined || g.limit === lim ? lim : null;
			g.rows.push(r);
		}

		d = { cpu: cpu, groups: groups };
	}

	Timer {
		id: poll
		interval: 2000
		repeat: true
		onTriggered: view.sample()
	}

	// milli-degrees to "50.2", rounded as the script does
	function deg(m) {
		const neg = m < 0;
		const t = Math.floor((Math.abs(m) + 50) / 100);
		return (neg ? "-" : "") + Math.floor(t / 10) + "." + (t % 10);
	}

	// widest sensor label, so the value column lines up across groups
	TextMetrics {
		id: labelMetrics
		font.family: Theme.font
		font.pixelSize: Theme.fontSize
		text: {
			let w = "";
			for (const g of view.d?.groups ?? [])
				for (const r of g.rows)
					if (r.label.length > w.length)
						w = r.label;
			return w;
		}
	}

	// ---- view ---------------------------------------------------------------

	Label {
		visible: view.d !== null && !view.d.cpu
		text: "no temperature sensors found"
		color: Theme.dim
	}

	// headline: CPU reading and where it comes from
	Item {
		visible: !!view.d?.cpu
		width: parent.width
		implicitHeight: head.implicitHeight

		Label {
			id: head
			text: view.d?.cpu ? view.deg(view.d.cpu.milli) + " °C" : "-"
			color: Theme.ramp(view.d?.cpu?.pct ?? 0)
			font.pixelSize: Theme.headSize
			font.bold: true
		}
		Label {
			anchors.right: parent.right
			anchors.verticalCenter: head.verticalCenter
			text: view.d?.cpu?.cat ?? ""
			color: Theme.accent
			font.pixelSize: Theme.chipSize
			font.bold: true
		}
	}

	Meter {
		visible: !!view.d?.cpu
		width: parent.width
		implicitHeight: 8
		value: view.d?.cpu?.pct ?? 0
	}

	Rule {
		visible: !!view.d?.cpu
		width: parent.width
	}

	// counts as models, so a poll updates the rows in place rather than
	// rebuilding them
	Repeater {
		model: view.d?.groups?.length ?? 0

		Column {
			id: block
			required property int index
			readonly property var modelData: view.d.groups[index] ?? { cat: "", detail: "", limit: null, rows: [] }
			width: view.width
			spacing: 3

			// heading: category in accent, chip/model dim, limit right
			Item {
				width: parent.width
				implicitHeight: cat.implicitHeight

				Row {
					Label {
						id: cat
						text: block.modelData.cat
						color: Theme.accent
						font.bold: true
					}
					Label {
						visible: block.modelData.detail !== ""
						text: "  ·  " + block.modelData.detail
						color: Theme.dim
					}
				}
				Label {
					visible: block.modelData.limit !== null
					anchors.right: parent.right
					text: "limit " + block.modelData.limit + " °C"
					color: Theme.dim
				}
			}

			Repeater {
				model: block.modelData.rows.length

				Row {
					id: row
					required property int index
					readonly property var modelData: block.modelData.rows[index] ?? { label: "", milli: 0, pct: 0, over: false, hot: false }
					x: 12
					spacing: 12

					Label {
						width: labelMetrics.advanceWidth
						text: row.modelData.label
						color: Theme.dim
					}
					Label {
						width: 70
						horizontalAlignment: Text.AlignRight
						text: view.deg(row.modelData.milli) + " °C"
						color: Theme.ramp(row.modelData.pct)
						font.bold: true
					}
					Meter {
						width: view.width - 12 - labelMetrics.advanceWidth - 70 - 14 - 3 * 12
						anchors.verticalCenter: parent.verticalCenter
						value: row.modelData.pct
					}
					// ! at or past the limit, ▲ on the hottest sensor
					Label {
						width: 14
						text: row.modelData.over ? "!" : row.modelData.hot ? "▲" : ""
						color: row.modelData.over ? Theme.crit : Theme.accent
						font.bold: true
					}
				}
			}
		}
	}
}
