// A horizontal meter: dim trough, fill in the colour of the value it shows.
//   value  0..100
//   fill   defaults to Theme.ramp(value); set it for meters where high is
//          not bad (battery charge, signal strength, volume)

import QtQuick

Item {
	id: meter

	property real value: 0
	property color fill: Theme.ramp(value)

	implicitHeight: 6

	Rectangle {
		anchors.fill: parent
		color: Theme.dim
		opacity: 0.18
	}
	Rectangle {
		height: parent.height
		width: parent.width * Math.max(0, Math.min(100, meter.value)) / 100
		color: meter.fill
		Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
		Behavior on color { ColorAnimation { duration: 250 } }
	}
}
