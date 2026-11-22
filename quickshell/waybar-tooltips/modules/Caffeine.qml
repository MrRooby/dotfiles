// custom/caffeine: whether the systemd inhibitor is held and for how long,
// the caffeine.sh tooltip as a popup. Clicking the bar module toggles it.
//
//   state     logind's inhibitor list (ListInhibitors over D-Bus via busctl,
//             as caffeine.sh asks `systemd-inhibit --list`): ours is the
//             entry whose WHO is waybar-caffeine. No Quickshell service
//             covers logind, hence the Process. Re-asked every 2 s while
//             open, since a click on the bar module flips it under the popup.
//   held for  the holder's start time, field 22 of /proc/<pid>/stat (USER_HZ,
//             100), against /proc/uptime
//   uptime    /proc/uptime

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	readonly property string who: "waybar-caffeine"
	// caffeine.sh's WHAT, the fallback before logind has listed the lock
	readonly property var defaultWhat: ["idle", "sleep", "handle-lid-switch", "handle-suspend-key"]

	// logind's answer: undefined until the first one arrives, null when off
	property var lock: undefined          // { pid, what: [] }
	readonly property bool ready: lock !== undefined
	readonly property bool on: lock != null
	readonly property int holderPid: lock ? lock.pid : 0

	property int uptime: 0
	property real startSecs: -1           // holder start, seconds since boot

	readonly property string align: "center"

	width: 295
	spacing: 7

	// ---- data ---------------------------------------------------------------

	Process {
		id: lister
		command: ["busctl", "call", "--json=short",
			"org.freedesktop.login1", "/org/freedesktop/login1",
			"org.freedesktop.login1.Manager", "ListInhibitors"]
		stdout: StdioCollector {
			onStreamFinished: view.parse(text)
		}
	}

	function query() {
		if (!lister.running)
			lister.running = true;
	}

	function parse(out) {
		let found = null;
		try {
			for (const e of JSON.parse(out).data[0]) {
				// [what, who, why, mode, uid, pid]
				if (e[1] === who) {
					found = { pid: e[5], what: e[0].split(":") };
					break;
				}
			}
		} catch (err) {
			// busctl failed: keep what we had, but stop hiding the popup
			if (lock === undefined)
				lock = null;
			return;
		}
		lock = found;
		readStart();
	}

	// one FileView per holder, made with its path already set: re-pointing a
	// single FileView and reading in the same call returns the old file
	Instantiator {
		id: stats
		model: view.holderPid > 0 ? [view.holderPid] : []
		delegate: FileView {
			required property var modelData
			path: "/proc/" + modelData + "/stat"
			blockLoading: true
			printErrors: false
		}
	}
	FileView { id: procUptime; path: "/proc/uptime"; blockLoading: true }

	function readStart() {
		const fv = stats.count > 0 ? stats.objectAt(0) : null;
		if (!fv) {
			startSecs = -1;
			return;
		}
		fv.reload();
		const s = fv.text();
		// comm is parenthesised and may hold spaces and ')': cut after the last
		const f = s.slice(s.lastIndexOf(") ") + 2).trim().split(/\s+/);
		const ticks = parseInt(f[19]);
		startSecs = fv.loaded && ticks >= 0 ? ticks / 100 : -1;
	}

	function tick() {
		procUptime.reload();
		uptime = Math.floor(parseFloat(procUptime.text()));
	}

	Component.onCompleted: {
		tick();
		query();
	}

	Timer {
		interval: 1000
		running: true
		repeat: true
		onTriggered: view.tick()
	}
	Timer {
		interval: 2000
		running: true
		repeat: true
		onTriggered: view.query()
	}

	// "41min", "9h 10min", "3d 4h", as fmt_dur in caffeine.sh
	function dur(s) {
		s = Math.max(0, Math.floor(s));
		if (s < 60)
			return s + "s";
		if (s < 3600)
			return Math.floor(s / 60) + "min";
		if (s < 86400)
			return Math.floor(s / 3600) + "h " + Math.floor(s % 3600 / 60) + "min";
		return Math.floor(s / 86400) + "d " + Math.floor(s % 86400 / 3600) + "h";
	}

	// logind's vocabulary, named the way the tooltip did, in caffeine.sh's order
	readonly property string inhibits: {
		const what = lock ? lock.what : defaultWhat;
		const names = {
			"idle": "idle", "sleep": "sleep",
			"handle-lid-switch": "lid", "handle-suspend-key": "power key"
		};
		const known = defaultWhat.filter(w => what.indexOf(w) >= 0);
		const rest = what.filter(w => defaultWhat.indexOf(w) < 0);
		return known.concat(rest).map(w => names[w] ?? w).join(" · ");
	}

	// ---- view -------------------------------------------------------------

	// headline: "Caffeine", the state on the right in its colour
	Headline {
		text: "Caffeine"
		note: view.on ? "on" : "off"
		noteColor: view.on ? Theme.ok : Theme.dim
	}

	Rule { width: parent.width }

	Grid {
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Uptime"; color: Theme.dim }
		Label { font.bold: true; text: view.dur(view.uptime) }

		Label { visible: held.visible; text: "Held for"; color: Theme.dim }
		Label {
			id: held
			visible: view.on && view.startSecs >= 0
			font.bold: true
			text: view.dur(view.uptime - view.startSecs)
		}

		Label { visible: view.on; text: "Inhibits"; color: Theme.dim }
		Label { visible: view.on; font.bold: true; text: view.inhibits }
	}
}
