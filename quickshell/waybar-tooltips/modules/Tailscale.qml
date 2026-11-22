// custom/tailscale: a port of tailscale.sh's tooltip -- this device, the exit
// node, and every peer on the tailnet, with click-to-copy addresses.
//
// There is no file or D-Bus service with this, so it is `tailscale status
// --json` (about 10 ms) every 2.5 s while the popup is open. Shown as in
// tailscale.sh's tooltip:
//   peers    online first (active connections on top, then by name), a rule,
//            then offline ones, most recently seen first
//   name     the MagicDNS label (what `tailscale status` prints), HostName
//            only when there is none: phones report "localhost" and the like
//   state    "Nm/h/d ago" when offline, "direct" / "relay <region>" for an
//            active connection, "idle" otherwise, "· exit" on the exit node
// Copying: a name copies its MagicDNS name, an IP its IPv4, right-click on an
// IP its IPv6.
// Clicks on the bar module itself (up/down, exit node) are unchanged.

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	// { state: "running" | "logged out" | "off", ... } once the first
	// status is in
	property var d: null
	readonly property bool ready: d !== null
	readonly property string align: "center"
	readonly property bool running: d?.state === "running"
	readonly property var peers: running ? d.peers : []

	// columns are measured in characters (the font is monospace), so names
	// and IPs line up like the old pango table
	readonly property real cw: metrics.advanceWidth
	readonly property int gap: 14
	readonly property int nameW: Math.ceil(cw * Math.min(20, maxLen("name", 8)))
	readonly property int ipW: Math.ceil(cw * maxLen("ip", 13))
	readonly property int osW: Math.ceil(cw * maxLen("os", 5))
	readonly property int stateW: Math.ceil(cw * maxLen("state", 6))
	readonly property int tableW: Math.ceil(cw) + nameW + ipW + osW + stateW + gap * 4
	readonly property int headW: tsHead.implicitWidth

	width: Math.max(350, tableW, headW)
	spacing: 7

	TextMetrics {
		id: metrics
		font.family: Theme.font
		font.pixelSize: Theme.fontSize
		font.bold: true
		text: "0"
	}

	function maxLen(key, min) {
		let n = min;
		for (const p of peers)
			n = Math.max(n, p[key].length);
		return n;
	}

	// ---- data --------------------------------------------------------------

	Process {
		id: status
		command: ["tailscale", "status", "--json"]
		stdout: StdioCollector {
			onStreamFinished: view.parse(text)
		}
	}

	Timer {
		interval: 2500
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!status.running) status.running = true
	}

	// no tailscale binary: the process never reports, so show "Off" rather
	// than keep the popup hidden
	Timer {
		interval: 500
		running: view.d === null
		onTriggered: if (view.d === null) view.d = { state: "off" }
	}

	function label(n) {
		return (n.DNSName ?? "").split(".")[0] || n.HostName || "?";
	}

	// ms since the epoch, 0 for never / unknown ("0001-01-01T00:00:00Z")
	function seen(n) {
		const t = Date.parse((n.LastSeen ?? "").replace(/\.\d+/, ""));
		return isNaN(t) || t < 946684800000 ? 0 : t;
	}

	function ago(t) {
		if (t === 0)
			return "offline";
		const s = (Date.now() - t) / 1000;
		return s < 3600 ? Math.floor(s / 60) + "m ago"
			: s < 86400 ? Math.floor(s / 3600) + "h ago"
			: Math.floor(s / 86400) + "d ago";
	}

	function peerState(n, t) {
		const s = !n.Online ? ago(t)
			: n.Active && n.CurAddr ? "direct"
			: n.Active ? "relay " + n.Relay
			: "idle";
		return s + (n.ExitNode ? " · exit" : "");
	}

	function addrs(n) {
		const ips = n.TailscaleIPs ?? [];
		return {
			ip: ips.find(a => !a.includes(":")) ?? "-",
			ip6: ips.find(a => a.includes(":")) ?? "",
			dns: (n.DNSName ?? "").replace(/\.$/, "")
		};
	}

	function parse(text) {
		let j;
		try {
			j = JSON.parse(text);
		} catch (e) {
			set({ state: "off" });
			return;
		}
		if (j.BackendState !== "Running") {
			set({ state: j.BackendState === "NeedsLogin" ? "logged out" : "off" });
			return;
		}

		const all = Object.values(j.Peer ?? {}).map(n => {
			const t = seen(n);
			return Object.assign(addrs(n), {
				name: label(n),
				os: n.OS ?? "",
				online: !!n.Online,
				active: !!n.Active,
				exit: !!n.ExitNode,
				seen: t,
				state: peerState(n, t)
			});
		});
		const byName = (a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
		const online = all.filter(p => p.online)
			.sort((a, b) => (b.active - a.active) || byName(a, b));
		const offline = all.filter(p => !p.online)
			.sort((a, b) => b.seen - a.seen);
		const peers = online.concat(offline);

		const self = j.Self ?? {};
		set({
			state: "running",
			self: Object.assign(addrs(self), { name: label(self) }),
			exitNode: all.find(p => p.exit)?.name ?? "",
			peers: peers
		});
	}

	// only when something changed: a new array rebuilds every peer row,
	// which would drop hover and the copy flash under the pointer
	function set(next) {
		if (JSON.stringify(next) !== JSON.stringify(d))
			d = next;
	}

	// ---- pieces --------------------------------------------------------------

	// a CopyLabel that also copies `alt` on right-click, and can be faded
	// for offline rows (still turns accent on hover)
	component Copy: Item {
		id: c

		property string text: ""
		property string value: text
		property string alt: ""
		property bool bold: true
		property bool faded: false

		implicitWidth: cl.implicitWidth
		implicitHeight: cl.implicitHeight
		opacity: (altFlash.running ? 0.5 : 1) * (faded ? 0.55 : 1)

		CopyLabel {
			id: cl
			width: c.width
			elide: Text.ElideRight
			text: c.text
			value: c.value
			font.bold: c.bold
		}
		TapHandler {
			enabled: c.alt !== ""
			acceptedButtons: Qt.RightButton
			onTapped: {
				Quickshell.execDetached(["wl-copy", "--", c.alt]);
				altFlash.restart();
			}
		}
		Timer {
			id: altFlash
			interval: 300
		}
	}

	// ---- view ----------------------------------------------------------------

	// header: "Tailscale", this device (or off / logged out) on the right
	Headline {
		id: tsHead
		text: "Tailscale"
		note: view.running ? view.d.self.name : view.d?.state ?? ""
		noteColor: view.running ? Theme.accent : Theme.dim
	}

	// this device's tailnet IP (click: IPv4, right-click: IPv6), exit node
	Grid {
		visible: view.running
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		readonly property string exitNode: view.d?.exitNode ?? ""

		Label { text: "IP"; color: Theme.dim }
		Copy {
			text: view.d?.self?.ip ?? ""
			alt: view.d?.self?.ip6 ?? ""
		}
		Label { text: "Exit node"; color: Theme.dim }
		Label {
			text: parent.exitNode || "off"
			color: parent.exitNode ? Theme.ok : Theme.dim
			font.bold: parent.exitNode !== ""
		}
	}

	Rule {
		visible: view.running
		width: parent.width
	}

	Label {
		visible: view.running && view.peers.length === 0
		text: "no other devices"
		color: Theme.dim
	}

	// peers: dot, name, IP, OS, state; a rule between online and offline
	Column {
		visible: view.peers.length > 0
		width: parent.width
		spacing: 3

		Repeater {
			model: view.peers

			Column {
				id: row

				required property var modelData
				required property int index
				readonly property var p: modelData
				readonly property bool firstOffline: !p.online && index > 0
					&& view.peers[index - 1].online

				width: parent.width
				spacing: 3

				Rule {
					visible: row.firstOffline
					width: parent.width
				}

				Row {
					spacing: view.gap

					Label {
						width: view.cw
						text: row.p.online ? "●" : "○"
						color: row.p.online ? Theme.ok : Theme.dim
					}
					Copy {
						width: view.nameW
						text: row.p.name
						value: row.p.dns || row.p.name
						faded: !row.p.online
					}
					Copy {
						width: view.ipW
						text: row.p.ip
						alt: row.p.ip6
						bold: false
						faded: !row.p.online
					}
					Label {
						width: view.osW
						text: row.p.os
						color: Theme.dim
					}
					Label {
						width: view.stateW
						horizontalAlignment: Text.AlignRight
						text: row.p.state
						color: row.p.online ? Theme.fg : Theme.dim
					}
				}
			}
		}
	}
}
