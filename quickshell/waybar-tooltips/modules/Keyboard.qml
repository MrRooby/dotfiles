// custom/keyboard: battery of both Corne halves, as corne.sh shows them.
//
//   left   the central half: BlueZ's Battery1 on the device, which
//          Quickshell.Bluetooth exposes as battery/batteryAvailable
//   right  the peripheral half: ZMK relays it as a second Battery Level
//          characteristic that no service mirrors, so it is a live GATT
//          ReadValue over busctl (same path and 2 s timeout as corne.sh),
//          once on open and every 10 s while open
//
// A straight port of corne.sh's tooltip: title, then label / percentage /
// gauge per half, gauges in the accent while fine, warning at <= 20 %,
// critical at <= 10 %, "not connected" for a half with no reading.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs

Column {
	id: view

	readonly property string align: "right"

	readonly property string address: "FC:6D:F5:51:64:3B"
	readonly property string rightChar:
		"/org/bluez/hci0/dev_FC_6D_F5_51_64_3B/service0015/char0016"

	readonly property int warnAt: 20
	readonly property int critAt: 10

	readonly property BluetoothDevice dev:
		Bluetooth.devices.values.find(d => d.address === view.address) ?? null
	readonly property bool connected: dev?.connected ?? false

	// percentages, -1 while that half has no reading
	readonly property int leftPct: connected && dev.batteryAvailable
		? Math.round(dev.battery * 100) : -1
	property int rightPct: -1
	property bool rightRead: false
	property bool waited: false

	// the GATT read is over the air; give it a moment, then show what's there
	readonly property bool ready: rightRead || waited

	width: 275
	spacing: 7

	function tint(p) {
		return p <= critAt ? Theme.crit : p <= warnAt ? Theme.warm : Theme.accent;
	}

	// "ay 1 44": one byte, the level
	Process {
		id: rightProc
		running: true
		command: ["busctl", "--timeout=2", "call", "org.bluez", view.rightChar,
			"org.bluez.GattCharacteristic1", "ReadValue", "a{sv}", "0"]
		stdout: StdioCollector {
			onStreamFinished: {
				const m = /^ay\s+\d+\s+(\d+)/.exec(text.trim());
				view.rightPct = m ? parseInt(m[1]) : -1;
				view.rightRead = true;
			}
		}
	}

	function readRight() {
		if (!rightProc.running)
			rightProc.running = true;
	}

	Timer {
		interval: 10000
		running: true
		repeat: true
		onTriggered: view.readRight()
	}
	Timer {
		interval: 300
		running: true
		onTriggered: view.waited = true
	}

	// the right half answers once the link is up
	onConnectedChanged: if (connected) readRight()

	// ---- view -------------------------------------------------------------

	Headline { text: "Corne" }

	Rule { width: parent.width }

	// one row per half: label, percentage, gauge
	Grid {
		width: parent.width
		columns: 3
		columnSpacing: 16
		rowSpacing: 3
		verticalItemAlignment: Grid.AlignVCenter

		Label { width: 44; text: "Left"; color: Theme.dim }
		Label {
			width: 40
			horizontalAlignment: Text.AlignRight
			font.bold: view.leftPct >= 0
			color: view.leftPct >= 0 ? Theme.fg : Theme.dim
			text: view.leftPct >= 0 ? view.leftPct + "%" : ""
		}
		Item {
			width: view.width - 44 - 40 - 2 * 16
			implicitHeight: 8
			Meter {
				visible: view.leftPct >= 0
				anchors.fill: parent
				value: view.leftPct
				fill: view.tint(view.leftPct)
			}
			Label {
				visible: view.leftPct < 0
				anchors.verticalCenter: parent.verticalCenter
				text: "not connected"
				color: Theme.dim
			}
		}

		Label { width: 44; text: "Right"; color: Theme.dim }
		Label {
			width: 40
			horizontalAlignment: Text.AlignRight
			font.bold: view.rightPct >= 0
			color: view.rightPct >= 0 ? Theme.fg : Theme.dim
			text: view.rightPct >= 0 ? view.rightPct + "%" : ""
		}
		Item {
			width: view.width - 44 - 40 - 2 * 16
			implicitHeight: 8
			Meter {
				visible: view.rightPct >= 0
				anchors.fill: parent
				value: view.rightPct
				fill: view.tint(view.rightPct)
			}
			Label {
				visible: view.rightPct < 0
				anchors.verticalCenter: parent.verticalCenter
				text: view.rightRead ? "not connected" : "reading…"
				color: Theme.dim
			}
		}
	}
}
