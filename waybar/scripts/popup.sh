#!/usr/bin/env bash
#
# Toggle a floating TUI popup (wlctl, bluetui) on the screen whose bar was
# clicked.
#
#   popup.sh <window-class> <command...>
#
# sway opens a new window on the focused output, not on the one whose bar
# took the click, and the old rule pinned the popup to an absolute position
# (610,30) that is always on the first screen. So: focus the clicked output
# first, launch, then place the window top-centre on that output.
#
# waybar exports WAYBAR_OUTPUT_NAME to the commands it runs; when it is
# missing the popup falls back to whichever output has focus.

set -uo pipefail

class=$1; shift

W=700 H=700   # must match the resize in the sway for_window rule
TOP=30        # clears the bar

has_window() {
	swaymsg -t get_tree | jq -e --arg c "$class" \
		'[.. | objects | select(.window_properties?.class == $c)] | length > 0' >/dev/null
}

# a second click closes it
if has_window; then
	swaymsg -q "[class=\"$class\"] kill"
	exit 0
fi

out=${WAYBAR_OUTPUT_NAME:-}
[ -n "$out" ] && swaymsg -q focus output "$out"

read -r ox oy ow < <(swaymsg -t get_outputs | jq -r --arg o "$out" '
	[ .[] | select(if $o == "" then .focused else .name == $o end) ][0].rect
	| "\(.x) \(.y) \(.width)"')

# the palette for the active theme, from themes/kitty/<theme>.conf, loaded on
# top of the normal kitty.conf; without one the popup looks like any kitty
theme=$(awk 'NR == 1 {print $2; exit}' ~/.config/waybar/current-theme.css 2>/dev/null)
palette=~/.config/waybar/themes/kitty/$theme.conf
cfg=(--config ~/.config/kitty/kitty.conf)
[ -r "$palette" ] && cfg+=(--config "$palette")

kitty "${cfg[@]}" --class "$class" -o background_opacity=1.0 -o confirm_os_window_close=0 -e "$@" >/dev/null 2>&1 &

# the window takes a moment to map; place it as soon as sway knows it
for _ in $(seq 1 60); do
	has_window && break
	sleep 0.05
done
swaymsg -q "[class=\"$class\"] move absolute position $(( ox + (ow - W) / 2 )) $(( oy + TOP ))"
