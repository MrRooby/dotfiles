// custom/battery: charge, power flow, charger, battery wear, power profile.
//
// The same sysfs reads as scripts/battery.sh, polled every 3 s while the
// popup is open (these files go through the ACPI EC, so not faster):
//   battery  /sys/class/power_supply/<bat>: the first type=Battery supply
//            that is not scope=Device, BAT* preferred, as in the script.
//            Energy-based (µWh/µW) or charge-based (µAh/µA × voltage_now).
//   power    smoothed like the bar: EMA with alpha 1/3, seeded from the
//            script's $XDG_RUNTIME_DIR/waybar-battery.state ("status mW")
//            and dropped whenever the status changes
//   charger  an online USB supply (usb_type's [bracketed] mode) rated at the
//            largest fixed-supply PDO of the attached partner, else an
//            online Mains supply as "AC"
//   profile  power-profiles over D-Bus (tlp-pd); turbo is performance plus
//            the ryzen-limits flag, as in power-profile.sh
//
// FileView cannot list a directory, so the supplies to probe are a fixed
// list of the usual names plus whatever UPower knows by native path (that is
// where unpredictable names like ucsi-source-psy-USBC000:001 come from).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs

Column {
	id: view

	property var d: null
	// the popup stays hidden until the first sample is in (a few ms)
	readonly property bool ready: d !== null
	property string align: "right"

	width: 350
	spacing: 7

	readonly property int warnAt: 20
	readonly property int critAt: 10

	// ---- sources ------------------------------------------------------------

	readonly property string psy: "/sys/class/power_supply/"

	// candidate supply names, in the glob's (byte) order
	readonly property var names: {
		const s = new Set(["AC", "AC0", "ACAD", "ADP0", "ADP1", "BAT", "BAT0",
			"BAT1", "BAT2", "BAT3", "CMB0"]);
		for (const dev of UPower.devices.values) {
			const n = dev.nativePath;
			if (n && n.indexOf("/") < 0)
				s.add(n);
		}
		return Array.from(s).sort();
	}

	// one set of FileViews per candidate (re-pointing one FileView inside a
	// call keeps returning the file it read first)
	Instantiator {
		id: probe
		model: view.names
		delegate: QtObject {
			required property string modelData
			readonly property string name: modelData
			readonly property FileView type: FileView {
				path: view.psy + modelData + "/type"
				blockLoading: true
				printErrors: false
			}
			readonly property FileView scope: FileView {
				path: view.psy + modelData + "/scope"
				blockLoading: true
				printErrors: false
			}
			readonly property FileView online: FileView {
				path: view.psy + modelData + "/online"
				blockLoading: true
				printErrors: false
			}
			readonly property FileView usbType: FileView {
				path: view.psy + modelData + "/usb_type"
				blockLoading: true
				printErrors: false
			}
		}
	}

	// the chosen battery's files, created once it is known
	property string bat: ""
	readonly property var batKeys: ["status", "capacity", "energy_now",
		"energy_full", "energy_full_design", "power_now", "charge_now",
		"charge_full", "charge_full_design", "voltage_now", "current_now",
		"charge_control_end_threshold", "cycle_count"]
	Instantiator {
		id: batFiles
		model: view.bat !== "" ? view.batKeys.map(k => view.psy + view.bat + "/" + k) : []
		delegate: FileView {
			required property string modelData
			path: modelData
			blockLoading: true
			printErrors: false
		}
	}

	// the attached partner's source PDOs. pd0/pd1 are the laptop's own ports
	// (what it can source); the partner's object is linked from its typec
	// device, which stands in for the script's readlink on pd*/device.
	readonly property int pdoMax: 7
	Instantiator {
		id: pdos
		model: {
			const out = [];
			for (let port = 0; port < 4; port++)
				for (let n = 1; n <= view.pdoMax; n++)
					for (const f of ["voltage", "maximum_current"])
						out.push("/sys/class/typec/port" + port
							+ "-partner/usb_power_delivery/source-capabilities/"
							+ n + ":fixed_supply/" + f);
			return out;
		}
		delegate: FileView {
			required property string modelData
			path: modelData
			blockLoading: true
			printErrors: false
		}
	}

	FileView {
		id: smoothState
		path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/waybar-battery.state"
		blockLoading: true
		printErrors: false
	}
	FileView {
		id: turboFlag
		path: "/run/ryzen-limits/turbo"
		blockLoading: true
		printErrors: false
	}

	// ---- sampling -----------------------------------------------------------

	// one sysfs value: absent, unreadable and empty all come back null
	function slurp(fv) {
		if (!fv)
			return null;
		fv.reload();
		const t = fv.text().split("\n")[0].trim();
		return fv.loaded && t !== "" ? t : null;
	}
	function slurpInt(fv) {
		const v = slurp(fv);
		return v !== null && /^-?[0-9]+$/.test(v) ? parseInt(v) : null;
	}

	// own EMA, carried between polls while the popup is open
	property string emaStatus: ""
	property int emaMw: -1

	function findBattery() {
		let found = "";
		for (let i = 0; i < probe.count; i++) {
			const p = probe.objectAt(i);
			if (!p || slurp(p.type) !== "Battery" || slurp(p.scope) === "Device")
				continue;
			found = p.name;
			if (found.startsWith("BAT"))
				break;
		}
		return found;
	}

	function charger() {
		let attached = false;
		let mode = "";
		for (let i = 0; i < probe.count; i++) {
			const p = probe.objectAt(i);
			if (!p || slurp(p.type) !== "USB" || slurp(p.online) !== "1")
				continue;
			attached = true;
			// "C [PD] PD_PPS": the bracketed token is the mode in force
			const m = /\[([^\]]*)\]/.exec(slurp(p.usbType) ?? "");
			if (m)
				mode = m[1];
			break;
		}

		if (attached) {
			let watts = 0;
			const per = view.pdoMax * 2;
			for (let port = 0; port < 4; port++) {
				let any = false;
				for (let n = 0; n < view.pdoMax; n++) {
					const base = port * per + n * 2;
					const mv = parseInt(slurp(pdos.objectAt(base)) ?? "");
					const ma = parseInt(slurp(pdos.objectAt(base + 1)) ?? "");
					if (!(mv >= 0) || !(ma >= 0))
						continue;
					any = true;
					watts = Math.max(watts, Math.floor((mv * ma + 500000) / 1e6));
				}
				if (any)
					break;
			}
			if (mode === "C")
				mode = "USB-C";
			// attached but no PDO list exposed: say so rather than invent
			return watts > 0 ? watts + "W" + (mode ? " " + mode : "") : (mode || "USB");
		}

		for (let i = 0; i < probe.count; i++) {
			const p = probe.objectAt(i);
			if (p && slurp(p.type) === "Mains" && slurp(p.online) === "1")
				return "AC";
		}
		return "";
	}

	// false when it has to come back in a moment (battery files just made)
	function sample() {
		if (bat === "") {
			const found = findBattery();
			if (found === "") {
				d = { missing: true };
				return true;
			}
			bat = found;
			return false;
		}
		if (batFiles.count !== batKeys.length)
			return false;

		const f = {};
		batKeys.forEach((k, i) => f[k] = batFiles.objectAt(i));

		const status = slurp(f.status) ?? "Unknown";
		const capacity = Math.max(0, Math.min(100, slurpInt(f.capacity) ?? 0));

		// milliwatt-hours and milliwatts, truncated where the script truncates
		let now = null, full = null, design = null, mw = null;
		const e = slurpInt(f.energy_now);
		if (e !== null) {
			now = Math.trunc(e / 1000);
			const ef = slurpInt(f.energy_full);
			if (ef !== null) full = Math.trunc(ef / 1000);
			const ed = slurpInt(f.energy_full_design);
			if (ed !== null) design = Math.trunc(ed / 1000);
			const p = slurpInt(f.power_now);
			if (p !== null) mw = Math.trunc(Math.abs(p) / 1000);
		} else {
			const c = slurpInt(f.charge_now);
			const uv = slurpInt(f.voltage_now) ?? 0;
			if (c !== null && uv > 0) {
				const wh = x => Math.trunc(Math.trunc(x / 1000) * uv / 1e6);
				now = wh(c);
				const cf = slurpInt(f.charge_full);
				if (cf !== null) full = wh(cf);
				const cd = slurpInt(f.charge_full_design);
				if (cd !== null) design = wh(cd);
				const i = slurpInt(f.current_now);
				if (i !== null) mw = wh(Math.abs(i));
			}
		}

		// EMA, alpha 1/3. The first poll continues the bar's average; a
		// status change drops it so charging never bleeds into discharging.
		if (mw !== null) {
			let prevStatus = emaStatus, prevMw = emaMw;
			if (prevStatus === "") {
				const st = (slurp(smoothState) ?? "").match(/^(.*) ([0-9]+)$/);
				if (st) {
					prevStatus = st[1];
					prevMw = parseInt(st[2]);
				}
			}
			if (prevStatus === status && prevMw >= 0)
				mw = Math.trunc((prevMw * 2 + mw + 1) / 3);
			emaStatus = status;
			emaMw = mw;
		}

		// the charge-stop threshold is the real ceiling when set
		let limit = slurpInt(f.charge_control_end_threshold) ?? 100;
		if (limit <= 0 || limit > 100)
			limit = 100;

		const hm = min => Math.floor(min / 60) + "h " + (min % 60) + "min";

		// live readings, withheld at Full; under Unknown only the time is.
		// Both lists run label, value, label, value for the 2-column grids.
		const live = [];
		if (mw !== null && mw > 0 && status !== "Full") {
			live.push("Power", (mw / 1000).toFixed(1) + " W");
			if (full !== null && full > 0) {
				live.push("Rate", (100 * mw / full).toFixed(1) + " %/h");
				if (status === "Charging") {
					const target = Math.trunc(full * limit / 100);
					if (now < target)
						live.push("Full in", hm(Math.trunc((target - now) * 60 / mw)));
				} else if (status === "Discharging") {
					live.push("Empty in", hm(Math.trunc(now * 60 / mw)));
				}
			}
		}

		// figures that move over weeks
		const fixed = [];
		const ch = charger();
		if (ch !== "")
			fixed.push("Charger", ch);
		if (limit < 100)
			fixed.push("Limit", limit + "%");
		if (full !== null && design !== null && design > 0)
			fixed.push("Health", Math.floor((100 * full + Math.trunc(design / 2)) / design) + "%");
		const cycles = slurpInt(f.cycle_count);
		if (cycles !== null && cycles > 0)
			fixed.push("Cycles", String(cycles));

		d = {
			missing: false,
			status: status,
			capacity: capacity,
			limit: limit,
			live: live,
			fixed: fixed
		};
		return true;
	}

	Timer {
		interval: 3000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!view.sample()) quickSample.restart()
	}
	Timer {
		id: quickSample
		interval: 30
		onTriggered: if (!view.sample()) restart()
	}

	// ---- power profile ------------------------------------------------------

	property string actualProfile: ""
	// the button just clicked, shown as active until the switch lands
	property string pendingProfile: ""
	readonly property string profile: pendingProfile || actualProfile

	function readProfile() {
		const p = PowerProfiles.profile;
		let name = p === PowerProfile.Performance ? "performance"
			: p === PowerProfile.Balanced ? "balanced"
			: p === PowerProfile.PowerSaver ? "power-saver" : "";
		turboFlag.reload();
		turboFlag.text();
		if (name === "performance" && turboFlag.loaded)
			name = "turbo";
		actualProfile = name;
		if (pendingProfile === name)
			pendingProfile = "";
	}

	function setProfile(name) {
		if (name === profile)
			return;
		pendingProfile = name;
		pendingTimeout.restart();
		// the script switches, waits for tlp-pd to publish the new profile,
		// then signals the bar's buttons (RTMIN+7) itself
		Quickshell.execDetached([Quickshell.env("HOME") + "/.config/waybar/scripts/power-profile.sh",
			"set", name]);
	}

	Component.onCompleted: readProfile()
	Connections {
		target: PowerProfiles
		function onProfileChanged() { view.readProfile() }
	}
	// turbo <-> performance only flips the flag file: no D-Bus signal
	Timer {
		interval: 1000
		running: true
		repeat: true
		onTriggered: view.readProfile()
	}
	// a switch that never lands (polkit said no) stops pretending
	Timer {
		id: pendingTimeout
		interval: 8000
		onTriggered: view.pendingProfile = ""
	}

	// ---- view ---------------------------------------------------------------

	// the state colour of the status word and the gauge, as in the script:
	// charging wins over critical, then critical, warning, accent
	readonly property color stateColor: !d || d.missing ? Theme.dim
		: d.status === "Charging" ? Theme.ok
		: d.capacity <= critAt ? Theme.crit
		: d.capacity <= warnAt ? Theme.warm
		: Theme.accent

	// headline: charge and status
	Item {
		width: parent.width
		implicitHeight: level.implicitHeight

		Label {
			id: level
			text: view.d && !view.d.missing ? view.d.capacity + "%" : "--"
			font.pixelSize: Theme.headSize
			font.bold: true
		}
		Label {
			anchors.right: parent.right
			anchors.verticalCenter: level.verticalCenter
			text: !view.d ? "" : view.d.missing ? "No battery found" : view.d.status
			textFormat: Text.PlainText
			color: view.stateColor
			font.pixelSize: Theme.chipSize
			font.bold: true
			Behavior on color { ColorAnimation { duration: 250 } }
		}
	}

	Meter {
		id: gauge
		width: parent.width
		implicitHeight: 8
		value: view.d?.capacity ?? 0
		fill: view.stateColor

		// where charging stops, when a threshold is set
		Rectangle {
			visible: (view.d?.limit ?? 100) < 100
			x: Math.round(gauge.width * (view.d?.limit ?? 100) / 100) - 1
			width: 2
			height: parent.height
			color: Theme.fg
		}
	}

	Rule {
		width: parent.width
		visible: !!view.d && !view.d.missing
	}

	// live readings, dim label / bright value
	Grid {
		visible: (view.d?.live?.length ?? 0) > 0
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Repeater {
			model: view.d?.live ?? []
			Label {
				required property int index
				required property string modelData
				text: modelData
				color: index % 2 ? Theme.fg : Theme.dim
				font.bold: index % 2 === 1
			}
		}
	}

	Rule {
		width: parent.width
		visible: (view.d?.live?.length ?? 0) > 0 && (view.d?.fixed?.length ?? 0) > 0
	}

	// slow figures
	Grid {
		visible: (view.d?.fixed?.length ?? 0) > 0
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Repeater {
			model: view.d?.fixed ?? []
			Label {
				required property int index
				required property string modelData
				text: modelData
				color: index % 2 ? Theme.fg : Theme.dim
				font.bold: index % 2 === 1
			}
		}
	}

	Rule { width: parent.width }

	// power profile switcher: the drawer's four buttons, the active one
	// inverted in its colour like the bar draws it
	Row {
		id: profiles
		width: parent.width
		spacing: 6

		Repeater {
			model: [
				{ id: "turbo",       icon: "\u{f135}",  label: "Turbo",    key: "pp-turbo" },
				{ id: "performance", icon: "\u{f0e7}",  label: "Perf",     key: "pp-performance" },
				{ id: "balanced",    icon: "\u{f029a}", label: "Balanced", key: "pp-balanced" },
				{ id: "power-saver", icon: "\u{f032a}", label: "Saver",    key: "pp-saver" }
			]

			Rectangle {
				id: btn
				required property var modelData
				readonly property bool active: view.profile === modelData.id
				readonly property color tint: Theme.color(modelData.key, Theme.accent)

				width: (profiles.width - profiles.spacing * 3) / 4
				height: 30
				color: active ? tint
					: hover.hovered ? Qt.rgba(tint.r, tint.g, tint.b, 0.2)
					: "transparent"
				border.width: active ? 0 : 1
				border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.45)
				Behavior on color { ColorAnimation { duration: 150 } }

				Row {
					anchors.centerIn: parent
					spacing: 6
					Label {
						anchors.verticalCenter: parent.verticalCenter
						text: btn.modelData.icon
						color: btn.active ? Theme.bg : btn.tint
						font.pixelSize: Theme.chipSize
					}
					Label {
						anchors.verticalCenter: parent.verticalCenter
						text: btn.modelData.label
						color: btn.active ? Theme.bg : Theme.fg
						font.bold: btn.active
					}
				}

				HoverHandler {
					id: hover
					cursorShape: Qt.PointingHandCursor
				}
				TapHandler {
					onTapped: view.setProfile(btn.modelData.id)
				}
			}
		}
	}
}
