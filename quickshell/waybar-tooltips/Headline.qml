// The header every popup uses: a big bold title on the left and an optional
// small bold note on the right (state, device kind, output, ...), centred on
// each other. Spans its parent's width.
//   text, color          the title
//   note, noteColor      the note; hidden when empty

import QtQuick

Item {
	id: head

	property string text: ""
	property color color: Theme.fg
	property string note: ""
	property color noteColor: Theme.accent

	width: parent ? parent.width : implicitWidth
	implicitWidth: title.implicitWidth + (note !== "" ? 16 + side.implicitWidth : 0)
	implicitHeight: title.implicitHeight

	Label {
		id: title
		text: head.text
		color: head.color
		font.pixelSize: Theme.headSize
		font.bold: true
	}
	Label {
		id: side
		visible: head.note !== ""
		anchors.right: parent.right
		anchors.verticalCenter: title.verticalCenter
		text: head.note
		color: head.noteColor
		font.pixelSize: Theme.chipSize
		font.bold: true
	}
}
