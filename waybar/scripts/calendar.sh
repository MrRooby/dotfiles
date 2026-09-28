#!/usr/bin/env bash
#
# Calendar module for waybar: the date in the bar, a month grid in the tooltip.
#
#   calendar.sh          -> waybar json for the current view
#   calendar.sh prev     -> step the view back one month
#   calendar.sh next     -> step it forward
#   calendar.sh today    -> back to the current month
#
# Replaces the built-in "clock#date". Waybar draws {calendar} itself and the
# only styling it takes is pango inside the calendar.format strings, which have
# to carry a literal hex colour. This fork's palette lives in current-theme.css
# and the theme switcher works by copying a file over it, so a hardcoded accent
# there would stop tracking the theme the moment you switched -- the same
# reason battery.sh renders its own tooltip rather than using tooltip-format.
#
# What the built-in gave up in exchange: its click action cycled a year view.
# Scrolling through months and clicking back to today is the trade.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes (the header lines
# contain a multi-byte "·" and are centred by length). The month and weekday
# names deliberately follow the user's locale, which is why LC_TIME is left
# alone below.
export LC_ALL=C.utf8

ICON="󰸗"
SIGNAL=10

state="${XDG_RUNTIME_DIR:-/tmp}/waybar-calendar.state"

# ---- theme colours -------------------------------------------------------

# Same lookup as battery.sh: pango only takes literal hex, so the palette is
# read from current-theme.css and @references are followed until a hex falls
# out. Anything unresolved paints nothing and inherits styles/tooltips.css.

declare -A THEME=()
theme_css="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/current-theme.css"
if [ -r "$theme_css" ]; then
	while read -r kw name val; do
		[ "$kw" = "@define-color" ] || continue
		THEME[$name]=${val%;}
	done < "$theme_css"
fi

g_hex=""
resolve() {
	local v=${THEME[$1]:-} n=0
	while [ -n "$v" ] && [ "${v:0:1}" = "@" ] && [ "$n" -lt 10 ]; do
		v=${THEME[${v#@}]:-}
		n=$(( n + 1 ))
	done
	if [[ $v =~ ^#[0-9a-fA-F]{3,8}$ ]]; then g_hex=$v; else g_hex=""; fi
}

resolve tooltip-dim; C_DIM=$g_hex
resolve tooltip-fg;  C_FG=$g_hex
resolve tooltip-br;  C_ACCENT=$g_hex

paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# escape for pango markup, then for the JSON string -- month and weekday names
# come from the locale's data, not from this script
g_esc=""
escape() {
	local s=${1//&/\&amp;}
	s=${s//</\&lt;}
	s=${s//>/\&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# ---- navigation ----------------------------------------------------------

offset=0
if [ -r "$state" ]; then
	read -r offset < "$state" 2>/dev/null || offset=0
	[[ $offset =~ ^-?[0-9]+$ ]] || offset=0
fi

# The view is clamped rather than wrapped: scrolling is a flick of the wheel
# and it is easy to end up hundreds of months out with nothing to say so.
case "${1:-}" in
	prev)  offset=$(( offset - 1 )) ;;
	next)  offset=$(( offset + 1 )) ;;
	today) offset=0 ;;
esac
[ "$offset" -lt -1200 ] && offset=-1200
[ "$offset" -gt  1200 ] && offset=1200

if [ -n "${1:-}" ]; then
	# write atomically: a reader catching this mid-write falls back to 0 and
	# the view would jump to today under the cursor
	tmp="$state.$$"
	if printf '%s\n' "$offset" > "$tmp" 2>/dev/null; then
		mv -f "$tmp" "$state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	else
		rm -f "$tmp" 2>/dev/null
	fi
	pkill -RTMIN+$SIGNAL waybar 2>/dev/null
fi

# ---- the two months ------------------------------------------------------

# today, then the month being viewed. Month and weekday names come from the
# locale, so LC_TIME is not pinned the way LC_ALL is above.
IFS='|' read -r t_y t_m t_d t_doy t_week t_long \
	< <(LC_ALL= date '+%Y|%m|%-d|%-j|%V|%A, %-d %B %Y')
IFS='|' read -r v_y v_m v_name v_dow1 \
	< <(LC_ALL= date -d "$t_y-$t_m-01 $offset months" '+%Y|%m|%B|%u')
v_days=$(date -d "$v_y-$v_m-01 +1 month -1 day" '+%-d')
t_yeardays=$(date -d "$t_y-12-31" '+%-j')

viewing_today=0
[ "$v_y" = "$t_y" ] && [ "$v_m" = "$t_m" ] && viewing_today=1

# ---- grid ----------------------------------------------------------------

# Seven four-wide columns, the last one unpadded: a day number right-aligned in
# two cells then two spaces, so " 1" and "Mo" start in the same column.
CELL=4
GRID_W=$(( 7 * CELL - 2 ))

# Weekday initials straight from the locale rather than a hardcoded list, so a
# locale that starts its week on Sunday still reads correctly. %a is trimmed to
# two characters because three would make every column five wide.
head_row=""
for d in 1 2 3 4 5 6 7; do
	# 2024-01-01 was a Monday, so +N days walks Mo..Su
	n=$(LC_ALL= date -d "2024-01-01 +$(( d - 1 )) days" '+%a')
	head_row+="$(printf '%-*s' "$CELL" "${n:0:2}")"
done
head_row=${head_row%  }

rows=()
line=""
col=0

# blank cells before the 1st
for (( i = 1; i < v_dow1; i++ )); do
	line+="$(printf '%*s' "$CELL" '')"
	col=$(( col + 1 ))
done

for (( d = 1; d <= v_days; d++ )); do
	# Saturday and Sunday sit back on the dim colour; today takes the accent
	# and the underline the built-in calendar used for it.
	if [ "$viewing_today" -eq 1 ] && [ "$d" -eq "$t_d" ]; then
		cell=$(paint "$C_ACCENT" "<b><u>$(printf '%2d' "$d")</u></b>")
	elif [ "$col" -ge 5 ]; then
		cell=$(paint "$C_DIM" "$(printf '%2d' "$d")")
	else
		cell=$(paint "$C_FG" "$(printf '%2d' "$d")")
	fi

	line+="$cell"
	col=$(( col + 1 ))

	if [ "$col" -eq 7 ]; then
		rows+=("$line")
		line=""
		col=0
	else
		line+="  "
	fi
done
[ -n "$line" ] && rows+=("${line%  }")

# ---- tooltip -------------------------------------------------------------

escape "$v_name"; v_esc=$g_esc
head_plain="$v_name  ·  $v_y"

# The subtitle is today either way: letting it grow a "today ·" prefix only
# while browsing made the tooltip change width under the cursor on every
# scroll. The footer carries the difference instead, and both variants fit
# inside the grid.
sub_plain=$t_long
if [ "$viewing_today" -eq 1 ]; then
	foot_plain="week $t_week  ·  day $t_doy of $t_yeardays"
else
	foot_plain="click for today"
fi

width=$GRID_W
[ ${#head_plain} -gt "$width" ] && width=${#head_plain}
[ ${#sub_plain}  -gt "$width" ] && width=${#sub_plain}
[ ${#foot_plain} -gt "$width" ] && width=${#foot_plain}

centre() {   # centre <plain-width>
	local n=$(( (width - $1) / 2 ))
	[ "$n" -lt 0 ] && n=0
	printf '%*s' "$n" ''
}

rule=""
for (( i = 0; i < width; i++ )); do rule+="─"; done

tooltip="$(centre ${#head_plain})<b>$v_esc</b>$(paint "$C_DIM" '  ·  ')$(paint "$C_ACCENT" "<b>$v_y</b>")"
escape "$sub_plain"
tooltip+="\n$(centre ${#sub_plain})$(paint "$C_DIM" "$g_esc")"
tooltip+="\n$(paint "$C_DIM" "$rule")"
escape "$head_row"
tooltip+="\n$(centre $GRID_W)$(paint "$C_DIM" "<i>$g_esc</i>")"

for r in "${rows[@]}"; do
	tooltip+="\n$(centre $GRID_W)$r"
done

tooltip+="\n$(paint "$C_DIM" "$rule")"
escape "$foot_plain"
tooltip+="\n$(centre ${#foot_plain})$(paint "$C_DIM" "$g_esc")"

# The bar always shows today, never the month being browsed -- it is a clock,
# and a scrolled-away view that silently changed the date in the bar would be
# the kind of bug you only notice once it has cost you something.
printf '{"text":"%s %02d-%s","class":"%s","tooltip":"%s"}\n' \
	"$ICON" "$t_d" "$t_m" "$([ "$viewing_today" -eq 1 ] || printf 'browsing')" "$tooltip"
