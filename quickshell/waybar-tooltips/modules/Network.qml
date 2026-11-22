// custom/network: the link carrying the default route in full and every
// other active link under it -- a straight port of network-status.sh's
// tooltip, same rows, same wording.
//
// Sources, while the popup is open:
//   links     one shell pass every 3 s (Process, ~60 ms): `ip -j route show
//             default` picks the primary interface (lowest metric, tunnels
//             and lo skipped), `nmcli device show` gives connection, IPv4,
//             gateway and DNS, `nmcli device wifi list --rescan no` the
//             cached channel / signal / security, and `iw dev X link` the
//             dBm, frequency and bitrate. None of that is in
//             Quickshell.Networking, which knows devices but not addresses.
//   wired     link speed from Quickshell.Networking (WiredDevice.linkSpeed)
//   radio     Wi-Fi on/off from Quickshell.Networking, for the short state
//   traffic   /proc/net/dev every second, the delta between two samples
//   public    the bar script's cache ($XDG_RUNTIME_DIR/waybar-network.pubip:
//             link key, timestamp, address), never fetched from here

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs

Column {
	id: view

	property var d: null
	property var prevDev: null
	property var rates: null
	// first link pass (~60 ms) and first traffic delta (250 ms)
	readonly property bool ready: d !== null && rates !== null
	readonly property string align: "center"

	readonly property var primary: d && d.links.length ? d.links[0] : null
	readonly property var others: d ? d.links.slice(1) : []
	readonly property bool isWifi: primary?.type === "wifi"
	readonly property var rate: primary ? rates?.[primary.dev] : undefined

	width: primary ? 385 : 220
	spacing: 7

	FileView { id: netDev; path: "/proc/net/dev"; blockLoading: true }
	FileView {
		id: pubip
		path: Quickshell.env("XDG_RUNTIME_DIR") + "/waybar-network.pubip"
		blockLoading: true
		printErrors: false
	}

	// ---- links ------------------------------------------------------------

	Process {
		id: probe
		command: ["sh", "-c", `
			echo @@route; ip -j route show default 2>/dev/null
			echo @@dev
			nmcli -t -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show 2>/dev/null
			echo @@wifi
			nmcli -t -f DEVICE,ACTIVE,CHAN,SIGNAL,SECURITY device wifi list --rescan no 2>/dev/null
			for w in /sys/class/net/*/wireless; do
				[ -e "$w" ] || continue
				w=\${w%/wireless}; w=\${w##*/}
				echo "@@iw $w"; iw dev "$w" link 2>/dev/null
			done
		`]
		stdout: StdioCollector {
			onStreamFinished: view.parse(text)
		}
	}

	Timer {
		interval: 3000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!probe.running) probe.running = true
	}

	// nmcli -t escapes the colons inside a value
	function unesc(s) {
		return s.replace(/\\:/g, ":");
	}

	function parse(out) {
		const sec = {};
		const iw = {};
		let cur = null;
		for (const line of out.split("\n")) {
			if (line.startsWith("@@iw ")) {
				cur = [];
				iw[line.slice(5).trim()] = cur;
			} else if (line.startsWith("@@")) {
				cur = [];
				sec[line.slice(2).trim()] = cur;
			} else if (cur) {
				cur.push(line);
			}
		}

		// the interface the default route leaves by, lowest metric first
		let primary = "";
		try {
			const routes = JSON.parse((sec.route ?? []).join("\n") || "[]")
				.filter(r => r.dev !== "lo" && !/^(tailscale|tun|wg)/.test(r.dev))
				.sort((a, b) => (a.metric ?? 0) - (b.metric ?? 0));
			primary = routes[0]?.dev ?? "";
		} catch (e) {}

		// connected ethernet / wifi devices, primary first
		const links = [];
		let dev = null;
		for (const line of sec.dev ?? []) {
			const i = line.indexOf(":");
			if (i < 0)
				continue;
			const key = line.slice(0, i);
			const val = unesc(line.slice(i + 1));
			if (key === "GENERAL.DEVICE") {
				dev = { dev: val, name: "", dns: [], addr: "", gw: "" };
				links.push(dev);
			} else if (!dev) {
				continue;
			} else if (key === "GENERAL.TYPE") {
				dev.type = val;
			} else if (key === "GENERAL.STATE") {
				dev.state = val.replace(/^\d+ \((.*)\)$/, "$1");
			} else if (key === "GENERAL.CONNECTION") {
				dev.name = val;
			} else if (key.startsWith("IP4.ADDRESS")) {
				if (!dev.addr)
					dev.addr = val;
			} else if (key === "IP4.GATEWAY") {
				dev.gw = val;
			} else if (key.startsWith("IP4.DNS")) {
				dev.dns.push(val);
			}
		}
		const up = links.filter(l => l.state === "connected"
			&& (l.type === "ethernet" || l.type === "wifi"));
		up.sort((a, b) => (b.dev === primary) - (a.dev === primary));

		const wifiList = (sec.wifi ?? []).map(l => l.split(":"));
		for (const l of up) {
			if (l.type === "wifi")
				describeWifi(l, wifiList, iw[l.dev] ?? []);
			else
				l.speed = wiredSpeed(l.dev);
		}

		// the bar script's public address, if it belongs to this link
		let pub = "";
		if (up.length) {
			pubip.reload();
			const p = pubip.text().split("\n");
			const key = up[0].dev + "|" + up[0].name + "|" + up[0].gw;
			if (pubip.loaded && p[0] === key)
				pub = (p[2] ?? "").trim();
		}

		d = { links: up, pubip: pub };
	}

	function describeWifi(l, wifiList, iwLines) {
		// channel, signal % and security from NetworkManager's cached scan
		const a = wifiList.find(f => f[0] === l.dev && f[1] === "yes");
		if (a) {
			l.chan = a[2];
			l.signal = a[3];
			l.sec = a[4] || "open";
		}
		// dBm, frequency and the negotiated transmit rate from the driver
		let mhz = 0;
		for (const raw of iwLines) {
			const s = raw.trim();
			let m;
			if ((m = /^signal:\s*(-?\d+)/.exec(s)))
				l.dbm = m[1];
			else if ((m = /^freq:\s*(\d+)/.exec(s)))
				mhz = parseInt(m[1]);
			else if ((m = /^tx bitrate:\s*(\d+)/.exec(s)))
				l.rate = m[1];
		}
		if (mhz > 0)
			l.band = mhz < 3000 ? "2.4 GHz" : mhz < 5925 ? "5 GHz" : "6 GHz";
	}

	// -1 / 0 when the driver cannot tell, e.g. some USB adapters
	function wiredSpeed(name) {
		for (const dev of Networking.devices.values) {
			if (dev.name === name && dev.type === DeviceType.Wired)
				return dev.linkSpeed > 0 ? String(dev.linkSpeed) : "";
		}
		return "";
	}

	// ---- traffic ----------------------------------------------------------

	// false until there are two samples to compare
	function sampleTraffic() {
		netDev.reload();
		const cur = { t: Date.now(), dev: {} };
		for (const line of netDev.text().split("\n")) {
			const i = line.indexOf(":");
			if (i < 0)
				continue;
			const f = line.slice(i + 1).trim().split(/\s+/).map(Number);
			cur.dev[line.slice(0, i).trim()] = [f[0], f[8]];
		}
		const prev = prevDev;
		prevDev = cur;
		if (!prev)
			return false;
		const dt = (cur.t - prev.t) / 1000;
		const r = {};
		for (const name in cur.dev) {
			const a = prev.dev[name], b = cur.dev[name];
			// a counter going backwards means the interface was reset
			if (!a || dt <= 0 || b[0] < a[0] || b[1] < a[1])
				continue;
			r[name] = [(b[0] - a[0]) / dt, (b[1] - a[1]) / dt];
		}
		rates = r;
		return true;
	}

	Timer {
		interval: 1000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!view.sampleTraffic()) quickSample.restart()
	}
	Timer {
		id: quickSample
		interval: 250
		onTriggered: view.sampleTraffic()
	}

	// "1.2 MB/s", "340 kB/s", "12 B/s" -- SI units, one decimal below ten
	function fmtRate(b) {
		const u = ["B/s", "kB/s", "MB/s", "GB/s"];
		let i = 0;
		while (b >= 1000 && i < 3) {
			b /= 1000;
			i++;
		}
		return (b < 10 && i > 0 ? b.toFixed(1) : Math.floor(b)) + " " + u[i];
	}

	// address without its prefix, for the clipboard
	function bare(cidr) {
		return cidr.split("/")[0];
	}

	// ---- view -------------------------------------------------------------

	// one label / value line, hidden when it has no value. Values in `copy`
	// ([shown, copied] pairs) are click-to-copy, side by side, wrapped when
	// they run out of room; `text` is a plain value.
	component Field: Row {
		id: field
		property string label
		property string text: ""
		property var copy: []

		visible: text !== "" || copy.length > 0
		spacing: 16

		Label {
			width: 64
			text: field.label
			color: Theme.dim
		}
		Label {
			visible: field.text !== ""
			text: field.text
			font.bold: true
		}
		Flow {
			visible: field.copy.length > 0
			width: field.width - 80
			spacing: 8
			Repeater {
				model: field.copy
				CopyLabel {
					required property var modelData
					text: modelData[0]
					value: modelData[1]
				}
			}
		}
	}

	// nothing connected: the one line the script shows
	Label {
		visible: view.d !== null && !view.primary
		text: Networking.wifiEnabled ? "Disconnected" : "Wi-Fi disabled"
		font.pixelSize: Theme.headSize
		font.bold: true
	}

	// headline: connection name, link type in accent on the right
	Item {
		visible: view.primary !== null
		width: parent.width
		implicitHeight: name.implicitHeight

		Label {
			id: name
			width: parent.width - kind.implicitWidth - 16
			text: view.primary?.name ?? ""
			elide: Text.ElideRight
			font.pixelSize: Theme.headSize
			font.bold: true
		}
		Label {
			id: kind
			anchors.right: parent.right
			anchors.verticalCenter: name.verticalCenter
			text: view.isWifi ? "Wi-Fi" : "Ethernet"
			color: Theme.accent
			font.pixelSize: Theme.chipSize
			font.bold: true
		}
	}

	// signal gauge under a Wi-Fi header; high is good, so accent as in the
	// script rather than the load ramp
	Meter {
		visible: view.isWifi
		width: parent.width
		implicitHeight: 8
		value: parseInt(view.primary?.signal ?? "0") || 0
		fill: Theme.accent
	}

	Rule {
		visible: view.primary !== null
		width: parent.width
	}

	// the primary link
	Column {
		visible: view.primary !== null
		width: parent.width
		spacing: 3

		Field {
			width: parent.width
			label: "Signal"
			text: {
				const p = view.primary;
				if (!view.isWifi)
					return "";
				return (p.signal ? p.signal + "%" : "") + (p.dbm ? " · " + p.dbm + " dBm" : "");
			}
		}
		Field {
			width: parent.width
			label: "Band"
			text: view.isWifi ? (view.primary.band ?? "")
				+ (view.primary.chan ? " · ch " + view.primary.chan : "") : ""
		}
		Field {
			width: parent.width
			label: "Link"
			text: {
				const p = view.primary;
				const v = view.isWifi ? p?.rate : p?.speed;
				return v ? v + " Mb/s" : "";
			}
		}
		Field {
			width: parent.width
			label: "Security"
			text: view.isWifi ? view.primary.sec ?? "" : ""
		}
		Field {
			width: parent.width
			label: "Device"
			text: view.primary?.dev ?? ""
		}
	}

	Rule {
		visible: view.primary !== null
		width: parent.width
	}

	Column {
		visible: view.primary !== null
		width: parent.width
		spacing: 3

		Field {
			width: parent.width
			label: "IPv4"
			copy: view.primary?.addr ? [[view.primary.addr, view.bare(view.primary.addr)]] : []
		}
		Field {
			width: parent.width
			label: "Public"
			copy: view.d?.pubip ? [[view.d.pubip, view.d.pubip]] : []
		}
		Field {
			width: parent.width
			label: "Gateway"
			copy: view.primary?.gw ? [[view.primary.gw, view.primary.gw]] : []
		}
		Field {
			width: parent.width
			label: "DNS"
			// "a, b, c" as in the script, each server copied on its own
			copy: {
				const l = view.primary?.dns ?? [];
				return l.map((s, i) => [s + (i < l.length - 1 ? "," : ""), s]);
			}
		}
	}

	// traffic, once there is a rate for the primary link
	Rule {
		visible: view.rate !== undefined
		width: parent.width
	}
	Column {
		visible: view.rate !== undefined
		width: parent.width
		spacing: 3

		Field {
			width: parent.width
			label: "Down"
			text: view.rate !== undefined ? view.fmtRate(view.rate[0]) : ""
		}
		Field {
			width: parent.width
			label: "Up"
			text: view.rate !== undefined ? view.fmtRate(view.rate[1]) : ""
		}
	}

	// every other active link: what it is, and its address
	Repeater {
		model: view.others

		Column {
			id: other
			required property var modelData
			width: view.width
			spacing: 3

			Rule { width: parent.width }
			Item { width: 1; height: 4 }
			Field {
				width: parent.width
				label: other.modelData.type === "wifi" ? "Wi-Fi" : "Ethernet"
				text: {
					const l = other.modelData;
					if (l.type === "wifi")
						return l.name + (l.signal ? " · " + l.signal + "%" : "");
					return l.name + (l.speed ? " · " + l.speed + " Mb/s" : "");
				}
			}
			Field {
				width: parent.width
				label: "IPv4"
				copy: other.modelData.addr ? [[other.modelData.addr, view.bare(other.modelData.addr)]] : []
			}
		}
	}
}
