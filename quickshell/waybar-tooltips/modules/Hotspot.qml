// custom/hotspot: the NetworkManager access point RBMK-1000. A port of the
// tooltip of scripts/hotspot.sh: same rows, same wording.
//
// Polled every 2.5 s while the popup is open:
//   profile, state   nmcli: the profile's ssid/band/channel/key-mgmt, and
//                    `nmcli device` for which card holds it (if any) and
//                    which Wi-Fi connection starting it would drop
//   address          ip -4 addr of that card
//   clients          iw dev <card> station dump: signal, connected time,
//                    bytes; there is no file or service with these
//   client IPs       /proc/net/arp (complete entries only), by MAC
//   uplink           /proc/net/route: the default route with the lowest
//                    metric, other than the hotspot card, lo and tunnels
// nmcli/ip/iw run in one Process per poll; Quickshell.Networking knows the
// card is in AP mode but has no stations or addresses.

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	readonly property string profileName: "RBMK-1000"   // NAME in hotspot.sh

	property var d: null
	readonly property bool ready: d !== null
	readonly property string align: "center"

	readonly property bool missing: d?.missing ?? false
	readonly property bool on: d?.on ?? false
	readonly property int nClients: d?.clients?.length ?? 0

	width: 370
	spacing: 7

	FileView { id: arp; path: "/proc/net/arp"; blockLoading: true; printErrors: false }
	FileView { id: route; path: "/proc/net/route"; blockLoading: true; printErrors: false }

	Process {
		id: proc
		command: ["sh", "-c", `
			n=$1
			echo @profile
			nmcli -t -f 802-11-wireless.ssid,802-11-wireless.band,802-11-wireless.channel,802-11-wireless-security.key-mgmt connection show "$n" 2>/dev/null
			devs=$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null)
			echo @devices
			printf '%s\\n' "$devs"
			dev=$(printf '%s\\n' "$devs" | awk -F: -v n="$n" '$4 == n {print $1; exit}')
			[ -n "$dev" ] || exit 0
			echo @addr
			ip -j -4 addr show dev "$dev" 2>/dev/null
			echo
			echo @stations
			iw dev "$dev" station dump 2>/dev/null
		`, "sh", view.profileName]
		stdout: StdioCollector {
			onStreamFinished: view.parse(text)
		}
	}

	Timer {
		interval: 2500
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!proc.running) proc.running = true
	}

	// ---- parsing ----------------------------------------------------------

	// nmcli -t: fields split on ':', with '\:' and '\\' escaped
	function terse(line) {
		const out = [];
		let cur = "";
		for (let i = 0; i < line.length; i++) {
			const c = line[i];
			if (c === "\\" && i + 1 < line.length)
				cur += line[++i];
			else if (c === ":") {
				out.push(cur);
				cur = "";
			} else
				cur += c;
		}
		out.push(cur);
		return out;
	}

	function parse(text) {
		const sec = {};
		let cur = null;
		for (const line of text.split("\n")) {
			if (/^@\w+$/.test(line)) {
				cur = line.slice(1);
				sec[cur] = [];
			} else if (cur !== null)
				sec[cur].push(line);
		}

		// the profile
		const P = {};
		for (const line of sec.profile ?? []) {
			const i = line.indexOf(":");
			if (i > 0)
				P[line.slice(0, i)] = line.slice(i + 1).replace(/\\(.)/g, "$1");
		}
		if (Object.keys(P).length === 0) {
			d = { missing: true };
			return;
		}
		const bandKey = P["802-11-wireless.band"] ?? "";
		const km = P["802-11-wireless-security.key-mgmt"] ?? "";
		const chan = P["802-11-wireless.channel"] ?? "0";

		// the devices: which card holds the hotspot, which Wi-Fi it would drop
		let dev = "";
		let wifiNow = "";
		for (const line of sec.devices ?? []) {
			if (line === "")
				continue;
			const f = terse(line);   // DEVICE TYPE STATE CONNECTION
			if (f[3] === profileName && dev === "")
				dev = f[0];
			if (f[1] === "wifi" && f[2] === "connected" && f[3] !== profileName && wifiNow === "")
				wifiNow = f[3];
		}

		// the uplink: default routes, lowest metric, not ours / lo / tunnels
		route.reload();
		let uplink = "";
		let best = Infinity;
		for (const line of route.text().split("\n").slice(1)) {
			const f = line.trim().split(/\s+/);
			if (f.length < 8 || f[1] !== "00000000" || f[7] !== "00000000")
				continue;
			if (f[0] === "lo" || f[0] === dev || /^(tailscale|tun|wg)/.test(f[0]))
				continue;
			const metric = parseInt(f[6]) || 0;
			if (metric < best) {
				best = metric;
				uplink = f[0];
			}
		}

		const band = bandKey === "bg" ? "2.4 GHz" : bandKey === "a" ? "5 GHz" : "auto";
		const out = {
			missing: false,
			ssid: P["802-11-wireless.ssid"] || profileName,
			band: band + (chan !== "0" && chan !== "" ? " · ch " + chan : ""),
			sec: km === "wpa-psk" ? "WPA2" : km === "sae" ? "WPA3" : km === "" ? "open" : km,
			on: dev !== "",
			dev: dev,
			uplink: uplink || "none, no internet for clients",
			wifiNow: wifiNow,
			addr: "",
			clients: [],
			tx: 0,
			rx: 0
		};

		if (out.on) {
			try {
				const a = JSON.parse((sec.addr ?? []).join("\n"))[0]?.addr_info?.[0];
				if (a)
					out.addr = a.local + "/" + a.prefixlen;
			} catch (e) {}

			// IPs by MAC, complete entries (ATF_COM) on this card only
			arp.reload();
			const ipOf = {};
			for (const line of arp.text().split("\n").slice(1)) {
				const f = line.trim().split(/\s+/);
				const mac = (f[3] ?? "").toLowerCase();
				if (f.length >= 6 && f[5] === dev && (parseInt(f[2]) & 2) && !ipOf[mac])
					ipOf[mac] = f[0];
			}

			// one client per station: "IP" / "-52 dBm · 3 h 12 min"
			let c = null;
			const flush = () => {
				if (!c)
					return;
				const n = out.clients.length + 1;
				out.clients.push({
					ip: ipOf[c.mac] ?? "",
					name: ipOf[c.mac] ?? "client " + n,
					info: (c.sig !== null ? c.sig + " dBm · " : "") + age(c.secs)
				});
			};
			for (const line of sec.stations ?? []) {
				let m = /^Station ([0-9a-fA-F:]{17})/.exec(line);
				if (m) {
					flush();
					c = { mac: m[1].toLowerCase(), sig: null, secs: 0 };
					continue;
				}
				if (!c)
					continue;
				if ((m = /^\s*rx bytes:\s*(\d+)/.exec(line)))
					out.rx += Number(m[1]);
				else if ((m = /^\s*tx bytes:\s*(\d+)/.exec(line)))
					out.tx += Number(m[1]);
				else if ((m = /^\s*signal:\s*(-?\d+)/.exec(line)))
					c.sig = Number(m[1]);
				else if ((m = /^\s*connected time:\s*(\d+)/.exec(line)))
					c.secs = Number(m[1]);
			}
			flush();
		}

		d = out;
	}

	// ---- formatting (as in hotspot.sh) ------------------------------------

	// "1.2 GB", "340 kB": SI, one decimal below ten
	function size(b) {
		const u = ["B", "kB", "MB", "GB", "TB"];
		let i = 0;
		while (b >= 1000 && i < 4) {
			b /= 1000;
			i++;
		}
		return (b < 10 && i > 0 ? b.toFixed(1) : Math.floor(b)) + " " + u[i];
	}

	// "3 h 12 min", "7 min", "40 s"
	function age(s) {
		if (s >= 3600)
			return Math.floor(s / 3600) + " h " + Math.floor(s % 3600 / 60) + " min";
		if (s >= 60)
			return Math.floor(s / 60) + " min";
		return s + " s";
	}

	// ---- view -------------------------------------------------------------

	// no profile: the script's tooltip is this one line
	Label {
		visible: view.missing
		color: Theme.dim
		text: "No NetworkManager profile named " + view.profileName
	}

	// headline: SSID, and On (accent) / Off (dim)
	Item {
		visible: !view.missing
		width: parent.width
		implicitHeight: Math.max(ssid.implicitHeight, status.implicitHeight)

		Label {
			id: ssid
			width: parent.width - status.width - 16
			anchors.verticalCenter: parent.verticalCenter
			elide: Text.ElideRight
			text: view.d?.ssid ?? view.profileName
			font.pixelSize: Theme.headSize
			font.bold: true
		}
		Chip {
			id: status
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: view.on ? "On" : "Off"
			tint: view.on ? Theme.accent : Theme.dim
		}
	}

	Rule { visible: !view.missing; width: parent.width }

	// the profile, and when on: the card and the uplink
	Grid {
		visible: !view.missing
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Band"; color: Theme.dim }
		Label { font.bold: true; text: view.d?.band ?? "-" }
		Label { text: "Security"; color: Theme.dim }
		Label { font.bold: true; text: view.d?.sec ?? "-" }

		Label { visible: view.on; text: "Device"; color: Theme.dim }
		Label { visible: view.on; font.bold: true; text: view.d?.dev ?? "" }
		Label { visible: view.on && view.d.addr !== ""; text: "Address"; color: Theme.dim }
		CopyLabel {
			visible: view.on && view.d.addr !== ""
			text: view.d?.addr ?? ""
			value: text.split("/")[0]
		}
		Label { visible: view.on; text: "Uplink"; color: Theme.dim }
		Label { visible: view.on; font.bold: true; text: view.d?.uplink ?? "" }
	}

	// off: what starting it would do
	Rule { visible: view.d !== null && !view.missing && !view.on; width: parent.width }
	Grid {
		visible: view.d !== null && !view.missing && !view.on
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Uplink"; color: Theme.dim }
		Label { font.bold: true; text: view.d?.uplink ?? "" }
		Label { visible: (view.d?.wifiNow ?? "") !== ""; text: "On start"; color: Theme.dim }
		Label {
			visible: (view.d?.wifiNow ?? "") !== ""
			font.bold: true
			text: "drops Wi-Fi " + (view.d?.wifiNow ?? "")
		}
	}

	// on: the clients. Column-major so both Repeaters line up: first every
	// label, then every value.
	Rule { visible: view.on; width: parent.width }
	Grid {
		visible: view.on
		rows: 1 + view.nClients
		flow: Grid.TopToBottom
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Clients"; color: Theme.dim }
		Repeater {
			model: view.on ? view.d.clients : []

			Item {
				id: who
				required property var modelData
				implicitWidth: 12 + (modelData.ip !== "" ? ip.implicitWidth : plain.implicitWidth)
				implicitHeight: plain.implicitHeight

				// the IP, click to copy; "client N" until it is in the ARP table
				CopyLabel {
					id: ip
					x: 12
					visible: who.modelData.ip !== ""
					text: who.modelData.ip
					font.bold: false
				}
				Label {
					id: plain
					x: 12
					visible: who.modelData.ip === ""
					color: Theme.dim
					text: who.modelData.name
				}
			}
		}

		Label { font.bold: true; text: String(view.nClients) }
		Repeater {
			model: view.on ? view.d.clients : []

			Label {
				required property var modelData
				font.bold: true
				text: modelData.info
			}
		}
	}

	// totals, from the laptop's side
	Rule { visible: view.on && view.nClients > 0; width: parent.width }
	Grid {
		visible: view.on && view.nClients > 0
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Sent"; color: Theme.dim }
		Label { font.bold: true; text: view.size(view.d?.tx ?? 0) }
		Label { text: "Received"; color: Theme.dim }
		Label { font.bold: true; text: view.size(view.d?.rx ?? 0) }
	}
}
