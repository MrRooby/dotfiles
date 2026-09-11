#!/usr/bin/env bash
#
# Toggle Tailscale and report its state to Waybar
#
# Requirements:
# 	tailscale, with this user set as operator so that up/down needs no sudo:
# 		sudo tailscale set --operator=$USER
# 	jq, for the device list in the tooltip

# Pinned so ${#str} counts characters rather than bytes (the dots and rules
# are multi-byte, and columns are padded by length).
export LC_ALL=C.utf8

ICON_UP="󰦝"
ICON_DOWN="󰦞"

# ---- theme colours -------------------------------------------------------

# Same lookup as battery.sh: pango only takes literal hex, so the palette is
# read from current-theme.css and @references followed until a hex falls out.
# Anything unresolved paints nothing and inherits styles/tooltips.css.

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
resolve charging;    C_ONLINE=$g_hex

paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# escape for pango markup, then for the JSON string -- hostnames are chosen by
# whoever owns the device
g_esc=""
escape() {
	local s=${1//&/&amp;}
	s=${s//</&lt;}
	s=${s//>/&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# ---- tooltip -------------------------------------------------------------

# One row per peer: online first (active connections on top, then by name),
# offline after, most recently seen first. The name is the MagicDNS label, the
# same one `tailscale status` prints -- HostName is whatever the OS reports,
# which on phones is "localhost" or "Bartosz's S21 FE".
PEERS_JQ='
def name: (.DNSName | split(".")[0]) // .HostName;
def seen: .LastSeen | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0;
def ago:
	(now - seen) as $s
	| if seen == 0      then "offline"
	  elif $s < 3600    then "\($s / 60   | floor)m ago"
	  elif $s < 86400   then "\($s / 3600 | floor)h ago"
	  else                   "\($s / 86400 | floor)d ago" end;
def state:
	if .Online | not     then ago
	elif .Active and .CurAddr != "" then "direct"
	elif .Active         then "relay \(.Relay)"
	else                      "idle" end;

(.Self | .TailscaleIPs[0] // "", name),
([.Peer // {} | .[]] as $p
	| ($p | map(select(.Online))  | sort_by([(.Active | not), name])),
	  ($p | map(select(.Online | not)) | sort_by(-seen))
	| .[]
	| [(if .Online then 1 else 0 end), name, (.TailscaleIPs[0] // "-"),
	   .OS, (state + (if .ExitNode then " · exit" else "" end))]
	| @tsv)
'

tooltip() {
	local json self_ip self_name
	json=$(tailscale status --json 2>/dev/null) || return 1

	local on=() names=() ips=() oses=() states=()
	{
		read -r self_ip
		read -r self_name
		while IFS=$'\t' read -r o n i s t; do
			on+=("$o"); names+=("$n"); ips+=("$i"); oses+=("$s"); states+=("$t")
		done
	} < <(jq -r "$PEERS_JQ" <<< "$json")

	# column widths, measured on plain text before any markup goes on
	local nw=0 iw=0 ow=0 sw=0 i
	for i in "${!names[@]}"; do
		[ ${#names[i]}  -gt "$nw" ] && nw=${#names[i]}
		[ ${#ips[i]}    -gt "$iw" ] && iw=${#ips[i]}
		[ ${#oses[i]}   -gt "$ow" ] && ow=${#oses[i]}
		[ ${#states[i]} -gt "$sw" ] && sw=${#states[i]}
	done

	# dot + 2 + name + 3 + ip + 3 + os + 3 + state
	local width=$(( 1 + 2 + nw + 3 + iw + 3 + ow + 3 + sw ))

	local head="Tailscale  ·  $self_name"
	[ ${#head}    -gt "$width" ] && width=${#head}
	[ ${#self_ip} -gt "$width" ] && width=${#self_ip}

	local rule="" out pad
	for (( i = 0; i < width; i++ )); do rule+="─"; done
	rule=$(paint "$C_DIM" "$rule")

	escape "$self_name"
	pad=$(( (width - ${#head}) / 2 ))
	out="$(printf '%*s' "$pad" '')<b>Tailscale</b>$(paint "$C_DIM" '  ·  ')$(paint "$C_ACCENT" "<b>$g_esc</b>")"
	pad=$(( (width - ${#self_ip}) / 2 ))
	out+="\n$(printf '%*s' "$pad" '')$(paint "$C_DIM" "$self_ip")"
	out+="\n$rule"

	if [ ${#names[@]} -eq 0 ]; then
		out+="\n$(paint "$C_DIM" "no other devices")"
	fi

	local n ip os st prev=1
	for i in "${!names[@]}"; do
		# a rule between the online group and the offline one
		[ "${on[i]}" -eq 0 ] && [ "$prev" -eq 1 ] && [ "$i" -gt 0 ] && out+="\n$rule"
		prev=${on[i]}

		printf -v n  '%-*s' "$nw" "${names[i]}"
		printf -v ip '%-*s' "$iw" "${ips[i]}"
		printf -v os '%-*s' "$ow" "${oses[i]}"
		printf -v st '%*s'  "$sw" "${states[i]}"
		escape "$n";  n=$g_esc
		escape "$st"; st=$g_esc

		if [ "${on[i]}" -eq 1 ]; then
			out+="\n$(paint "$C_ONLINE" "●")  $(paint "$C_FG" "<b>$n</b>")"
			out+="   $(paint "$C_DIM" "$ip")   $(paint "$C_DIM" "$os")   $(paint "$C_FG" "$st")"
		else
			out+="\n$(paint "$C_DIM" "○  $n   $ip   $os   $st")"
		fi
	done

	printf '%s' "$out"
}

# ---- main ----------------------------------------------------------------

state() {
	tailscale status --json --peers=false 2>/dev/null |
		awk -F '"' '/"BackendState"/ {print $4; exit}'
}

main() {
	if [[ $1 == "toggle" ]]; then
		if [[ $(state) == "Running" ]]; then
			tailscale down
		else
			tailscale up
		fi
	fi

	case $(state) in
		"Running")
			local tip
			tip=$(tooltip) || tip="Tailscale: $(tailscale ip -4 2>/dev/null || echo connected)"
			printf '{"text": "%s", "class": "active", "tooltip": "%s"}\n' \
				"$ICON_UP" "$tip"
			;;
		"NeedsLogin")
			printf '{"text": "%s", "class": "inactive", "tooltip": "Tailscale: logged out"}\n' \
				"$ICON_DOWN"
			;;
		*)
			printf '{"text": "%s", "class": "inactive", "tooltip": "Tailscale: off"}\n' \
				"$ICON_DOWN"
			;;
	esac
}

main "$@"
