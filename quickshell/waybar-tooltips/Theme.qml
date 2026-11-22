pragma Singleton

// waybar's palette for every popup: the @define-color lines of
// ~/.config/waybar/current-theme.css, @references followed until a hex falls
// out. Watched, so switching the waybar theme recolours the popups live.
// Fallbacks are nostromo, for the moment before the file is read.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: theme

	readonly property string font: "JetBrainsMono Nerd Font Mono"

	// text sizes for every popup, in px: body (labels, values), the headline
	// figure, and chips / small headings
	readonly property int fontSize: 12
	readonly property int headSize: 20
	readonly property int chipSize: 13

	property var palette: ({})

	// any @define-color by name, e.g. color("pp-turbo", accent)
	function color(name, fallback) {
		return palette[name] ?? fallback;
	}

	readonly property color bg: color("tooltip-bg", "#11111b")
	readonly property color fg: color("tooltip-fg", "#d8cab8")
	readonly property color dim: color("tooltip-dim", "#9b9b9b")
	readonly property color ok: color("tooltip-ok", "#57AE3A")
	readonly property color warm: color("warning", "#f9e2af")
	readonly property color crit: color("critical", "#f38ba8")
	readonly property color accent: color("tooltip-br", "#CE6B29")

	// green while there is room, warm once it works, red when pegged. The
	// 75/90 defaults are the lines states.css colours bar modules with.
	function ramp(pct, warmAt, critAt) {
		const w = warmAt ?? 75;
		const c = critAt ?? 90;
		return pct >= c ? crit : pct >= w ? warm : ok;
	}

	FileView {
		path: Quickshell.env("HOME") + "/.config/waybar/current-theme.css"
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			// (no String.matchAll in Qt's JS engine)
			const raw = {};
			const re = /@define-color\s+([\w-]+)\s+([^;]+);/g;
			const css = text();
			let m;
			while ((m = re.exec(css)) !== null)
				raw[m[1]] = m[2].trim();
			const out = {};
			for (const k in raw) {
				let v = raw[k];
				for (let i = 0; i < 10 && v && v.startsWith("@"); i++)
					v = raw[v.slice(1)];
				if (v && /^#[0-9a-fA-F]{3,8}$/.test(v))
					out[k] = v;
			}
			theme.palette = out;
		}
	}
}
