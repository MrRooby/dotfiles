// A value you can click to copy (IPs, MACs, names). The popup never gets
// keyboard focus, so Ctrl+C on a selection does not work; this does.
// Shows the copy affordance on hover and flashes "copied" after a click.
//   text   what is shown
//   value  what is copied, defaults to text

import QtQuick
import Quickshell

Label {
	id: label

	property string value: text

	font.bold: true
	color: hover.hovered ? Theme.accent : Theme.fg
	opacity: flash.running ? 0.5 : 1

	HoverHandler {
		id: hover
		cursorShape: Qt.PointingHandCursor
	}
	TapHandler {
		onTapped: {
			Quickshell.execDetached(["wl-copy", "--", label.value]);
			flash.restart();
		}
	}
	Timer {
		id: flash
		interval: 300
	}
}
