#!/usr/bin/env bash
#
# Typing speed for waybar: the live words per minute while typing, the session
# average during a pause, and both with the peak in the tooltip.
#
# The numbers come from the rusty-word-count daemon, which measures typing in
# the background and sends a line of JSON whenever the score changes. This
# script stays running for as long as that stream does and turns each line
# into one for the module, so nothing is polled and an idle keyboard costs
# nothing.
#
# The live figure is 0 whenever nothing is being typed, which is most of the
# time, so during a pause the bar falls back to the session average and the
# module gets the class "idle" for styles/states.css to dim it.
#
# Requirements:
# 	rusty-word-count, with its daemon running
# 	(systemctl --user status rusty-word-count)

set -uo pipefail
export LC_ALL=C.utf8

BIN=$HOME/.cargo/bin/rusty-word-count

# ---- theme colours -------------------------------------------------------

# Same lookup as battery.sh: pango only takes literal hex, so the palette is
# read from current-theme.css and @references are followed until a hex falls
# out. Anything unresolved paints nothing and inherits styles/tooltips.css.
#
# Unlike the interval modules this script outlives a theme switch, so the
# palette is read again for every line rather than once at the top.

declare -A THEME=()
theme_css="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/current-theme.css"

g_hex=""
resolve() {
	local v=${THEME[$1]:-} n=0
	while [ -n "$v" ] && [ "${v:0:1}" = "@" ] && [ "$n" -lt 10 ]; do
		v=${THEME[${v#@}]:-}
		n=$(( n + 1 ))
	done
	if [[ $v =~ ^#[0-9a-fA-F]{3,8}$ ]]; then g_hex=$v; else g_hex=""; fi
}

load_theme() {
	local kw name val
	THEME=()
	if [ -r "$theme_css" ]; then
		while read -r kw name val; do
			[ "$kw" = "@define-color" ] || continue
			THEME[$name]=${val%;}
		done < "$theme_css"
	fi
	resolve tooltip-dim; C_DIM=$g_hex
	resolve tooltip-fg;  C_FG=$g_hex
	resolve tooltip-br;  C_ACCENT=$g_hex
}

paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# ---- one line ------------------------------------------------------------

# "3m 48s", "1h 05m"
duration() {
	if   [ "$1" -ge 3600 ]; then printf '%dh %02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 ))
	elif [ "$1" -ge 60 ];   then printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 ))
	else                         printf '%ds' "$1"
	fi
}

render() {   # render <line from the daemon>
	local wpm average peak chars secs
	[[ $1 =~ \"wpm\":([0-9]+) ]]         || return; wpm=${BASH_REMATCH[1]}
	[[ $1 =~ \"average\":([0-9]+) ]]     || return; average=${BASH_REMATCH[1]}
	[[ $1 =~ \"peak\":([0-9]+) ]]        || return; peak=${BASH_REMATCH[1]}
	[[ $1 =~ \"chars\":([0-9]+) ]]       || return; chars=${BASH_REMATCH[1]}
	[[ $1 =~ \"active_secs\":([0-9]+) ]] || return; secs=${BASH_REMATCH[1]}

	# the bar shows the live figure while there is one and the average
	# otherwise; the tooltip marks whichever of the two that is
	local text class hot
	if [ "$wpm" -gt 0 ]; then
		text=$wpm;     class=typing; hot=Live
	else
		text=$average; class=idle;   hot=Average
	fi

	# a label of "-" is a rule
	local labels=(Live Average Peak - Words Time)
	local values=("$wpm WPM" "$average WPM" "$peak WPM" "" "$(( chars / 5 ))" "$(duration "$secs")")

	load_theme

	# same layout as fan.sh: widths on plain text, padded by hand
	local i lw=0 vw=0
	for i in "${!labels[@]}"; do
		[ "${labels[i]}" = "-" ] && continue
		[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
		[ ${#values[i]} -gt "$vw" ] && vw=${#values[i]}
	done
	local inner=$(( lw + 2 + vw ))

	local title="Typing"
	local pad=$(( (inner - ${#title}) / 2 ))
	local tooltip
	tooltip="$(printf '%*s' "$pad" '')$(paint "$C_ACCENT" "<b>$title</b>")"

	local rule=""
	for (( i = 0; i < inner; i++ )); do rule+="─"; done
	rule="\n$(paint "$C_DIM" "$rule")"

	local l v
	tooltip+="$rule"
	for i in "${!labels[@]}"; do
		if [ "${labels[i]}" = "-" ]; then
			tooltip+="$rule"
			continue
		fi
		l=${labels[i]}; v=${values[i]}
		l+=$(printf '%*s' $(( lw - ${#l} )) '')
		v=$(printf '%*s' $(( vw - ${#v} )) '')$v
		if [ "${labels[i]}" = "$hot" ]; then
			tooltip+="\n$(paint "$C_ACCENT" "<b>$l  $v</b>")"
		else
			tooltip+="\n$(paint "$C_DIM" "$l")  $(paint "$C_FG" "<b>$v</b>")"
		fi
	done

	# two columns, so the module only changes width at 100 WPM and beyond
	printf '{"text":"%2s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
}

# ---- stream --------------------------------------------------------------

"$BIN" watch 2>/dev/null | while IFS= read -r line; do
	render "$line"
done

# The stream ended, so the daemon is not running or has just been stopped.
# Say so rather than leave the last number standing; waybar runs the script
# again after the module's restart-interval.
printf '{"text":"--","tooltip":"rusty-word-count is not running","class":"offline"}\n'
