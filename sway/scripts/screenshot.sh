#!/usr/bin/env bash
#
# Region screenshot that keeps tooltips, popups and hover states.
#
#   screenshot.sh          copy the region to the clipboard
#   screenshot.sh --save   save the region wherever the dialog says
#
# The whole screen is captured BEFORE slurp starts. slurp's overlay takes the
# pointer, so the app under the cursor gets a pointer-leave and drops its
# tooltip; capturing after the selection (what hyprshot does) loses it. The
# selection is then cropped out of the earlier capture. The tooltip vanishes
# from the screen while you drag, but it is in the picture.
#
# Bound to PrtSc, not Super+something: Firefox drops a tooltip on any key
# press it receives, and the compositor still hands it the bare Super press.
# A lone PrtSc binding is swallowed whole, so the app never sees a key.
#
# Bound in both sway's config and hyprland.conf.
#
# Requirements: grim, slurp, jq, magick (ImageMagick), wl-copy, zenity (--save)

set -uo pipefail

mode=${1:-clipboard}

# Layout origin and grim's scale (the largest output scale), so slurp's
# logical coordinates can be mapped onto pixels of the full capture.
if [ -n "${SWAYSOCK:-}" ]; then
	outputs=$(swaymsg -t get_outputs -r | jq '[.[] | select(.active) | {x: .rect.x, y: .rect.y, scale}]')
elif [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
	outputs=$(hyprctl monitors -j | jq '[.[] | {x, y, scale}]')
else
	echo "screenshot.sh: neither sway nor Hyprland" >&2
	exit 1
fi
read -r minx miny scale < <(jq -r '"\(map(.x) | min) \(map(.y) | min) \(map(.scale) | max)"' <<<"$outputs")

tmpdir=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
full=$tmpdir/full.png
shot=$tmpdir/shot.png

grim -s "$scale" "$full" || exit 1

geom=$(slurp) || exit 0    # Esc / right click cancels

# "X,Y WxH" (logical) -> "WxH+X+Y" (pixels in the capture)
crop=$(awk -v s="$scale" -v ox="$minx" -v oy="$miny" '{
	split($1, p, ","); split($2, d, "x")
	printf "%dx%d+%d+%d", d[1]*s + 0.5, d[2]*s + 0.5, (p[1]-ox)*s + 0.5, (p[2]-oy)*s + 0.5
}' <<<"$geom")

magick "$full" -crop "$crop" +repage "$shot" || exit 1

case $mode in
	--save)
		dest=$(zenity --file-selection --save --confirm-overwrite \
			--title='save screenshot WHEREE??' --filename='screenshot.png') || exit 0
		[ -n "$dest" ] || exit 0
		cp -f "$shot" "$dest"
		;;
	*)
		wl-copy --type image/png <"$shot"
		command -v notify-send >/dev/null && notify-send -a screenshot -t 3000 "Screenshot copied"
		;;
esac
