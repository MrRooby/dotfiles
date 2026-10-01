#!/usr/bin/env bash
#
# Network module for waybar: link icon in the bar, connection detail in the
# tooltip.
#
# Replaces the built-in network module, whose tooltip describes a single
# interface and has no placeholders for link rate, security or DNS. This one
# describes the interface carrying the default route in full -- Wi-Fi signal,
# band, link rate and security, or the wired link speed; address, gateway,
# DNS and live traffic -- and lists any other active connection under it, so
# a dock's ethernet and the Wi-Fi it overrides are both visible.
#
# Requirements: iproute2, NetworkManager (nmcli), iw
#
# nmcli is spawned once for the device list, once per connected device and
# once for the active access point: ~20 ms each, fine at a 5 s poll.

set -uo pipefail

# pinned so ${#str} counts characters rather than bytes (the header and the
# gauge are multi-byte) and awk prints a decimal point in every locale
export LC_ALL=C.utf8

ICON_ETHERNET="󰈀"
ICON_DISCONNECTED="󰤯"
ICON_DISABLED="󰤮"
ICONS_WIFI=("󰤟" "󰤢" "󰤥" "󰤨")

# per-interface byte counters from the previous poll, for the traffic rate
state="${XDG_RUNTIME_DIR:-/tmp}/waybar-network.state"

# ---- helpers -------------------------------------------------------------

slurp() {
	local v
	[ -r "$1" ] || return 1
	read -r v < "$1" 2>/dev/null || return 1
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

# escape for pango markup, then for the JSON string -- connection names and
# SSIDs are whatever the network's owner typed
g_esc=""
escape() {
	local s=${1//&/&amp;}
	s=${s//</&lt;}
	s=${s//>/&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# "1.2 MB/s", "340 kB/s", "12 B/s" -- SI units, one decimal below ten
g_rate=""
fmt_rate() {
	g_rate=$(awk -v b="$1" 'BEGIN {
		split("B/s kB/s MB/s GB/s", u, " "); i = 1
		while (b >= 1000 && i < 4) { b /= 1000; i++ }
		printf (b < 10 && i > 1) ? "%.1f %s" : "%d %s", b, u[i]
	}')
}

# ---- what is connected ---------------------------------------------------

# the interface the default route leaves by, lowest metric first; loopback
# and tunnels (tailscale0) are not links in this sense
primary=$(ip -j route show default 2>/dev/null | jq -r '
	[ .[] | select(.dev != "lo" and (.dev | test("^(tailscale|tun|wg)") | not)) ]
	| sort_by(.metric // 0) | .[0].dev // empty')

# connected ethernet / wifi devices, primary first
devs=(); types=()
while IFS=: read -r dev type st; do
	[ "$st" = "connected" ] || continue
	case "$type" in ethernet|wifi) ;; *) continue ;; esac
	if [ "$dev" = "$primary" ]; then
		devs=("$dev" "${devs[@]}"); types=("$type" "${types[@]}")
	else
		devs+=("$dev"); types+=("$type")
	fi
done < <(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null)

# ---- per-device detail ---------------------------------------------------

# fills d_* for one device
d_name=""; d_addr=""; d_gw=""; d_dns=""
d_signal=""; d_dbm=""; d_band=""; d_chan=""; d_rate=""; d_sec=""; d_speed=""
describe() {
	local dev=$1 type=$2 key val

	d_name=""; d_addr=""; d_gw=""; d_dns=""
	d_signal=""; d_dbm=""; d_band=""; d_chan=""; d_rate=""; d_sec=""; d_speed=""

	# terse `device show` is KEY:value per line; only the first colon splits
	while IFS= read -r line; do
		key=${line%%:*}; val=${line#*:}; val=${val//\\:/:}
		case "$key" in
			GENERAL.CONNECTION) d_name=$val ;;
			IP4.ADDRESS*)       [ -z "$d_addr" ] && d_addr=$val ;;
			IP4.GATEWAY)        d_gw=$val ;;
			IP4.DNS*)           d_dns+="${d_dns:+, }$val" ;;
		esac
	done < <(nmcli -t -f GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show "$dev" 2>/dev/null)

	if [ "$type" = "wifi" ]; then
		# channel, signal % and security from NetworkManager's cached scan --
		# --rescan no, a scan per poll would stall the radio every 5 s
		local active chan sig sec
		while IFS=: read -r active chan sig sec; do
			[ "$active" = "yes" ] || continue
			d_chan=$chan; d_signal=$sig; d_sec=${sec:-open}
			break
		done < <(nmcli -t -f ACTIVE,CHAN,SIGNAL,SECURITY device wifi list ifname "$dev" --rescan no 2>/dev/null)

		# dBm, frequency and the negotiated transmit rate from the driver
		local mhz=""
		while read -r a b c _; do
			case "$a" in
				signal:) d_dbm=$b ;;
				freq:)   mhz=${b%.*} ;;
				tx)      [ "$b" = "bitrate:" ] && d_rate=${c%.*} ;;
			esac
		done < <(iw dev "$dev" link 2>/dev/null)

		if [[ $mhz =~ ^[0-9]+$ ]]; then
			if   [ "$mhz" -lt 3000 ]; then d_band="2.4 GHz"
			elif [ "$mhz" -lt 5925 ]; then d_band="5 GHz"
			else                           d_band="6 GHz"; fi
		fi
	else
		# -1 when the driver cannot tell, e.g. some USB adapters
		local s
		s=$(slurp "/sys/class/net/$dev/speed") && [ "$s" -gt 0 ] 2>/dev/null && d_speed=$s
	fi
}

# ---- traffic -------------------------------------------------------------

# bytes per second since the previous poll, per device. The first poll after
# a (re)connect has no baseline and shows nothing rather than a fake zero.
declare -A prev_t=() prev_rx=() prev_tx=() rate_rx=() rate_tx=()
if [ -r "$state" ]; then
	while read -r dev t rx tx; do
		prev_t[$dev]=$t; prev_rx[$dev]=$rx; prev_tx[$dev]=$tx
	done < "$state"
fi

now=${EPOCHREALTIME:-$(date +%s.%N)}
lines=()
for dev in "${devs[@]}"; do
	rx=$(slurp "/sys/class/net/$dev/statistics/rx_bytes") || continue
	tx=$(slurp "/sys/class/net/$dev/statistics/tx_bytes") || continue
	lines+=("$dev $now $rx $tx")

	pt=${prev_t[$dev]:-}; prx=${prev_rx[$dev]:-}; ptx=${prev_tx[$dev]:-}
	[ -n "$pt" ] || continue
	# a counter going backwards means the interface was reset
	[ "$rx" -ge "$prx" ] && [ "$tx" -ge "$ptx" ] || continue
	read -r rate_rx[$dev] rate_tx[$dev] < <(awk -v t0="$pt" -v t1="$now" \
		-v r0="$prx" -v r1="$rx" -v x0="$ptx" -v x1="$tx" 'BEGIN {
			dt = t1 - t0; if (dt <= 0) exit
			printf "%d %d\n", (r1 - r0) / dt, (x1 - x0) / dt }')
done

tmp="$state.$$"
if printf '%s\n' "${lines[@]}" > "$tmp" 2>/dev/null; then
	mv -f "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
else
	rm -f "$tmp" 2>/dev/null
fi

# ---- bar -----------------------------------------------------------------

if [ ${#devs[@]} -eq 0 ]; then
	if [ "$(nmcli radio wifi 2>/dev/null)" = "disabled" ]; then
		printf '{"text":"%s","class":"disabled","tooltip":"Wi-Fi disabled"}\n' "$ICON_DISABLED"
	else
		printf '{"text":"%s","class":"disconnected","tooltip":"Disconnected"}\n' "$ICON_DISCONNECTED"
	fi
	exit 0
fi

describe "${devs[0]}" "${types[0]}"

if [ "${types[0]}" = "wifi" ]; then
	class="wifi"
	n=$(( ${d_signal:-0} / 25 )); [ "$n" -gt 3 ] && n=3
	icon=${ICONS_WIFI[n]}
else
	class="ethernet"
	icon=$ICON_ETHERNET
fi

# ---- theme colours -------------------------------------------------------

# same lookup as battery.sh: pango takes literal hex only, so the palette is
# read from current-theme.css and @references followed down to a hex

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

# ---- rows ----------------------------------------------------------------

# a label of "-" is a section break, drawn as a rule
labels=(); values=()
row() { [ -n "$2" ] && { labels+=("$1"); values+=("$2"); }; }
rule_row() { labels+=("-"); values+=(""); }

traffic_rows() {
	local dev=$1
	[ -n "${rate_rx[$dev]:-}" ] || return
	fmt_rate "${rate_rx[$dev]}"; row "Down" "$g_rate"
	fmt_rate "${rate_tx[$dev]}"; row "Up"   "$g_rate"
}

# primary link, in full
if [ "$class" = "wifi" ]; then
	row "Signal"   "${d_signal:+$d_signal%}${d_dbm:+ · $d_dbm dBm}"
	row "Band"     "${d_band}${d_chan:+ · ch $d_chan}"
	row "Link"     "${d_rate:+$d_rate Mb/s}"
	row "Security" "$d_sec"
else
	row "Link"     "${d_speed:+$d_speed Mb/s}"
fi
row "Device"   "${devs[0]}"
rule_row
row "IPv4"     "$d_addr"
row "Gateway"  "$d_gw"
row "DNS"      "$d_dns"
if [ -n "${rate_rx[${devs[0]}]:-}" ]; then
	rule_row
	traffic_rows "${devs[0]}"
fi

head_name=$d_name
head_type=$([ "$class" = "wifi" ] && echo "Wi-Fi" || echo "Ethernet")
gauge_pct=$([ "$class" = "wifi" ] && echo "${d_signal:-0}" || echo "")

# every other active link, two lines each: what it is, and its address
for (( i = 1; i < ${#devs[@]}; i++ )); do
	describe "${devs[i]}" "${types[i]}"
	rule_row
	if [ "${types[i]}" = "wifi" ]; then
		row "Wi-Fi" "$d_name${d_signal:+ · $d_signal%}"
	else
		row "Ethernet" "$d_name${d_speed:+ · $d_speed Mb/s}"
	fi
	row "IPv4" "$d_addr"
done

# ---- tooltip -------------------------------------------------------------

# widths on the plain text, markup wrapped round the padded result after --
# same approach, and same reason, as battery.sh
lw=0; vw=0
for i in "${!labels[@]}"; do
	[ "${labels[i]}" = "-" ] && continue
	[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
	[ ${#values[i]} -gt "$vw" ] && vw=${#values[i]}
done

head_plain="$head_name  ·  $head_type"
inner=$(( lw + 2 + vw ))
if [ ${#head_plain} -gt "$inner" ]; then
	inner=${#head_plain}
	vw=$(( inner - lw - 2 ))
fi

pad=$(( (inner - ${#head_plain}) / 2 ))
escape "$head_name"
tooltip="$(printf '%*s' "$pad" '')<b>$g_esc</b>$(paint "$C_DIM" '  ·  ')$(paint "$C_ACCENT" "<b>$head_type</b>")"

# signal gauge under a Wi-Fi header, filled to the nearest cell
if [ -n "$gauge_pct" ]; then
	fill=""; rest=""; f=$(( gauge_pct * inner / 100 ))
	for (( i = 0; i < inner; i++ )); do
		if [ "$i" -lt "$f" ]; then fill+="█"; else rest+="░"; fi
	done
	tooltip+="\n$(paint "$C_ACCENT" "$fill")$(paint "$C_DIM" "$rest")"
fi

rule=""
for (( i = 0; i < inner; i++ )); do rule+="─"; done
rule="\n$(paint "$C_DIM" "$rule")"

tooltip+="$rule"
prev_rule=1
for i in "${!labels[@]}"; do
	if [ "${labels[i]}" = "-" ]; then
		# no doubled rules, no rule as the last line
		[ "$prev_rule" -eq 0 ] && [ $(( i + 1 )) -lt ${#labels[@]} ] && tooltip+="$rule"
		prev_rule=1
		continue
	fi
	# padded by hand: printf's width counts bytes, and "·" is two of them
	l=${labels[i]}; v=${values[i]}
	l+=$(printf '%*s' $(( lw - ${#l} )) '')
	v=$(printf '%*s' $(( vw - ${#v} )) '')$v
	escape "$l"; l=$g_esc
	escape "$v"; v=$g_esc
	tooltip+="\n$(paint "$C_DIM" "$l")  $(paint "$C_FG" "<b>$v</b>")"
	prev_rule=0
done

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$icon" "$class" "$tooltip"
