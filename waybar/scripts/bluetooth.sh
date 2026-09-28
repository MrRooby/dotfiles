#!/usr/bin/env bash
#
# Bluetooth module for waybar: adapter state in the bar, everything bluez knows
# in the tooltip.
#
# waybar's built-in bluetooth module can only paste {device_alias},
# {device_address} and {device_battery_percentage} into a fixed enumerate
# format. There is no way to align columns, to colour a row by its state, to
# list devices that are paired but not connected, or to say anything at all
# about the link -- and which codec a headset actually negotiated is the thing
# you open a bluetooth tooltip for.
#
# Everything below comes out of a single GetManagedObjects call on org.bluez:
# the adapter, every device, their org.bluez.Battery1 percentages and the
# org.bluez.MediaTransport1 objects carrying the negotiated codec and its
# configuration blob. That is the same call bluetoothctl makes, rather than
# spawning bluetoothctl once per device and parsing its prose.
#
# Requirements:
# 	bluez (org.bluez on the system bus)
# 	jq, for walking the object tree and decoding the codec configuration
#
# Layout follows tailscale.sh: a centred header, then one padded row per
# device -- filled dot and full colour for connected, hollow dot and dim for
# everything else -- with the codec detail on a dim continuation line.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes: every rule, dot and
# nerd-font glyph here is multi-byte and the columns are padded by length.
# "Nerd Font Mono" is the single-width variant, so one glyph is one cell and
# the icon columns pad like any other.
export LC_ALL=C.utf8

ICON_CONNECTED="󰂱"
ICON_ON="󰂰"
ICON_OFF="󰂲"

BATT_WARN=25   # %
BATT_CRIT=10   # %

# device class -> glyph. Keys are produced by icon_key() in the jq below, which
# prefers bluez's own Icon property and falls back to the BR/EDR class-of-device
# major class or the LE appearance category.
declare -A GLYPH=(
	[headphones]="󰋋" [headset]="󰋎" [speaker]="󰓃"  [phone]="󰄜"
	[computer]="󰌢"   [keyboard]="󰌌" [mouse]="󰍽"    [gamepad]="󰊴"
	[tablet]="󰓷"     [printer]="󰐪"  [scanner]="󰚫"  [camera]="󰄀"
	[video]="󰕧"      [display]="󰍹"  [network]="󰑩"  [watch]="󰬲"
	[car]="󰄋"        [pen]="󰙁"      [unknown]="󰂯"
)

# the same ten-step ramp battery.sh draws in the bar
BATT_ICONS=("󰂎" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹")

# ---- theme colours -------------------------------------------------------

# Same lookup as battery.sh and tailscale.sh: pango only takes literal hex, so
# the palette is read from current-theme.css at runtime and @references are
# followed until a hex falls out. Anything unresolved paints nothing and
# inherits styles/tooltips.css.

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
resolve charging;    C_OK=$g_hex
resolve warning;     C_WARN=$g_hex
resolve critical;    C_CRIT=$g_hex

paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# escape for pango markup, then for the JSON string -- an alias is whatever the
# device advertises, so it is never pasted into either raw
g_esc=""
escape() {
	local s=${1//&/\&amp;}
	s=${s//</\&lt;}
	s=${s//>/\&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# ---- the object tree -----------------------------------------------------

# ASCII unit separator, not tab: tab is IFS whitespace, so bash would collapse
# runs of it and a device with no battery would shift every field after it.
SEP=$'\x1f'

# One "A" line for the adapter, then one "D" line per device. Sorted connected
# first, then paired, then whatever the last scan turned up, each group by name.
#
# The codec decoders below follow the bitfield layouts in bluez's
# a2dp-codecs.h. Those structs are packed bitfields, so on little-endian the
# first field of a byte sits in its LOW bits -- an SBC configuration byte is
# (frequency << 4) | channel_mode, not the other way round -- and each field's
# bit weights are relative to the field, not the byte.
DEVICES_JQ='
def V($x): $x.data;
def S($x): (V($x) // "" | tostring);
def B($x): (V($x) // false);
def N($x): V($x);
def bset($v; $w): if $v == null then false else ((($v / $w) | floor) % 2) == 1 end;
def mask($v; $tbl): ([$tbl[] | select(bset($v; .[0])) | .[1]] | first) // "";
def khz($f): if $f == "" then "" else "\($f / 1000) kHz" end;

# ---- codec decoding ------------------------------------------------------

# A vendor-specific A2DP codec carries its identity in the first six bytes of
# the configuration: a 32-bit little-endian company ID, then a 16-bit codec ID.
def vendor_codec($cfg):
  (($cfg[0] // 0) + ($cfg[1] // 0) * 256 + ($cfg[2] // 0) * 65536 + ($cfg[3] // 0) * 16777216) as $v
  | (($cfg[4] // 0) + ($cfg[5] // 0) * 256) as $i
  | if   $v ==  301 and $i ==   170 then "LDAC"
    elif $v ==   79 and $i ==     1 then "aptX"
    elif $v ==  215 and $i ==    36 then "aptX HD"
    elif $v ==  215 and $i ==     2 then "aptX LL"
    elif $v ==  215 and $i ==   173 then "aptX Adaptive"
    elif $v ==   10 and $i ==     1 then "FastStream"
    elif $v ==  117 and $i ==   259 then "Samsung Scalable"
    elif $v == 1338 and $i == 18508 then "LHDC"
    elif $v == 1338 and $i == 19506 then "LHDC v2"
    elif $v == 1338 and $i == 19507 then "LHDC v3"
    elif $v == 1338 and $i == 19509 then "LHDC v5"
    elif $v == 1249 and $i ==     1 then "LC3plus"
    else "vendor \($v):\($i)" end;

# SBC: [frequency|channel mode, block length|subbands|allocation,
#       min bitpool, max bitpool]
def sbc_fs($cfg):   mask($cfg[0]; [[128,16000],[64,32000],[32,44100],[16,48000]]);
def sbc_chan($cfg): mask($cfg[0]; [[8,"mono"],[4,"dual channel"],[2,"stereo"],[1,"joint stereo"]]);

# The frame length the encoder is pinned to, and from it the bitrate the link
# actually runs at -- bitpool alone means nothing without the block count and
# subband count it is paired with. Formulae are from the SBC specification,
# section 12.9.
def sbc_kbps($cfg):
  mask($cfg[1]; [[128,4],[64,8],[32,12],[16,16]]) as $blocks
  | mask($cfg[1]; [[8,4],[4,8]]) as $sb
  | sbc_fs($cfg) as $fs
  | sbc_chan($cfg) as $mode
  | ($cfg[3] // 0) as $bp
  | if ($blocks == "") or ($sb == "") or ($fs == "") or ($mode == "") or ($bp == 0) then ""
    else
      (if $mode == "mono" then 1 else 2 end) as $ch
      | (4 + (4 * $sb * $ch / 8)
           + (if $mode == "mono" or $mode == "dual channel"
              then ((($blocks * $ch * $bp) + 7) / 8 | floor)
              else (((if $mode == "joint stereo" then $sb else 0 end)
                     + ($blocks * $bp) + 7) / 8 | floor) end)) as $frame
      | "\(((8 * $frame * $fs / ($sb * $blocks)) / 1000) | round) kbps"
    end;

# AAC: object type, a 12-bit frequency split across two octets, two channel
# bits, then a 23-bit bitrate ceiling with the VBR flag in the top bit.
def aac_fs($cfg):
  ((($cfg[1] // 0) * 16) + ((($cfg[2] // 0) / 16) | floor)) as $f
  | mask($f; [[2048,8000],[1024,11025],[512,12000],[256,16000],
              [128,22050],[64,24000],[32,32000],[16,44100],
              [8,48000],[4,64000],[2,88200],[1,96000]]);
def aac_chan($cfg): mask($cfg[2]; [[8,"mono"],[4,"stereo"]]);
def aac_kbps($cfg):
  ((($cfg[3] // 0) % 128) * 65536 + ($cfg[4] // 0) * 256 + ($cfg[5] // 0)) as $b
  | if $b == 0 then ""
    else "\(($b / 1000) | floor) kbps" + (if bset($cfg[3]; 128) then " VBR" else "" end) end;

# LDAC and the aptX family put their own fields after the six-byte vendor
# header. aptX Adaptive lays those bytes out differently, so it only ever
# reports its name.
def ldac_fs($cfg):   mask($cfg[6]; [[32,44100],[16,48000],[8,88200],[4,96000],[2,176400],[1,192000]]);
def ldac_chan($cfg): mask($cfg[7]; [[4,"mono"],[2,"dual channel"],[1,"stereo"]]);
def aptx_fs($cfg):   mask($cfg[6]; [[128,16000],[64,32000],[32,44100],[16,48000]]);
def aptx_chan($cfg): mask($cfg[6]; [[2,"stereo"],[1,"mono"]]);

def transport($t):
  N($t.Codec) as $c
  | (V($t.Configuration) // []) as $cfg
  | (S($t.UUID) | ascii_downcase) as $u
  | (if   ($u|startswith("0000110a")) or ($u|startswith("0000110b")) then "A2DP"
     elif ($u|startswith("00001108")) or ($u|startswith("0000111e"))
       or ($u|startswith("0000111f")) or ($u|startswith("00001131")) then "HFP"
     else "LE Audio" end) as $profile
  | (if $profile == "A2DP" then
       (if   $c == 0   then "SBC"
        elif $c == 1   then "MP3"
        elif $c == 2   then "AAC"
        elif $c == 4   then "ATRAC"
        elif $c == 255 then vendor_codec($cfg)
        else "codec \($c)" end)
     elif $profile == "HFP" then
       (if $c == 1 then "CVSD" elif $c == 2 then "mSBC" elif $c == 3 then "LC3-SWB" else "codec \($c)" end)
     else
       (if $c == 6 then "LC3" else "codec \($c)" end) end) as $codec
  | (if   $codec == "SBC" then [khz(sbc_fs($cfg)), sbc_chan($cfg), sbc_kbps($cfg),
                                (if ($cfg[3] // 0) > 0 then "bitpool \($cfg[3])" else "" end)]
     elif $codec == "AAC" then [khz(aac_fs($cfg)), aac_chan($cfg), aac_kbps($cfg)]
     elif $codec == "LDAC" then [khz(ldac_fs($cfg)), ldac_chan($cfg)]
     elif ($codec | IN("aptX", "aptX HD", "aptX LL")) then [khz(aptx_fs($cfg)), aptx_chan($cfg)]
     else [] end) as $extra
  | { profile: $profile,
      detail: ([$codec] + $extra
               + [(if N($t.Volume) != null then "vol \((N($t.Volume) * 100 / 127) | round)%" else "" end),
                  S($t.State)]
               | map(select(. != "")) | join(" · ")) };

# ---- device class --------------------------------------------------------

def icon_key($d):
  S($d.Icon) as $i
  | { "audio-headphones":"headphones", "audio-headset":"headset",
      "audio-card":"speaker", "audio-speakers":"speaker",
      "multimedia-player":"speaker", "phone":"phone", "computer":"computer",
      "input-keyboard":"keyboard", "input-mouse":"mouse",
      "input-gaming":"gamepad", "input-tablet":"tablet", "printer":"printer",
      "scanner":"scanner", "camera-photo":"camera", "camera-video":"video",
      "video-display":"display", "network-wireless":"network",
      "modem":"network" }[$i]
    // ( ((((N($d.Class) // 0) / 256) | floor) % 32) as $maj
       | (((N($d.Appearance) // 0) / 64) | floor) as $cat
       | if   $maj == 1 then "computer"
         elif $maj == 2 then "phone"
         elif $maj == 3 then "network"
         elif $maj == 4 then "speaker"
         elif $maj == 5 then (if ((((N($d.Class) // 0) / 64) | floor) % 4) == 2 then "mouse" else "keyboard" end)
         elif $maj == 6 then "printer"
         elif $maj == 7 then "watch"
         elif $cat == 15 then ((N($d.Appearance) // 0) % 64) as $s
              | (if   $s == 1 then "keyboard"
                 elif $s == 2 then "mouse"
                 elif $s == 3 or $s == 4 then "gamepad"
                 elif $s == 5 then "tablet"
                 elif $s == 7 then "pen"
                 elif $s == 8 then "scanner"
                 else "keyboard" end)
         elif $cat == 1  then "phone"
         elif $cat == 2  then "computer"
         elif $cat == 3  then "watch"
         elif $cat == 5  then "display"
         elif $cat == 10 then "speaker"
         elif $cat == 11 then "scanner"
         else "unknown" end );

# ---- rows ----------------------------------------------------------------

.data[0] as $o
| ([$o | to_entries[] | select(.value["org.bluez.Adapter1"] != null)] | first) as $ae
| ($ae.value["org.bluez.Adapter1"] // {}) as $a

| (["A", S($a.Alias), S($a.Address), S($a.PowerState),
    (B($a.Discoverable) | tostring), (B($a.Pairable) | tostring),
    (B($a.Discovering) | tostring)] | join("\u001f")),

  ([$o | to_entries[] | select(.value["org.bluez.Device1"] != null)]
   | map(. as $e
     | ($e.value["org.bluez.Device1"]) as $d
     | ($e.value["org.bluez.Battery1"]) as $bat
     | ([$o | to_entries[]
             | select(.key | startswith($e.key + "/"))
             | .value["org.bluez.MediaTransport1"] | select(. != null)]
        | sort_by(S(.State) | if . == "active" then 0 elif . == "pending" then 1 else 2 end)
        | first) as $t
     | (if $t == null then null else transport($t) end) as $ti
     | B($d.Connected) as $conn
     | (B($d.Paired) or B($d.Bonded)) as $known
     | [V($d.UUIDs) // [] | .[] | ascii_downcase] as $uuids
     | (if   S($d.Alias) != "" then S($d.Alias)
        elif S($d.Name)  != "" then S($d.Name)
        else S($d.Address) end) as $name
     | (if   $ti != null then $ti.profile
        elif ($uuids | any(startswith("00001124") or startswith("00001812"))) then "HID"
        elif ($uuids | any(startswith("00001115") or startswith("00001116")
                        or startswith("00001117"))) then "PAN"
        else "connected" end) as $live
     | (if   $conn          then $live
        elif B($d.Blocked)  then "blocked"
        elif $known         then "paired"
        elif B($d.Trusted)  then "trusted"
        else "new" end) as $state
     | { conn: $conn, known: $known, name: $name,
         row: (["D", (if $conn then "1" else "0" end),
                (if $known then "1" else "0" end),
                icon_key($d), $name, S($d.Address),
                (if   S($d.AddressType) == "random" then "LE"
                 elif N($d.Class) != null then "BR/EDR"
                 else "LE" end),
                (if $bat != null then (N($bat.Percentage) | tostring) else "" end),
                ($state + (if N($d.RSSI) != null then " · \(N($d.RSSI)) dBm" else "" end)),
                (if $ti != null then $ti.detail else "" end)]
               | join("\u001f")) })
   | sort_by([(if .conn then 0 else 1 end), (if .known then 0 else 1 end), (.name | ascii_downcase)])
   | .[].row)
'

# ---- render --------------------------------------------------------------

a_alias=""; a_addr=""; a_power=""; a_disc=""; a_pair=""; a_scan=""
conn=(); known=(); keys=(); names=(); addrs=(); links=(); batts=(); states=(); details=()

load() {
	local json tag f1 f2 f3 f4 f5 f6 f7 f8 f9
	json=$(busctl --json=short --no-pager call org.bluez / \
		org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null) || return 1
	[ -n "$json" ] || return 1

	while IFS="$SEP" read -r tag f1 f2 f3 f4 f5 f6 f7 f8 f9; do
		case $tag in
			A)
				a_alias=$f1; a_addr=$f2; a_power=$f3
				a_disc=$f4; a_pair=$f5; a_scan=$f6
				;;
			D)
				conn+=("$f1");  known+=("$f2"); keys+=("$f3")
				names+=("$f4"); addrs+=("$f5"); links+=("$f6")
				batts+=("$f7"); states+=("$f8"); details+=("$f9")
				;;
		esac
	done < <(jq -r "$DEVICES_JQ" <<< "$json" 2>/dev/null)

	[ -n "$a_addr" ]
}

# "󰁿  60%", or six spaces so the column still pads when a device is silent
batt_cell() {
	local pct=$1 n
	if [ -z "$pct" ]; then
		printf '      '
		return
	fi
	n=$(( pct / 10 ))
	[ "$n" -gt 9 ] && n=9
	[ "$n" -lt 0 ] && n=0
	printf '%s %3s%%' "${BATT_ICONS[n]}" "$pct"
}

batt_colour() {
	local pct=$1
	if   [ -z "$pct" ];               then printf '%s' "$C_DIM"
	elif [ "$pct" -le "$BATT_CRIT" ]; then printf '%s' "$C_CRIT"
	elif [ "$pct" -le "$BATT_WARN" ]; then printf '%s' "$C_WARN"
	else                                   printf '%s' "$C_OK"
	fi
}

tooltip() {
	local i n_conn=0 n_known=0 has_batt=0

	for i in "${!names[@]}"; do
		[ "${conn[i]}"  = "1" ] && n_conn=$(( n_conn + 1 ))
		[ "${known[i]}" = "1" ] && n_known=$(( n_known + 1 ))
		[ -n "${batts[i]}" ] && has_batt=1
	done

	# column widths, measured on the plain text before any markup goes on
	local nw=0 aw=0 lw=0 sw=0 dw=0
	for i in "${!names[@]}"; do
		[ ${#names[i]}   -gt "$nw" ] && nw=${#names[i]}
		[ ${#addrs[i]}   -gt "$aw" ] && aw=${#addrs[i]}
		[ ${#links[i]}   -gt "$lw" ] && lw=${#links[i]}
		[ ${#states[i]}  -gt "$sw" ] && sw=${#states[i]}
		[ ${#details[i]} -gt "$dw" ] && dw=${#details[i]}
	done

	# dot + 2 + glyph + 2 + name + 2 + address + 2 + link [+ 2 + battery] + 2 + state
	local bw=0
	[ "$has_batt" -eq 1 ] && bw=8      # two spaces plus the six-cell battery
	local width=$(( 1 + 2 + 1 + 2 + nw + 2 + aw + 2 + lw + bw + 2 + sw ))

	# the continuation lines are indented to the name column and can outrun the
	# row they belong to; the rules span whichever is wider
	[ "$dw" -gt 0 ] && [ $(( dw + 6 )) -gt "$width" ] && width=$(( dw + 6 ))

	local head status
	case $a_power in
		on)            status="$n_conn connected" ;;
		off-blocked)   status="blocked (rfkill)" ;;
		off-enabling)  status="powering on" ;;
		off-disabling) status="powering off" ;;
		*)             status="powered off" ;;
	esac
	status+=" · $n_known paired"
	[ "$a_disc" = "true" ] && status+=" · discoverable"
	[ "$a_pair" = "true" ] && status+=" · pairable"
	[ "$a_scan" = "true" ] && status+=" · scanning"

	head="Bluetooth  ·  $a_alias"
	[ ${#head}   -gt "$width" ] && width=${#head}
	[ ${#a_addr} -gt "$width" ] && width=${#a_addr}
	[ ${#status} -gt "$width" ] && width=${#status}

	local rule="" out pad
	for (( i = 0; i < width; i++ )); do rule+="─"; done
	rule=$(paint "$C_DIM" "$rule")

	escape "$a_alias"
	pad=$(( (width - ${#head}) / 2 ))
	out="$(printf '%*s' "$pad" '')<b>Bluetooth</b>$(paint "$C_DIM" '  ·  ')$(paint "$C_ACCENT" "<b>$g_esc</b>")"
	pad=$(( (width - ${#a_addr}) / 2 ))
	out+="\n$(printf '%*s' "$pad" '')$(paint "$C_DIM" "$a_addr")"
	pad=$(( (width - ${#status}) / 2 ))
	out+="\n$(printf '%*s' "$pad" '')$(paint "$C_DIM" "$status")"
	out+="\n$rule"

	if [ ${#names[@]} -eq 0 ]; then
		out+="\n$(paint "$C_DIM" "no devices")"
		printf '%s' "$out"
		return
	fi

	local nm ad lk st bc glyph prev=1
	for i in "${!names[@]}"; do
		# a rule between the connected group and the rest
		[ "${conn[i]}" = "0" ] && [ "$prev" = "1" ] && [ "$i" -gt 0 ] && out+="\n$rule"
		prev=${conn[i]}

		glyph=${GLYPH[${keys[i]}]:-${GLYPH[unknown]}}
		printf -v nm '%-*s' "$nw" "${names[i]}"
		printf -v ad '%-*s' "$aw" "${addrs[i]}"
		printf -v lk '%-*s' "$lw" "${links[i]}"
		escape "$nm"; nm=$g_esc
		escape "${states[i]}"; st=$g_esc

		if [ "$has_batt" -eq 1 ]; then
			bc="  $(paint "$(batt_colour "${batts[i]}")" "$(batt_cell "${batts[i]}")")"
		else
			bc=""
		fi

		if [ "${conn[i]}" = "1" ]; then
			out+="\n$(paint "$C_OK" "●")  $(paint "$C_ACCENT" "$glyph")  $(paint "$C_FG" "<b>$nm</b>")"
			out+="  $(paint "$C_DIM" "$ad")  $(paint "$C_DIM" "$lk")$bc  $(paint "$C_FG" "$st")"
		else
			out+="\n$(paint "$C_DIM" "○  $glyph  $nm  $ad  $lk")$bc$(paint "$C_DIM" "  $st")"
		fi

		# codec, sample rate, channel mode, bitrate, absolute volume and the
		# transport state, indented under the name column
		if [ -n "${details[i]}" ]; then
			escape "${details[i]}"
			out+="\n      $(paint "$C_DIM" "$g_esc")"
		fi
	done

	printf '%s' "$out"
}

# ---- main ----------------------------------------------------------------

main() {
	local icon class tip i n=0

	if ! load; then
		printf '{"text":"%s","class":"off","tooltip":"no bluetooth adapter"}\n' "$ICON_OFF"
		exit 0
	fi

	tip=$(tooltip)

	for i in "${!conn[@]}"; do [ "${conn[i]}" = "1" ] && n=$(( n + 1 )); done

	if [ "$a_power" != "on" ]; then
		icon=$ICON_OFF
		case $a_power in
			off-blocked) class="disabled" ;;
			*)           class="off" ;;
		esac
	elif [ "$n" -gt 0 ]; then
		icon=$ICON_CONNECTED; class="connected"
	else
		icon=$ICON_ON; class="on"
	fi

	printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$icon" "$class" "$tip"
}

main "$@"
