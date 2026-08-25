#!/usr/bin/env bash
#
# Launch waybar with the fast-tooltip shim, building it on first run.
#
#   exec ~/.config/waybar/scripts/waybar-run.sh      # from the sway config
#
# GTK3 waits 500ms before showing a tooltip and offers no way to change it, so
# tools/fast-tooltip.c interposes the timer -- see the comment at the top of
# that file for how and why. Everything here is best effort: if the compiler
# or the glib headers are missing, or the build fails, waybar is started
# unmodified and tooltips are simply slow.
#
# The build lives here rather than in install.sh because sway's exec line is
# the only entry point most people ever use again after installing, and a
# stale or missing .so should not need a reinstall to fix.

set -uo pipefail
export LC_ALL=C.utf8

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/tools/fast-tooltip.c"
lib="$root/lib/libfasttooltip.so"

# ---- build ---------------------------------------------------------------

build() {
	command -v gcc >/dev/null || return 1
	command -v pkg-config >/dev/null || return 1
	pkg-config --exists glib-2.0 || return 1

	mkdir -p "$root/lib" || return 1

	# to a temp name first, so a half-written .so is never preloaded into
	# waybar if this is interrupted
	local tmp="$lib.$$"
	if gcc -shared -fPIC -O2 -o "$tmp" "$src" \
		$(pkg-config --cflags glib-2.0) 2>/dev/null; then
		mv -f "$tmp" "$lib"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

if [ -f "$src" ] && { [ ! -f "$lib" ] || [ "$src" -nt "$lib" ]; }; then
	build
fi

# ---- launch --------------------------------------------------------------

if [ -f "$lib" ]; then
	exec env LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$lib" waybar "$@"
fi

exec waybar "$@"
