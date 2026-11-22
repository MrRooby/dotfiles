// custom/bluetooth: a port of scripts/bluetooth.sh's tooltip -- the adapter,
// every device bluez knows, and the negotiated codec under each connected
// headset. Same content, wording, ordering and colours as the script; the
// only addition is that MACs are click-to-copy.
//
// The data is the same single D-Bus call the script makes, org.bluez
// GetManagedObjects through busctl (a few ms), polled every 3 s (the bar
// module's interval) while the popup is open. Quickshell.Bluetooth has the
// adapter and devices but not the adapter MAC, RSSI, AddressType,
// Class/Appearance, UUIDs or the MediaTransport1 codec blob.
//
// The codec decoders follow bluez's a2dp-codecs.h, ported from the jq in the
// script: packed bitfields, so the first field of a byte is in its low bits.
//
// The rows are laid out like the script's: monospace text padded to columns
// by character count (the theme font is the single-width Nerd Font Mono, so
// one glyph is one cell).

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	property var d: null
	readonly property bool ready: d !== null
	property string align: "center"

	width: Math.max(310, (cols.total + 1) * fm.advanceWidth("M"))   // +1: no glyph against the frame
	spacing: 4

	readonly property int battWarn: 25
	readonly property int battCrit: 10

	readonly property var glyphs: ({
		headphones: "\u{f02cb}", headset: "\u{f02ce}", speaker: "\u{f04c3}", phone: "\u{f011c}",
		computer: "\u{f0322}", keyboard: "\u{f030c}", mouse: "\u{f037d}", gamepad: "\u{f02b4}",
		tablet: "\u{f04f7}", printer: "\u{f042a}", scanner: "\u{f06ab}", camera: "\u{f0100}",
		video: "\u{f0567}", display: "\u{f0379}", network: "\u{f0469}", watch: "\u{f0b32}",
		car: "\u{f010b}", pen: "\u{f0641}", unknown: "\u{f00af}"
	})
	// the same ten-step ramp battery.sh draws in the bar
	readonly property var battIcons: ["\u{f008e}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}",
		"\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}"]

	FontMetrics {
		id: fm
		font.family: Theme.font
		font.pixelSize: Theme.fontSize
	}

	// ---- data -------------------------------------------------------------

	Process {
		id: proc
		command: ["busctl", "--json=short", "--no-pager", "call", "org.bluez", "/",
			"org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]
		stdout: StdioCollector {
			onStreamFinished: view.d = view.parse(text)
		}
	}

	Timer {
		interval: 3000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!proc.running) proc.running = true
	}

	// ---- decoding (ported from the jq in bluetooth.sh) -------------------

	function val(p) { return p === undefined || p === null ? null : p.data; }
	function str(p) { const v = val(p); return v === null ? "" : String(v); }
	function flag(p) { return val(p) === true; }
	function bset(v, w) { return v === null || v === undefined ? false : Math.floor(v / w) % 2 === 1; }
	function mask(v, tbl) {
		for (const e of tbl)
			if (bset(v, e[0]))
				return e[1];
		return "";
	}
	function khz(f) { return f === "" ? "" : (f / 1000) + " kHz"; }

	// a vendor A2DP codec: 32-bit LE company ID, then a 16-bit codec ID
	function vendorCodec(c) {
		const v = (c[0] ?? 0) + (c[1] ?? 0) * 256 + (c[2] ?? 0) * 65536 + (c[3] ?? 0) * 16777216;
		const i = (c[4] ?? 0) + (c[5] ?? 0) * 256;
		const known = [
			[301, 170, "LDAC"], [79, 1, "aptX"], [215, 36, "aptX HD"], [215, 2, "aptX LL"],
			[215, 173, "aptX Adaptive"], [10, 1, "FastStream"], [117, 259, "Samsung Scalable"],
			[1338, 18508, "LHDC"], [1338, 19506, "LHDC v2"], [1338, 19507, "LHDC v3"],
			[1338, 19509, "LHDC v5"], [1249, 1, "LC3plus"]
		];
		for (const k of known)
			if (k[0] === v && k[1] === i)
				return k[2];
		return "vendor " + v + ":" + i;
	}

	function sbcFs(c) { return mask(c[0], [[128, 16000], [64, 32000], [32, 44100], [16, 48000]]); }
	function sbcChan(c) { return mask(c[0], [[8, "mono"], [4, "dual channel"], [2, "stereo"], [1, "joint stereo"]]); }
	// the bitrate the link runs at, from the frame length (SBC spec 12.9)
	function sbcKbps(c) {
		const blocks = mask(c[1], [[128, 4], [64, 8], [32, 12], [16, 16]]);
		const sb = mask(c[1], [[8, 4], [4, 8]]);
		const fs = sbcFs(c);
		const mode = sbcChan(c);
		const bp = c[3] ?? 0;
		if (blocks === "" || sb === "" || fs === "" || mode === "" || bp === 0)
			return "";
		const ch = mode === "mono" ? 1 : 2;
		const frame = 4 + (4 * sb * ch / 8)
			+ (mode === "mono" || mode === "dual channel"
				? Math.floor((blocks * ch * bp + 7) / 8)
				: Math.floor(((mode === "joint stereo" ? sb : 0) + blocks * bp + 7) / 8));
		return Math.round(8 * frame * fs / (sb * blocks) / 1000) + " kbps";
	}

	function aacFs(c) {
		const f = (c[1] ?? 0) * 16 + Math.floor((c[2] ?? 0) / 16);
		return mask(f, [[2048, 8000], [1024, 11025], [512, 12000], [256, 16000],
			[128, 22050], [64, 24000], [32, 32000], [16, 44100],
			[8, 48000], [4, 64000], [2, 88200], [1, 96000]]);
	}
	function aacChan(c) { return mask(c[2], [[8, "mono"], [4, "stereo"]]); }
	function aacKbps(c) {
		const b = ((c[3] ?? 0) % 128) * 65536 + (c[4] ?? 0) * 256 + (c[5] ?? 0);
		return b === 0 ? "" : Math.floor(b / 1000) + " kbps" + (bset(c[3], 128) ? " VBR" : "");
	}

	// LDAC and aptX put their fields after the six-byte vendor header;
	// aptX Adaptive lays them out differently and only reports its name
	function ldacFs(c) { return mask(c[6], [[32, 44100], [16, 48000], [8, 88200], [4, 96000], [2, 176400], [1, 192000]]); }
	function ldacChan(c) { return mask(c[7], [[4, "mono"], [2, "dual channel"], [1, "stereo"]]); }
	function aptxFs(c) { return mask(c[6], [[128, 16000], [64, 32000], [32, 44100], [16, 48000]]); }
	function aptxChan(c) { return mask(c[6], [[2, "stereo"], [1, "mono"]]); }

	function transport(t) {
		const c = val(t.Codec);
		const cfg = val(t.Configuration) ?? [];
		const u = str(t.UUID).toLowerCase();
		const pre = p => u.startsWith(p);
		const profile = pre("0000110a") || pre("0000110b") ? "A2DP"
			: pre("00001108") || pre("0000111e") || pre("0000111f") || pre("00001131") ? "HFP"
			: "LE Audio";
		let codec;
		if (profile === "A2DP")
			codec = c === 0 ? "SBC" : c === 1 ? "MP3" : c === 2 ? "AAC" : c === 4 ? "ATRAC"
				: c === 255 ? vendorCodec(cfg) : "codec " + c;
		else if (profile === "HFP")
			codec = c === 1 ? "CVSD" : c === 2 ? "mSBC" : c === 3 ? "LC3-SWB" : "codec " + c;
		else
			codec = c === 6 ? "LC3" : "codec " + c;

		let extra = [];
		if (codec === "SBC")
			extra = [khz(sbcFs(cfg)), sbcChan(cfg), sbcKbps(cfg), (cfg[3] ?? 0) > 0 ? "bitpool " + cfg[3] : ""];
		else if (codec === "AAC")
			extra = [khz(aacFs(cfg)), aacChan(cfg), aacKbps(cfg)];
		else if (codec === "LDAC")
			extra = [khz(ldacFs(cfg)), ldacChan(cfg)];
		else if (codec === "aptX" || codec === "aptX HD" || codec === "aptX LL")
			extra = [khz(aptxFs(cfg)), aptxChan(cfg)];

		const vol = val(t.Volume);
		const parts = [codec].concat(extra, [
			vol !== null ? "vol " + Math.round(vol * 100 / 127) + "%" : "",
			str(t.State)
		]);
		return { profile: profile, detail: parts.filter(s => s !== "").join(" · ") };
	}

	// bluez's Icon first, then the BR/EDR major class or the LE appearance
	function iconKey(dev) {
		const byIcon = {
			"audio-headphones": "headphones", "audio-headset": "headset",
			"audio-card": "speaker", "audio-speakers": "speaker",
			"multimedia-player": "speaker", "phone": "phone", "computer": "computer",
			"input-keyboard": "keyboard", "input-mouse": "mouse",
			"input-gaming": "gamepad", "input-tablet": "tablet", "printer": "printer",
			"scanner": "scanner", "camera-photo": "camera", "camera-video": "video",
			"video-display": "display", "network-wireless": "network", "modem": "network"
		}[str(dev.Icon)];
		if (byIcon)
			return byIcon;
		const cls = val(dev.Class) ?? 0;
		const app = val(dev.Appearance) ?? 0;
		const maj = Math.floor(cls / 256) % 32;
		const cat = Math.floor(app / 64);
		if (maj === 1) return "computer";
		if (maj === 2) return "phone";
		if (maj === 3) return "network";
		if (maj === 4) return "speaker";
		if (maj === 5) return Math.floor(cls / 64) % 4 === 2 ? "mouse" : "keyboard";
		if (maj === 6) return "printer";
		if (maj === 7) return "watch";
		if (cat === 15) {
			const s = app % 64;
			return s === 2 ? "mouse" : s === 3 || s === 4 ? "gamepad" : s === 5 ? "tablet"
				: s === 7 ? "pen" : s === 8 ? "scanner" : "keyboard";
		}
		if (cat === 1) return "phone";
		if (cat === 2) return "computer";
		if (cat === 3) return "watch";
		if (cat === 5) return "display";
		if (cat === 10) return "speaker";
		if (cat === 11) return "scanner";
		return "unknown";
	}

	function parse(text) {
		let tree;
		try {
			tree = JSON.parse(text).data[0];
		} catch (e) {
			return { adapter: null, devices: [] };
		}
		const paths = Object.keys(tree);

		const ap = paths.find(p => tree[p]["org.bluez.Adapter1"]);
		const a = ap ? tree[ap]["org.bluez.Adapter1"] : null;
		const adapter = a && str(a.Address) !== "" ? {
			alias: str(a.Alias),
			address: str(a.Address),
			power: str(a.PowerState),
			discoverable: flag(a.Discoverable),
			pairable: flag(a.Pairable),
			discovering: flag(a.Discovering)
		} : null;

		const rank = s => s === "active" ? 0 : s === "pending" ? 1 : 2;
		const devices = [];
		for (const p of paths) {
			const dev = tree[p]["org.bluez.Device1"];
			if (!dev)
				continue;
			const bat = tree[p]["org.bluez.Battery1"];
			const ts = paths.filter(q => q.startsWith(p + "/") && tree[q]["org.bluez.MediaTransport1"])
				.map(q => tree[q]["org.bluez.MediaTransport1"])
				.sort((x, y) => rank(str(x.State)) - rank(str(y.State)));
			const ti = ts.length ? transport(ts[0]) : null;
			const conn = flag(dev.Connected);
			const known = flag(dev.Paired) || flag(dev.Bonded);
			const uuids = (val(dev.UUIDs) ?? []).map(s => s.toLowerCase());
			const anyUuid = list => uuids.some(s => list.some(l => s.startsWith(l)));
			const name = str(dev.Alias) || str(dev.Name) || str(dev.Address);
			const live = ti ? ti.profile
				: anyUuid(["00001124", "00001812"]) ? "HID"
				: anyUuid(["00001115", "00001116", "00001117"]) ? "PAN"
				: "connected";
			const state = conn ? live : flag(dev.Blocked) ? "blocked" : known ? "paired"
				: flag(dev.Trusted) ? "trusted" : "new";
			const rssi = val(dev.RSSI);
			const pct = bat ? val(bat.Percentage) : null;
			devices.push({
				conn: conn,
				known: known,
				key: iconKey(dev),
				name: name,
				address: str(dev.Address),
				link: str(dev.AddressType) === "random" ? "LE" : val(dev.Class) !== null ? "BR/EDR" : "LE",
				battery: pct,
				state: state + (rssi !== null ? " · " + rssi + " dBm" : ""),
				detail: ti ? ti.detail : ""
			});
		}
		devices.sort((x, y) => (x.conn ? 0 : 1) - (y.conn ? 0 : 1)
			|| (x.known ? 0 : 1) - (y.known ? 0 : 1)
			|| (x.name.toLowerCase() < y.name.toLowerCase() ? -1
				: x.name.toLowerCase() > y.name.toLowerCase() ? 1 : 0));

		return { adapter: adapter, devices: devices };
	}


	// ---- layout (the script's tooltip()) ---------------------------------

	readonly property var devs: d?.devices ?? []
	readonly property var a: d?.adapter ?? null
	readonly property int nConn: devs.filter(x => x.conn).length
	readonly property int nKnown: devs.filter(x => x.known).length
	readonly property bool hasBatt: devs.some(x => x.battery !== null)

	readonly property string head: "Bluetooth  ·  " + (a?.alias ?? "")
	readonly property string status: {
		if (!a)
			return "";
		const p = a.power;
		let s = p === "on" ? nConn + " connected"
			: p === "off-blocked" ? "blocked (rfkill)"
			: p === "off-enabling" ? "powering on"
			: p === "off-disabling" ? "powering off"
			: "powered off";
		s += " · " + nKnown + " paired";
		if (a.discoverable) s += " · discoverable";
		if (a.pairable) s += " · pairable";
		if (a.discovering) s += " · scanning";
		return s;
	}

	// column widths in characters, measured on the plain text
	readonly property var cols: {
		const w = k => devs.reduce((m, x) => Math.max(m, x[k].length), 0);
		const c = { name: w("name"), addr: w("address"), link: w("link"), state: w("state"), detail: w("detail") };
		// dot + 2 + glyph + 2 + name + 2 + address + 2 + link [+ 2 + battery] + 2 + state
		let t = devs.length ? 1 + 2 + 1 + 2 + c.name + 2 + c.addr + 2 + c.link + (hasBatt ? 8 : 0) + 2 + c.state : 0;
		if (c.detail > 0)
			t = Math.max(t, c.detail + 6);
		t = Math.max(t, head.length, (a?.address ?? "").length, status.length, devs.length ? 0 : "no devices".length);
		c.total = t;
		return c;
	}

	function battCell(pct) {
		if (pct === null)
			return "      ";
		return battIcons[Math.max(0, Math.min(9, Math.floor(pct / 10)))] + " " + String(pct).padStart(3) + "%";
	}
	function battColor(pct) {
		return pct === null ? Theme.dim : pct <= battCrit ? Theme.crit : pct <= battWarn ? Theme.warm : Theme.ok;
	}

	Label {
		visible: view.d !== null && view.a === null
		text: "no bluetooth adapter"
	}

	// header: "Bluetooth", the adapter on the right, then its address and
	// the status line
	Headline {
		visible: view.a !== null
		text: "Bluetooth"
		note: view.a?.alias ?? ""
	}
	Grid {
		visible: view.a !== null
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Address"; color: Theme.dim }
		CopyLabel { text: view.a?.address ?? "" }
		Label { text: "Status"; color: Theme.dim }
		Label { text: view.status; font.bold: true }
	}
	Rule { visible: view.a !== null; width: parent.width }

	Label {
		visible: view.a !== null && view.devs.length === 0
		text: "no devices"
		color: Theme.dim
	}

	// one row per device, connected first, a rule before the rest
	Repeater {
		model: view.a !== null ? view.devs : []

		Column {
			id: row
			required property var modelData
			required property int index
			readonly property var dv: modelData
			readonly property bool on: dv.conn
			readonly property color rest: on ? Theme.fg : Theme.dim

			width: parent.width
			spacing: 4

			Rule {
				visible: !row.on && row.index > 0 && view.devs[row.index - 1].conn
				width: parent.width
			}

			Row {
				Label {
					text: row.on ? "●  " : "○  "
					color: row.on ? Theme.ok : Theme.dim
				}
				Label {
					text: (view.glyphs[row.dv.key] ?? view.glyphs.unknown) + "  "
					color: row.on ? Theme.accent : Theme.dim
				}
				Label {
					text: row.dv.name.padEnd(view.cols.name) + "  "
					color: row.rest
					font.bold: row.on
				}
				CopyLabel {
					text: row.dv.address.padEnd(view.cols.addr)
					value: row.dv.address
					font.bold: false
					color: mac.hovered ? Theme.accent : Theme.dim
					HoverHandler { id: mac }
				}
				Label {
					text: "  " + row.dv.link.padEnd(view.cols.link)
					color: Theme.dim
				}
				Label {
					visible: view.hasBatt
					text: "  " + view.battCell(row.dv.battery)
					color: view.battColor(row.dv.battery)
				}
				Label {
					text: "  " + row.dv.state
					color: row.rest
				}
			}

			// codec, sample rate, channel mode, bitrate, absolute volume and
			// the transport state, indented under the name column
			Label {
				visible: row.dv.detail !== ""
				text: "      " + row.dv.detail
				color: Theme.dim
			}
		}
	}
}
