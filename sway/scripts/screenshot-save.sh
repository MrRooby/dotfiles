#!/usr/bin/env bash
#
# Region screenshot, saved wherever the dialog says.
#
# The shot is taken first and the dialog opened after. The old one-liner,
# grim -g "$(slurp)" "$(zenity ...)", expanded both substitutions before grim
# ran, so the dialog was on screen -- or still fading out -- in the capture.
# Cancelling the selection or the dialog discards the shot.
#
# Bound in both sway's config and hyprland.conf.
#
# Requirements: grim, slurp, zenity

set -uo pipefail

geom=$(slurp) || exit 0

tmp=$(mktemp --suffix=.png -p "${XDG_RUNTIME_DIR:-/tmp}") || exit 1
trap 'rm -f "$tmp"' EXIT

grim -g "$geom" "$tmp" || exit 1

dest=$(zenity --file-selection --save --confirm-overwrite \
	--title='save screenshot WHEREE??' --filename='screenshot.png') || exit 0
[ -n "$dest" ] || exit 0

mv -f "$tmp" "$dest"
