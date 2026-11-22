// custom/wpm: typing speed, the tooltip of wpm.sh.
//
// Straight from the rusty-word-count daemon, the same source wpm.sh reads:
// its socket takes the request line "watch json" and answers with one JSON
// line now and another whenever the score changes, e.g.
//   {"wpm":62,"average":42,"peak":92,"chars":39670,"active_secs":11337}
// The live figure is 0 during a pause, so, as in the bar, the average is the
// current figure then; the current one of the two is marked in accent.

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	property string align: "right"

	property var d: null          // last snapshot from the daemon
	property bool offline: false  // socket missing or the daemon went away
	property bool timedOut: false
	readonly property bool ready: d !== null || offline || timedOut

	readonly property bool typing: (d?.wpm ?? 0) > 0
	readonly property bool showData: d !== null && !offline

	// as wide as the figures, not a fixed width
	width: showData ? Math.max(wpmHead.implicitWidth, liveGrid.implicitWidth, totalGrid.implicitWidth) : offlineLabel.implicitWidth
	spacing: 7

	Socket {
		id: sock
		path: Quickshell.env("XDG_RUNTIME_DIR") + "/rusty-word-count.sock"
		connected: true

		onConnectionStateChanged: {
			if (connected) {
				view.offline = false;
				write("watch json\n");
				flush();
			} else {
				view.offline = true;
			}
		}
		onError: view.offline = true

		parser: SplitParser {
			onRead: line => {
				try {
					const j = JSON.parse(line);
					if (j.wpm === undefined)
						return;
					view.d = j;
					view.offline = false;
				} catch (e) {}
			}
		}
	}

	// the daemon may start (or restart) while the popup is open
	Timer {
		interval: 2000
		running: view.offline
		repeat: true
		onTriggered: sock.connected = true
	}

	// never keep the popup hidden for long
	Timer {
		interval: 300
		running: true
		onTriggered: view.timedOut = true
	}

	// "3m 48s", "1h 05m", as in wpm.sh
	function duration(s) {
		const pad = n => String(n).padStart(2, "0");
		if (s >= 3600)
			return Math.floor(s / 3600) + "h " + pad(Math.floor(s % 3600 / 60)) + "m";
		if (s >= 60)
			return Math.floor(s / 60) + "m " + pad(s % 60) + "s";
		return s + "s";
	}

	// ---- view -------------------------------------------------------------

	Label {
		id: offlineLabel
		visible: !view.showData
		text: "rusty-word-count is not running"
		color: Theme.dim
	}

	Headline {
		id: wpmHead
		visible: view.showData
		text: "Typing"
	}

	Rule { visible: view.showData; width: parent.width }

	Grid {
		id: liveGrid
		visible: view.showData
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label {
			text: "Live"
			color: view.typing ? Theme.accent : Theme.dim
			font.bold: view.typing
		}
		Label {
			text: (view.d?.wpm ?? 0) + " WPM"
			color: view.typing ? Theme.accent : Theme.fg
			font.bold: true
		}
		Label {
			text: "Average"
			color: !view.typing ? Theme.accent : Theme.dim
			font.bold: !view.typing
		}
		Label {
			text: (view.d?.average ?? 0) + " WPM"
			color: !view.typing ? Theme.accent : Theme.fg
			font.bold: true
		}
		Label { text: "Peak"; color: Theme.dim }
		Label {
			text: (view.d?.peak ?? 0) + " WPM"
			font.bold: true
		}
	}

	Rule { visible: view.showData; width: parent.width }

	Grid {
		id: totalGrid
		visible: view.showData
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Words"; color: Theme.dim }
		Label {
			text: Math.floor((view.d?.chars ?? 0) / 5)
			font.bold: true
		}
		Label { text: "Time"; color: Theme.dim }
		Label {
			text: view.duration(view.d?.active_secs ?? 0)
			font.bold: true
		}
	}
}
