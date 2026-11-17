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
	pkg-config --exists gtk+-3.0 || return 1

	mkdir -p "$root/lib" || return 1

	# to a temp name first, so a half-written .so is never preloaded into
	# waybar if this is interrupted
	local tmp="$lib.$$"
	if gcc -shared -fPIC -O2 -o "$tmp" "$src" \
		$(pkg-config --cflags gtk+-3.0) 2>/dev/null; then
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

# waybar built from PR #5312 (on-enter/on-leave hooks, used for the
# Quickshell popups) plus a local patch exporting WAYBAR_OUTPUT_NAME to them.
# Built in ~/src/waybar-pr5312 and copied here, see the comment in
# modules/custom/cpu.jsonc. A Fedora library bump can leave it unable to
# start, so it is only used if --version runs; otherwise the packaged waybar
# starts and the bar is still there (modules relying on the hooks just lose
# their popup). Once the PR ships in a release, delete the binary.
bin=waybar
pr="$HOME/.local/lib/waybar-pr5312/waybar"   # named waybar so pkill -x waybar finds it
if [ -x "$pr" ] && "$pr" --version >/dev/null 2>&1; then
	bin=$pr
fi

if [ -f "$lib" ]; then
	exec env LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$lib" "$bin" "$@"
fi

exec "$bin" "$@"
