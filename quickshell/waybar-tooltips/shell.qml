// Interactive tooltips for waybar modules.
//
//   qs -c waybar-tooltips
//
// waybar (a build of PR #5312, see ~/.config/waybar/scripts/waybar-run.sh)
// runs a module's on-enter / on-leave commands, which send one line each to
// $XDG_RUNTIME_DIR/waybar-tooltips.sock:
//
//   enter <Name> <output> <x> <width>
//       "enter Cpu DP-2 905 60": show modules/Cpu.qml under the bar on DP-2,
//       centred on the module at x 905..965 (from the bar's left edge). x and
//       width come from WAYBAR_MODULE_X / WAYBAR_MODULE_WIDTH, a local patch
//       on top of the PR build; without them the module's `align` is used.
//   leave
//
// The popup opens straight under the bar and stays while the pointer is on
// the module or on the popup, so it can be read, selected and clicked.
//
// Each popup is one file in modules/, created when it opens and destroyed
// when it closes. Shared pieces live next to this file: Theme (singleton:
// palette from waybar's current-theme.css), Label, Meter, Rule, Chip,
// CopyLabel. A module may expose `property bool ready`; the popup waits for
// it, so a module can take its first sample before showing. It may also set
// `property string align` ("left" / "right") to sit at that end of the bar.
//
// tools/check.sh <Name> loads one module without a window and reports errors.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
	id: root

	// what the last enter reported
	property string module: ""
	property string output: ""
	property int modX: -1    // -1: no position, fall back to align
	property int modW: 0

	property bool overModule: false
	property bool overPopup: false
	property bool open: false

	// Opening is instant; closing waits a few ms only so the pointer can
	// cross from waybar onto the popup (leave arrives before enter).
	onOverModuleChanged: sync()
	onOverPopupChanged: sync()
	function sync() {
		if (overModule || overPopup) {
			closeTimer.stop();
			open = true;
		} else {
			closeTimer.restart();
		}
	}
	Timer {
		id: closeTimer
		interval: 80
		onTriggered: root.open = root.overModule || root.overPopup
	}

	SocketServer {
		active: true
		path: Quickshell.env("XDG_RUNTIME_DIR") + "/waybar-tooltips.sock"
		handler: Socket {
			parser: SplitParser {
				onRead: line => {
					const p = line.trim().split(/\s+/);
					if (p[0] === "enter" && p.length >= 2 && /^[A-Z]\w*$/.test(p[1])) {
						root.module = p[1];
						root.output = p[2] ?? "";
						Popup.output = root.output;
						const x = parseInt(p[3]);
						root.modX = Number.isFinite(x) && x >= 0 ? x : -1;
						root.modW = parseInt(p[4]) || 0;
						root.overModule = true;
					} else if (p[0] === "leave") {
						root.overModule = false;
					}
				}
			}
		}
	}

	// the output the bar that sent the enter sits on; first screen if the
	// name is missing or unknown
	readonly property var screen: Quickshell.screens.find(s => s.name === output)
		?? Quickshell.screens[0]

	PanelWindow {
		id: popup

		screen: root.screen
		visible: root.open && content.status === Loader.Ready
			&& (content.item?.ready ?? true)

		// top-left anchored, zone 0: the compositor puts it right under
		// waybar's exclusive zone. waybar's hooks give no module position, so
		// a module says where it sits in the bar (`property string align`:
		// "left", "right", default "center") and the popup goes there.
		readonly property string align: content.item?.align ?? "center"
		anchors.top: true
		anchors.left: true
		exclusiveZone: 0
		// centred on the module when waybar said where it is, kept on screen
		margins.left: Math.max(0, Math.min(root.screen.width - implicitWidth,
			root.modX >= 0 ? root.modX + root.modW / 2 - implicitWidth / 2
			: align === "left" ? 0
			: align === "right" ? root.screen.width - implicitWidth
			: (root.screen.width - implicitWidth) / 2))
		WlrLayershell.layer: WlrLayer.Overlay
		WlrLayershell.namespace: "waybar-tooltip"

		implicitWidth: box.implicitWidth
		implicitHeight: box.implicitHeight
		color: "transparent"

		Rectangle {
			id: box
			implicitWidth: content.implicitWidth + 20
			implicitHeight: content.implicitHeight + 16
			color: Theme.bg
			border.color: Theme.accent
			border.width: 2

			HoverHandler { onHoveredChanged: root.overPopup = hovered }

			Loader {
				id: content
				x: 10
				y: 8
				// created on open, destroyed on close, so nothing polls while
				// no popup is up
				active: root.open && root.module !== ""
				source: root.module !== "" ? Qt.resolvedUrl("modules/" + root.module + ".qml") : ""
			}
		}
	}
}
