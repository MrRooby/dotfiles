// custom/brightness: brightness and identity of the screen this bar sits on,
// the rows of brightness.sh's tooltip. Read-only: the bar's scroll sets it.
//
// It describes the hovered bar's output (Popup.output, from the shell) the
// way brightness.sh does:
//   eDP-*   the laptop panel: /sys/class/backlight, read once a second
//   other   an external monitor through ddcutil, over DDC/CI (I2C) or USB.
//           ddcutil takes ~0.3 s a call, so nothing here runs it:
//           brightness.sh keeps its readings in $XDG_RUNTIME_DIR/
//           waybar-brightness ("displays" lists "<link> <output> <model>",
//           link being i2c-N or usb-B.D; <link>-target, <link>-vcp) and those
//           files are read instead
//   EDID    the script's per-monitor cache, edid-<cksum>, keyed by the POSIX
//           cksum of /sys/class/drm/card*-<output>/edid (computed here)

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	readonly property string align: "right"

	// the output of the hovered bar, as the shell received it (the popup
	// window's own screen lags behind when moving to the other output)
	readonly property string output: Popup.output || (Quickshell.screens[0]?.name ?? "")
	readonly property bool internal: output.startsWith("eDP")

	readonly property string stateDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/waybar-brightness"

	property var d: null
	// kept apart from d and only replaced when it changes, so the rows are
	// not rebuilt every second
	property var sections: []
	readonly property bool ready: d !== null

	// set from sample(); the FileViews below follow them
	property string link: ""  // i2c-N or usb-B.D
	property string edidSum: ""

	readonly property int shown: d?.pct ?? -1

	// as wide as the content: the widest row grid, or the headline
	property real gridsW: 0
	width: Math.max(gridsW, pctLabel.implicitWidth + 24 + outLabel.implicitWidth)
	spacing: 7

	// the Instantiators below only have their FileViews once complete
	property bool complete: false
	Component.onCompleted: {
		complete = true;
		sample();
	}
	onOutputChanged: sample()

	// ---- sources ----------------------------------------------------------

	FileView {
		id: displays
		path: view.stateDir + "/displays"
		blockLoading: true
		printErrors: false
	}

	// backlight devices brightnessctl would find; the first present wins
	readonly property var backlights: ["amdgpu_bl0", "amdgpu_bl1", "amdgpu_bl2", "intel_backlight", "acpi_video0"]
	Instantiator {
		id: blMax
		model: view.backlights
		delegate: FileView {
			required property string modelData
			path: "/sys/class/backlight/" + modelData + "/max_brightness"
			blockLoading: true
			printErrors: false
		}
	}
	Instantiator {
		id: blCur
		model: view.backlights
		delegate: FileView {
			required property string modelData
			path: "/sys/class/backlight/" + modelData + "/brightness"
			blockLoading: true
			printErrors: false
		}
	}

	// the output's EDID, under any DRM card. An array model is rebuilt when
	// it changes, so each FileView reads its own path from the start.
	Instantiator {
		id: edids
		model: view.output ? [0, 1, 2, 3].map(i => "/sys/class/drm/card" + i + "-" + view.output + "/edid") : []
		delegate: FileView {
			required property string modelData
			path: modelData
			blockLoading: true
			printErrors: false
		}
	}

	// files whose names are only known after a read: 0 target, 1 vcp, 2 edid cache
	Instantiator {
		id: dyn
		model: [
			view.link !== "" ? view.stateDir + "/" + view.link + "-target" : "",
			view.link !== "" ? view.stateDir + "/" + view.link + "-vcp" : "",
			view.edidSum !== "" ? view.stateDir + "/edid-" + view.edidSum : ""
		]
		delegate: FileView {
			required property string modelData
			path: modelData
			blockLoading: true
			printErrors: false
		}
	}

	// text of a FileView, or null when it has no file
	function read(fv) {
		if (!fv || fv.path === "")
			return null;
		fv.reload();
		const t = fv.text();
		return fv.loaded ? t : null;
	}

	// POSIX cksum (CRC-32/CKSUM over the bytes, then the length), as the
	// script keys its EDID cache
	property var crcTable: null
	function cksum(bytes) {
		if (!crcTable) {
			const t = [];
			for (let i = 0; i < 256; i++) {
				let c = i << 24;
				for (let k = 0; k < 8; k++)
					c = (c & 0x80000000) ? (c << 1) ^ 0x04C11DB7 : c << 1;
				t.push(c >>> 0);
			}
			crcTable = t;
		}
		const t = crcTable;
		let crc = 0;
		const step = b => { crc = ((crc << 8) ^ t[((crc >>> 24) ^ b) & 0xff]) >>> 0; };
		for (let i = 0; i < bytes.length; i++)
			step(bytes[i]);
		for (let n = bytes.length; n > 0; n = Math.floor(n / 256))
			step(n & 0xff);
		return (~crc) >>> 0;
	}

	// MCCS colour preset codes (VCP 0x14), as in the script
	function presetName(code) {
		const names = {
			"01": "sRGB", "02": "Native", "03": "4000 K", "04": "5000 K",
			"05": "6500 K", "06": "7500 K", "07": "8200 K", "08": "9300 K",
			"09": "10000 K", "0a": "11500 K", "0b": "User 1", "0c": "User 2",
			"0d": "User 3"
		};
		const c = code.toLowerCase();
		return c === "" ? "" : names[c] ?? "0x" + code;
	}

	// 15634 -> "15 634"
	function group(n) {
		return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
	}

	function kv(text) {
		const o = {};
		for (const line of (text ?? "").split("\n")) {
			const i = line.indexOf("=");
			if (i > 0)
				o[line.slice(0, i)] = line.slice(i + 1);
		}
		return o;
	}

	function sample() {
		if (!complete || output === "")
			return;

		// EDID checksum -> the script's cached make/model/... for this monitor
		let sum = "";
		for (let i = 0; i < edids.count; i++) {
			const fv = edids.objectAt(i);
			fv.reload();
			const buf = fv.data();
			if (fv.loaded && buf && buf.byteLength > 0) {
				sum = String(cksum(new Uint8Array(buf)));
				break;
			}
		}

		let pct = null, rows = [], status = "", model = "";
		if (internal) {
			let dev = "";
			for (let i = 0; i < view.backlights.length; i++) {
				const max = parseInt(read(blMax.objectAt(i)));
				if (max > 0) {
					dev = view.backlights[i];
					const cur = parseInt(read(blCur.objectAt(i)));
					pct = Math.round(100 * cur / max);
					break;
				}
			}
			rows = [["Control", "backlight"], ["Device", dev]];
		} else {
			let l = "";
			for (const line of (read(displays) ?? "").split("\n")) {
				const f = line.trim().split(/\s+/);
				if (f.length >= 2 && f[1] === output) {
					l = f[0];
					model = f[2] ?? "";
					break;
				}
			}
			link = l;  // rebuilds dyn's FileViews for this link
			if (l === "") {
				status = "no DDC/CI or USB";
			} else {
				const t = parseInt(read(dyn.objectAt(0)));
				if (isNaN(t)) {
					status = "DDC/CI read failed";
				} else {
					pct = t;
					const vcp = kv(read(dyn.objectAt(1)));
					rows = [
						["Contrast", vcp.contrast ? vcp.contrast + "%" : ""],
						["Preset", presetName(vcp.preset ?? "")],
						["Usage", vcp.hours ? group(vcp.hours) + " h" : ""],
						null,
						...(l.startsWith("usb-")
							? [["Control", "USB"], ["Device", l.slice(4)]]
							: [["Control", "DDC/CI"], ["Bus", l]])
					];
				}
			}
		}

		edidSum = sum;  // rebuilds dyn's edid-<sum> FileView
		const e = kv(read(dyn.objectAt(2)));
		const identity = [
			["Make", e.E_MAKE ?? ""],
			["Model", e.E_MODEL || model],
			["Serial", e.E_SERIAL ?? ""],
			["Size", e.E_SIZE ?? ""],
			["Native", e.E_NATIVE ?? ""],
			["Made", e.E_YEAR ?? ""]
		];
		if (status !== "")
			rows = [["Status", status]];

		// sections without empty rows, and without empty sections
		const sections = [];
		let cur = [];
		for (const r of identity.concat([null], rows)) {
			if (r === null) {
				if (cur.length)
					sections.push(cur);
				cur = [];
			} else if (r[1] !== "") {
				cur.push(r);
			}
		}
		if (cur.length)
			sections.push(cur);

		if (JSON.stringify(sections) !== JSON.stringify(view.sections))
			view.sections = sections;
		d = { pct: pct };
	}

	Timer {
		interval: 1000
		running: true
		repeat: true
		onTriggered: view.sample()
	}

	// ---- view -------------------------------------------------------------

	// headline: percent and the output
	Item {
		width: parent.width
		implicitHeight: pctLabel.implicitHeight

		Label {
			id: pctLabel
			text: view.shown >= 0 ? view.shown + "%" : "--"
			color: view.shown >= 0 ? Theme.fg : Theme.dim
			font.pixelSize: Theme.headSize
			font.bold: true
		}
		Label {
			id: outLabel
			anchors.right: parent.right
			anchors.verticalCenter: pctLabel.verticalCenter
			text: view.output
			color: Theme.accent
			font.pixelSize: Theme.chipSize
			font.bold: true
		}
	}

	// gauge, filled in the accent like the script's bar
	Meter {
		visible: view.shown >= 0
		width: parent.width
		implicitHeight: 8
		value: view.shown
		fill: Theme.accent
	}

	Repeater {
		model: view.sections

		Column {
			id: section
			required property var modelData
			width: view.width
			spacing: 7

			Rule { width: parent.width }

			Grid {
				columns: 2
				onImplicitWidthChanged: view.gridsW = Math.max(view.gridsW, implicitWidth)
				columnSpacing: 16
				rowSpacing: 3

				Repeater {
					// flattened: label, value, label, value, ...
					model: section.modelData.reduce((a, r) => a.concat(r), [])

					// even cells are dim labels, odd ones bold values
					Label {
						required property string modelData
						required property int index
						text: modelData
						color: index % 2 === 0 ? Theme.dim : Theme.fg
						font.bold: index % 2 === 1
					}
				}
			}
		}
	}
}
