// pulseaudio#output + pulseaudio#input: the default output and input
// device, as the old tooltips showed them ("Output Device: {desc}",
// "Input Device: {desc}").
//
// Read live from Quickshell's PipeWire service: the default sink and
// source and their node descriptions.

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs

Column {
	id: view

	property string align: "right"

	readonly property var sink: Pipewire.defaultAudioSink
	readonly property var source: Pipewire.defaultAudioSource
	readonly property bool ready: Pipewire.ready

	readonly property int labelW: 48

	width: 330
	spacing: 7

	PwObjectTracker {
		objects: [view.sink, view.source].filter(n => n)
	}

	function desc(n) {
		return n ? n.description || n.nickname || n.name : "none";
	}

	Grid {
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Output"; color: Theme.dim; width: view.labelW }
		Label {
			width: view.width - view.labelW - 16
			wrapMode: Text.Wrap
			font.bold: true
			text: view.desc(view.sink)
		}
		Label { text: "Input"; color: Theme.dim; width: view.labelW }
		Label {
			width: view.width - view.labelW - 16
			wrapMode: Text.Wrap
			font.bold: true
			text: view.desc(view.source)
		}
	}
}
