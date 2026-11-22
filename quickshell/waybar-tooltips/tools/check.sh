#!/usr/bin/env bash
#
# Load one popup module without a window and report how it went.
#
#   tools/check.sh <Name> [seconds]     e.g. tools/check.sh Cpu 3
#
# Builds a throwaway shell next to $XDG_RUNTIME_DIR that symlinks the shared
# pieces (Theme, Label, ...) and modules/, so `import qs` resolves as in the
# real shell, then instantiates modules/<Name>.qml with no window: nothing
# appears on screen and the running popup shell is not touched. Prints QML
# warnings/errors, then the module's ready flag, implicit size and align.
# console.warn() from the module shows up too, for printing its data.
#
# Exit status 1 if the module failed to load.

set -uo pipefail

name=${1:?usage: check.sh <Name> [seconds]}
secs=${2:-3}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

[ -f "$here/modules/$name.qml" ] || { echo "no modules/$name.qml" >&2; exit 1; }

dir=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" qs-check.XXXXXX) || exit 1
trap 'rm -rf "$dir"' EXIT

for f in "$here"/*.qml; do
	[ "$(basename "$f")" = shell.qml ] && continue
	ln -s "$f" "$dir/"
done
ln -s "$here/modules" "$dir/modules"

cat > "$dir/shell.qml" <<EOF
import QtQuick
import Quickshell
ShellRoot {
	Loader {
		id: l
		source: Qt.resolvedUrl("modules/$name.qml")
	}
	Timer {
		interval: $secs * 1000
		running: true
		onTriggered: {
			const ok = l.status === Loader.Ready;
			console.warn("CHECK", ok ? "loaded" : "FAILED (status " + l.status + ")");
			if (ok)
				console.warn("CHECK ready=" + (l.item.ready ?? "(none)")
					+ " size=" + Math.round(l.item.implicitWidth) + "x" + Math.round(l.item.implicitHeight)
					+ " align=" + (l.item.align ?? "center"));
			Qt.exit(ok ? 0 : 1);
		}
	}
}
EOF

out=$(timeout $((secs + 5)) qs -p "$dir" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
	| grep -v -E 'INFO: (Launching|Shell ID|Saving logs|Configuration Loaded)|QQmlEngine::quit|QQmlEngine::exit')
printf '%s\n' "$out"
grep -q 'CHECK loaded' <<<"$out"
