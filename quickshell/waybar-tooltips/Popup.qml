pragma Singleton

// What the current popup is for, for modules that need it. shell.qml sets it
// from the `enter` line before the module is created, so it is right from the
// module's first frame (the popup window's own screen only follows a moment
// later when the pointer moves to a bar on another output).

import Quickshell

Singleton {
	// output of the bar whose module opened the popup, e.g. "DP-2"
	property string output: ""
}
