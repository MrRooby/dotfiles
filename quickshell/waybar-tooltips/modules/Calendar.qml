// custom/date: a month grid with ISO week numbers, browsable.
//
// Everything is drawn here from JS Date and the locale (Qt.locale(): month
// and weekday names), nothing is read from calendar.sh's output:
//   today    SystemClock, so the grid rolls over at midnight while open
//   view     the month offset calendar.sh keeps in
//            $XDG_RUNTIME_DIR/waybar-calendar.state (clamped to +-1200)
//
// The popup and the bar share that offset: scrolling the bar moves the
// popup (the file is watched), and the popup's buttons / wheel run
// `calendar.sh prev|next|today`, which writes the file and signals the bar.
// Those runs go through one Process, one at a time: the script is a
// read-modify-write of the file, so a fast wheel firing it concurrently
// would lose steps and leave the bar and the popup disagreeing.

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	readonly property string align: "center"

	width: 350
	spacing: 7

	readonly property int limit: 1200
	readonly property string script: Quickshell.env("HOME") + "/.config/waybar/scripts/calendar.sh"

	// the month being shown, relative to today; moves at once on input
	property int target: 0
	// what the state file holds (or will, once the running step lands)
	property int fileOffset: 0

	readonly property bool browsing: target !== 0
	readonly property var loc: Qt.locale()
	readonly property var cal: build(clock.date, target)

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	function clamp(n) {
		return Math.max(-limit, Math.min(limit, n));
	}

	function parse(s) {
		const t = (s ?? "").trim();
		return /^-?[0-9]+$/.test(t) ? clamp(parseInt(t, 10)) : 0;
	}

	FileView {
		id: stateFile
		path: Quickshell.env("XDG_RUNTIME_DIR") + "/waybar-calendar.state"
		blockLoading: true
		printErrors: false
		watchChanges: true
		// calendar.sh replaces the file with mv; the watch follows it, but
		// the new text only shows up in onLoaded, not in this handler
		onFileChanged: reload()
		onLoaded: {
			view.fileOffset = view.parse(text());
			// the bar was scrolled while the popup is open: follow it
			if (!runner.running)
				view.target = view.fileOffset;
		}
	}

	Component.onCompleted: {
		fileOffset = parse(stateFile.text());
		target = fileOffset;
	}

	// ---- navigation -------------------------------------------------------

	function go(delta) {
		target = clamp(target + delta);
		advance();
	}
	function today() {
		target = 0;
		advance();
	}

	// one calendar.sh step toward target; called again when it finishes
	property int expected: 0
	function advance() {
		if (runner.running || fileOffset === target)
			return;
		const cmd = target === 0 ? "today" : target < fileOffset ? "prev" : "next";
		expected = cmd === "today" ? 0 : clamp(fileOffset + (cmd === "prev" ? -1 : 1));
		runner.command = [script, cmd];
		runner.running = true;
	}

	Process {
		id: runner
		onExited: (code, status) => {
			if (code !== 0) {
				// the script failed: show what the file says and stop
				view.target = view.fileOffset;
				return;
			}
			view.fileOffset = view.expected;
			view.advance();
		}
	}

	// the wheel inside the popup steps months like the wheel on the bar:
	// up is back. Touchpads send small deltas, so whole notches are counted.
	property real wheelAcc: 0
	WheelHandler {
		onWheel: event => {
			view.wheelAcc += event.angleDelta.y;
			let steps = 0;
			while (view.wheelAcc >= 120) { view.wheelAcc -= 120; steps--; }
			while (view.wheelAcc <= -120) { view.wheelAcc += 120; steps++; }
			if (steps !== 0)
				view.go(steps);
		}
	}

	// ---- dates ------------------------------------------------------------

	// All grid arithmetic in UTC milliseconds, so a DST change can never
	// shift a day. Date.UTC normalises overflow (day 0, day -3, month 12),
	// which gives month lengths and the neighbouring months' days for free.
	readonly property real dayMs: 86400000

	function isoWeek(ms) {
		const dow = (new Date(ms).getUTCDay() + 6) % 7;   // Mon 0 .. Sun 6
		const thu = ms + (3 - dow) * dayMs;               // that week's Thursday
		const y = new Date(thu).getUTCFullYear();          // owns the week
		return 1 + Math.floor((thu - Date.UTC(y, 0, 1)) / dayMs / 7);
	}

	function build(now, off) {
		const ty = now.getFullYear(), tm = now.getMonth(), td = now.getDate();
		const idx = ty * 12 + tm + off;
		const vy = Math.floor(idx / 12), vm = idx - vy * 12;

		const lead = (new Date(Date.UTC(vy, vm, 1)).getUTCDay() + 6) % 7;
		const viewingToday = vy === ty && vm === tm;

		// six weeks every time, so the popup keeps its size while browsing;
		// the days of the months around it fill the gaps, faded
		const weeks = [];
		for (let r = 0; r < 6; r++) {
			const monday = Date.UTC(vy, vm, 1 - lead + 7 * r);
			const days = [];
			for (let c = 0; c < 7; c++) {
				const dt = new Date(monday + c * dayMs);
				const inMonth = dt.getUTCMonth() === vm;
				days.push({
					d: dt.getUTCDate(),
					inMonth: inMonth,
					weekend: c >= 5,
					today: inMonth && viewingToday && dt.getUTCDate() === td
				});
			}
			weeks.push({ week: isoWeek(monday), days: days });
		}

		const leap = (ty % 4 === 0 && ty % 100 !== 0) || ty % 400 === 0;
		const tUtc = Date.UTC(ty, tm, td);
		return {
			year: vy,
			// nominative ("listopad", not "listopada") for a heading
			month: loc.standaloneMonthName(vm, Locale.LongFormat),
			weeks: weeks,
			// same order as calendar.sh's '%A, %-d %B %Y'
			long: loc.dayName(now.getDay(), Locale.LongFormat) + ", " + td + " "
				+ loc.monthName(tm, Locale.LongFormat) + " " + ty,
			week: isoWeek(tUtc),
			doy: 1 + Math.round((tUtc - Date.UTC(ty, 0, 1)) / dayMs),
			yearDays: leap ? 366 : 365
		};
	}

	// Monday first, as in calendar.sh; two letters of the locale's short name
	readonly property var initials: [1, 2, 3, 4, 5, 6, 0]
		.map(d => loc.dayName(d, Locale.ShortFormat).slice(0, 2))

	function distance(n) {
		const a = Math.abs(n);
		const y = Math.floor(a / 12), m = a % 12;
		const parts = [];
		if (y) parts.push(y + (y === 1 ? " year" : " years"));
		if (m) parts.push(m + (m === 1 ? " month" : " months"));
		return parts.join(" ") + (n > 0 ? " ahead" : " back");
	}

	// ---- view -------------------------------------------------------------

	component NavButton: Rectangle {
		id: btn
		property string text: ""
		property bool lit: true
		signal clicked

		implicitWidth: Math.max(implicitHeight, lbl.implicitWidth + 14)
		implicitHeight: lbl.implicitHeight + 8
		color: hover.hovered ? Theme.accent : "transparent"
		border.color: hover.hovered ? Theme.accent : Theme.dim
		border.width: 1

		Label {
			id: lbl
			anchors.centerIn: parent
			text: btn.text
			font.pixelSize: Theme.chipSize
			font.bold: true
			color: hover.hovered ? Theme.bg : btn.lit ? Theme.fg : Theme.dim
		}
		HoverHandler {
			id: hover
			cursorShape: Qt.PointingHandCursor
		}
		TapHandler { onTapped: btn.clicked() }
	}

	// headline: month and year, the month buttons on the right (its own row
	// rather than Headline, which has no room for controls)
	Item {
		width: parent.width
		implicitHeight: Math.max(title.implicitHeight, nav.implicitHeight)

		Row {
			id: title
			spacing: 10
			Label {
				text: view.cal.month
				font.pixelSize: Theme.headSize
				font.bold: true
			}
			Label {
				text: view.cal.year
				color: Theme.accent
				font.pixelSize: Theme.headSize
				font.bold: true
			}
		}

		Row {
			id: nav
			anchors.right: parent.right
			anchors.verticalCenter: title.verticalCenter
			spacing: 4
			NavButton { text: "‹"; onClicked: view.go(-1) }
			NavButton {
				text: "today"
				lit: view.browsing
				onClicked: view.today()
			}
			NavButton { text: "›"; onClicked: view.go(1) }
		}
	}

	// today, whatever month is shown
	Label {
		text: view.cal.long
		color: Theme.dim
	}

	Rule { width: parent.width }

	// ISO week numbers down the left, then Monday..Sunday
	Grid {
		id: grid
		readonly property int weekW: 42
		readonly property int cellW: (view.width - weekW) / 7
		readonly property int cellH: Theme.fontSize + 10

		columns: 8
		columnSpacing: 0
		rowSpacing: 2

		Label {
			width: grid.weekW
			height: grid.cellH
			verticalAlignment: Text.AlignVCenter
			text: "wk"
			color: Theme.dim
			font.italic: true
		}
		Repeater {
			model: view.initials
			Label {
				required property string modelData
				width: grid.cellW
				height: grid.cellH
				horizontalAlignment: Text.AlignHCenter
				verticalAlignment: Text.AlignVCenter
				text: modelData
				color: Theme.dim
				font.italic: true
			}
		}

		Repeater {
			model: 48   // 6 weeks of (week number + 7 days)

			Label {
				required property int index
				readonly property int row: Math.floor(index / 8)
				readonly property int col: index % 8
				readonly property var week: view.cal.weeks[row]
				readonly property var day: col > 0 ? week.days[col - 1] : null

				width: col === 0 ? grid.weekW : grid.cellW
				height: grid.cellH
				horizontalAlignment: col === 0 ? Text.AlignLeft : Text.AlignHCenter
				verticalAlignment: Text.AlignVCenter

				text: day ? String(day.d) : String(week.week).padStart(2, "0")
				// today in the accent, bold and underlined; Saturday and
				// Sunday dim; the neighbouring months' days faded
				color: !day ? Theme.dim
					: day.today ? Theme.accent
					: day.weekend ? Theme.dim : Theme.fg
				opacity: !day ? (week.days.some(x => x.inMonth) ? 1 : 0.4)
					: day.inMonth ? 1 : 0.3
				font.bold: day?.today ?? false
				font.underline: day?.today ?? false
			}
		}
	}

	Rule { width: parent.width }

	// footer: where today sits in its year; while browsing, how far away the
	// view is, which also leads back
	Item {
		width: parent.width
		implicitHeight: weekLine.implicitHeight

		Label {
			id: weekLine
			text: "week " + String(view.cal.week).padStart(2, "0") + "  ·  day "
				+ view.cal.doy + " of " + view.cal.yearDays
			color: Theme.dim
		}

		Label {
			visible: view.browsing
			anchors.right: parent.right
			text: view.distance(view.target)
			color: back.hovered ? Theme.accent : Theme.dim
			HoverHandler {
				id: back
				cursorShape: Qt.PointingHandCursor
			}
			TapHandler { onTapped: view.today() }
		}
	}
}
