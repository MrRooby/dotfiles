// A small inverted badge, the look of the active profile button in the bar:
// background in `tint`, text in the popup background colour.
//   icon   Nerd Font glyph, written as a \u escape ("", "\u{f029a}")
//   text   label

import QtQuick

Rectangle {
	id: chip

	property string icon: ""
	property string text: ""
	property color tint: Theme.accent

	implicitWidth: row.implicitWidth + 14
	implicitHeight: row.implicitHeight + 4
	color: tint
	Behavior on color { ColorAnimation { duration: 250 } }

	Row {
		id: row
		anchors.centerIn: parent
		spacing: 6
		Label {
			visible: chip.icon !== ""
			text: chip.icon
			color: Theme.bg
			font.pixelSize: Theme.chipSize + 1
		}
		Label {
			text: chip.text
			color: Theme.bg
			font.pixelSize: Theme.chipSize
			font.bold: true
		}
	}
}
