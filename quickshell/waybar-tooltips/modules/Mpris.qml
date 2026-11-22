// mpris: what the bar's tooltip said ("Playing: {title} - {artist}"), as a
// popup: playback state, title and artist of the player waybar shows.
//
// From Quickshell.Services.Mpris (the MPRIS D-Bus players). The player is
// the first one playing, else the first one; playerctld is skipped, it only
// mirrors another player.

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs

Column {
	id: view

	property string align: "right"

	// players appear asynchronously on the bus: give them a moment, but
	// show right away once one is there
	property bool settled: false
	readonly property bool ready: settled || player !== null

	readonly property var player: {
		const ps = Mpris.players.values.filter(p => !p.dbusName.endsWith(".playerctld"));
		return ps.find(p => p.isPlaying) ?? ps[0] ?? null;
	}
	readonly property bool playing: player?.isPlaying ?? false
	readonly property real valueWidth: width - artistKey.implicitWidth - 16

	width: 350
	spacing: 7

	Timer {
		interval: 250
		running: true
		onTriggered: view.settled = true
	}

	Label {
		visible: view.player === null
		text: "Nothing playing"
		color: Theme.dim
	}

	// headline: playback state
	Label {
		visible: view.player !== null
		text: view.playing ? "Playing" : "Paused"
		color: view.playing ? Theme.ok : Theme.warm
		font.pixelSize: Theme.headSize
		font.bold: true
	}

	Rule { visible: view.player !== null; width: parent.width }

	Grid {
		visible: view.player !== null
		columns: 2
		columnSpacing: 16
		rowSpacing: 3

		Label { text: "Title"; color: Theme.dim }
		Label {
			width: view.valueWidth
			elide: Text.ElideRight
			font.bold: true
			text: view.player?.trackTitle || "-"
		}
		Label { id: artistKey; text: "Artist"; color: Theme.dim }
		Label {
			width: view.valueWidth
			elide: Text.ElideRight
			font.bold: true
			text: view.player?.trackArtist || "-"
		}
	}
}
