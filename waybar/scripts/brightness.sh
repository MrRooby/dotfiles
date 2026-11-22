#!/usr/bin/env bash
#
# Brightness for the custom/brightness module, with one target per bar
#
# config.jsonc runs a separate bar for the laptop panel and for external
# screens and gives each its own target, because waybar does not pass
# WAYBAR_OUTPUT_NAME to on-scroll commands (only to exec):
#
#   internal   laptop panel, through brightnessctl
#   ddc        external monitor through ddcutil: DDC/CI over the video cable
#              (I2C), or, for monitors that only take commands over their USB
#              upstream cable (EIZO ColorEdge, ...), the USB Monitor Control
#              Class. The USB path needs rw access to the monitor's
#              /dev/usb/hiddev* (see ~/dotfiles/system/udev).
#
# A screen that neither path reaches still shows "--" with class
# "unavailable", and its tooltip says why. `get` always exits 0 for that:
# waybar hides a custom module whose exec fails.
#
# A DDC write takes 100-300 ms, so a fast scroll would queue a pile of ddcutil
# calls and the monitor would trail behind the wheel. Instead each scroll only
# moves a target kept in $STATE and pokes waybar, and a single worker pushes
# the newest target to the monitor, skipping the steps in between.
#
# The tooltip follows battery.sh: centred header, gauge, rules, and a
# label/value table. It describes the screen the bar sits on. EDID facts come
# from edid-decode and are cached per output. Monitor readings (contrast,
# preset, usage hours) are taken in the same ddcutil call as the brightness
# read, so they refresh on the module's interval and cost no extra bus traffic.
#
# Requirements:
# 	brightnessctl
# 	ddcutil (for "ddc"; the user needs rw access to /dev/i2c-*, and to
# 	         /dev/usb/hiddev* for monitors controlled over USB)
# 	edid-decode (optional, for make/model/size/year in the tooltip)
# 	notify-send (libnotify)

export LC_ALL=C.utf8

STEP=5
SIGNAL=13
FRESH=20  # seconds a DDC value set from here is trusted over a fresh read
STATE=${XDG_RUNTIME_DIR:-/tmp}/waybar-brightness

usage() {
	cat <<- EOF
		USAGE: ${0##*/} get|up|down internal|ddc [step]

		Print or adjust the brightness of the laptop panel (internal) or of an
		external monitor over DDC/CI (ddc). Default step: $STEP%

		EXAMPLES:
		    $ ${0##*/} get ddc
		    $ ${0##*/} up internal
		    $ ${0##*/} down ddc 10
	EOF
	exit 1
}

rd() { [[ -r $1 ]] && cat "$1"; }

refresh() { pkill -RTMIN+$SIGNAL -x waybar; }

notify() { # label percent
	notify-send "Brightness ($1): $2%" -h int:value:"$2" -i "contrast" \
		-h string:x-canonical-private-synchronous:backlight
}

# pango + JSON escaping, same as battery.sh
g_esc=""
escape() {
	local s=${1//&/\&amp;}
	s=${s//</\&lt;}
	s=${s//>/\&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# ---- theme colours -------------------------------------------------------

# Read from current-theme.css at runtime so the theme switcher carries over;
# @references are followed until a hex falls out (see battery.sh).

declare -A THEME=()
theme_css="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/current-theme.css"
if [[ -r $theme_css ]]; then
	while read -r kw name val; do
		[[ $kw == "@define-color" ]] || continue
		THEME[$name]=${val%;}
	done < "$theme_css"
fi

g_hex=""
resolve() {
	local v=${THEME[$1]:-} n=0
	while [[ ${v:0:1} == "@" ]] && ((n++ < 10)); do v=${THEME[${v#@}]:-}; done
	if [[ $v =~ ^#[0-9a-fA-F]{3,8}$ ]]; then g_hex=$v; else g_hex=""; fi
}

resolve tooltip-dim; C_DIM=$g_hex
resolve tooltip-fg;  C_FG=$g_hex
resolve tooltip-br;  C_ACCENT=$g_hex

paint() {
	if [[ -n $1 ]]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# ---- tooltip -------------------------------------------------------------

# Rows go into LABELS/VALUES; a "-" label draws a rule instead of a row.
LABELS=(); VALUES=()
row() { [[ -n $2 ]] && { LABELS+=("$1"); VALUES+=("$2"); }; }
rule() { LABELS+=("-"); VALUES+=(""); }

# printf pads by bytes, so "×" and "·" would push a column; pad by characters
spaces() { (($1 > 0)) && printf "%*s" "$1" ""; }

# tooltip <percent or empty> <title>
# Widths are measured on the plain text and the markup wrapped afterwards.
tooltip() {
	local pct=$1 title=$2 lw=0 vw=0 i l v inner head pad fill="" rest="" line="" out
	for i in "${!LABELS[@]}"; do
		[[ ${LABELS[i]} == "-" ]] && continue
		((${#LABELS[i]} > lw)) && lw=${#LABELS[i]}
		((${#VALUES[i]} > vw)) && vw=${#VALUES[i]}
	done
	head="${pct:---}${pct:+%}  ·  $title"
	inner=$((lw + 2 + vw))
	if ((${#head} > inner)); then
		inner=${#head}
		vw=$((inner - lw - 2))
	fi
	pad=$(((inner - ${#head}) / 2))

	escape "$title"
	printf -v out '%*s' "$pad" ''
	out+="<b>${pct:---}${pct:+%}</b>$(paint "$C_DIM" '  ·  ')$(paint "$C_ACCENT" "<b>$g_esc</b>")"

	if [[ -n $pct ]]; then
		local f=$((pct * inner / 100))
		for ((i = 0; i < inner; i++)); do
			if ((i < f)); then fill+="█"; else rest+="░"; fi
		done
		out+="\n$(paint "$C_ACCENT" "$fill")$(paint "$C_DIM" "$rest")"
	fi

	for ((i = 0; i < inner; i++)); do line+="─"; done
	line="\n$(paint "$C_DIM" "$line")"

	# a rule is drawn only when a row follows it, so an empty section leaves
	# no doubled or trailing rule behind
	out+="$line"
	local ruled=1
	for i in "${!LABELS[@]}"; do
		if [[ ${LABELS[i]} == "-" ]]; then
			ruled=0
			continue
		fi
		((ruled)) || out+="$line"
		ruled=1
		l=${LABELS[i]}$(spaces $((lw - ${#LABELS[i]})))
		v=$(spaces $((vw - ${#VALUES[i]})))${VALUES[i]}
		escape "$l"; l=$g_esc
		escape "$v"; v=$g_esc
		out+="\n$(paint "$C_DIM" "$l")  $(paint "$C_FG" "<b>$v</b>")"
	done
	TOOLTIP=$out
}

# emit <percent or empty> <title>; uses the rows collected so far
emit() {
	tooltip "$1" "$2"
	if [[ -n $1 ]]; then
		printf '{"text":"%s%%","percentage":%d,"tooltip":"%s","class":"ok"}\n' \
			"$1" "$1" "$TOOLTIP"
	else
		printf '{"text":"--","percentage":0,"tooltip":"%s","class":"unavailable"}\n' \
			"$TOOLTIP"
	fi
}

# 15634 -> "15 634"
group() {
	local n=$1 out=""
	while ((${#n} > 3)); do
		out=" ${n: -3}$out"
		n=${n:0:${#n}-3}
	done
	printf '%s' "$n$out"
}

# ---- EDID ----------------------------------------------------------------

# EDID checksum of a sysfs connector dir, empty when it has none. sysfs lists
# the edid attribute as 0 bytes whatever it holds, so [[ -s ]] cannot be used.
edid_sum() {
	local crc len
	read -r crc len < <(cksum < "$1/edid" 2> /dev/null)
	((len > 0)) && printf '%s' "$crc"
}

# "connector:checksum" of every connected output's EDID. Changes whenever a
# monitor is plugged, unplugged or swapped for another on the same port.
outputs_sig() {
	local d
	for d in /sys/class/drm/card*-*; do
		[[ $(rd "$d/status") == connected ]] || continue
		printf '%s:%s ' "${d##*/card[0-9]-}" "$(edid_sum "$d")"
	done
}

# Make/model/serial/size/year/native mode of an output. Cached by the EDID's
# checksum, not the port name, so another monitor on the same port is read
# afresh. Sets E_MAKE E_MODEL E_SERIAL E_SIZE E_YEAR E_NATIVE.
edid() {
	local out=$1 cache sys sum
	E_MAKE="" E_MODEL="" E_SERIAL="" E_SIZE="" E_YEAR="" E_NATIVE=""
	sys=$(printf '%s\n' /sys/class/drm/card*-"$out" | head -1)
	sum=$(edid_sum "$sys") || return 1
	cache=$STATE/edid-$sum
	if [[ ! -s $cache ]]; then
		{
			if command -v edid-decode > /dev/null; then
				edid-decode "$sys/edid" 2> /dev/null | awk -v pnp=/usr/share/hwdata/pnp.ids '
					/^ *Manufacturer:/ {
						id = $2; make = id
						while ((getline l < pnp) > 0)
							if (substr(l, 1, 4) == id "\t") { make = substr(l, 5); break }
						split(make, mw, " "); print "E_MAKE=" mw[1]
					}
					/Display Product Name:/      { gsub(/.*: *\x27|\x27.*/, ""); name = $0 }
					/Alphanumeric Data String:/  { gsub(/.*: *\x27|\x27.*/, ""); if (alnum == "") alnum = $0 }
					/Display Product Serial Number:/ { gsub(/.*: *\x27|\x27.*/, ""); print "E_SERIAL=" $0 }
					/Made in:/ { if (match($0, /[0-9][0-9][0-9][0-9]/)) print "E_YEAR=" substr($0, RSTART, 4) }
					/Maximum image size:/ {
						w = $4; h = $7
						if (w > 0 && h > 0) printf "E_SIZE=%.0f\"\n", sqrt(w * w + h * h) / 2.54
					}
					END { m = name != "" ? name : alnum; if (m != "") print "E_MODEL=" m }
				'
			fi
			local mode
			mode=$(head -1 "$sys/modes" 2> /dev/null)
			[[ -n $mode ]] && echo "E_NATIVE=${mode/x/×}"
		} > "$cache.tmp"
		mv "$cache.tmp" "$cache"
	fi
	local k v
	while IFS='=' read -r k v; do
		[[ $k == E_* ]] && printf -v "$k" '%s' "$v"
	done < "$cache"
}

# ---- internal ------------------------------------------------------------

internal_get() { brightnessctl -m | awk -F, '{ print int($4) }'; }

internal() {
	local action=$1 step=$2 out pct dev
	case $action in
		get)
			out=${WAYBAR_OUTPUT_NAME:-eDP-1}
			pct=$(internal_get)
			dev=$(brightnessctl -m | cut -d, -f1)
			identity_rows "$out"
			rule
			row "Control" "backlight"
			row "Device" "$dev"
			emit "$pct" "$out"
			;;
		up | down)
			[[ $action == up ]] && step="$step%+" || step="$step%-"
			brightnessctl -n set "$step" > /dev/null
			refresh
			notify "laptop" "$(internal_get)"
			;;
	esac
}

# ---- ddc -----------------------------------------------------------------

# Every display ddcutil can talk to, cached as "id connector model" lines,
# where id names the link and prefixes its state files in $STATE:
#   i2c-3     DDC/CI on /dev/i2c-3
#   usb-1.5   USB bus 1, device 5. ddcutil does not know which connector a
#             USB monitor is on, so it is matched to the connector whose
#             (failed) I2C probe reported the same make and model.
# A monitor reachable both ways is listed with I2C first and that wins.
# The cache is dropped when the set of connected monitors changes (and with it
# the per-link readings, which may now belong to a different monitor).
#
# exec knows its bar's output and only accepts that display; a monitor that
# just came up may not answer DDC yet, so a miss re-detects, at most every
# RETRY seconds. On-scroll commands do not know the output and take the
# first display.
RETRY=30
ddc_detect() {
	local want=${WAYBAR_OUTPUT_NAME:-} sig id c m
	sig=$(outputs_sig)
	if [[ $sig != "$(rd "$STATE/outputs")" ]]; then
		rm -f "$STATE/displays" "$STATE"/i2c-* "$STATE"/usb-*
		printf '%s' "$sig" > "$STATE/outputs"
	elif [[ -e $STATE/displays ]] &&
		{ [[ -n $want ]] && ! grep -q " $want " "$STATE/displays" || [[ ! -s $STATE/displays ]]; } &&
		(($(date +%s) - $(stat -c %Y "$STATE/displays") >= RETRY)); then
		rm -f "$STATE/displays"
	fi
	# an empty file is kept too: "nothing answered", retried after RETRY
	if [[ ! -e $STATE/displays ]]; then
		ddcutil detect --terse --enable-usb 2> /dev/null | awk '
			function flush() {
				if (mon != "" && conn != "") conn_of[mon] = conn
				if (ok && bus != "") { n++; ids[n] = "i2c-" bus; conns[n] = conn; mons[n] = mon; models[n] = model }
				if (ok && usb != "") { n++; ids[n] = "usb-" usb; conns[n] = ""; mons[n] = mon; models[n] = model }
				ok = 0; bus = ""; usb = ""; conn = ""; mon = ""; model = ""
			}
			/^Display [0-9]+/ { flush(); ok = 1; next }
			/^Invalid display/ { flush(); next }
			/I2C bus:/ { sub(/.*\/dev\/i2c-/, ""); bus = $0 }
			/USB bus:device:/ { usb = $NF }
			/DRM connector:/ { sub(/.*card[0-9]+-/, ""); conn = $0 }
			# make:model:serial; the key is make:model, as the serial may
			# read differently (or be empty) over I2C and over USB
			/Monitor:/ { sub(/.*Monitor: */, ""); full = $0; split(full, f, ":"); mon = f[1] ":" f[2]; model = f[2] }
			END {
				flush()
				for (i = 1; i <= n; i++) {
					c = conns[i] != "" ? conns[i] : conn_of[mons[i]]
					if (c == "") continue
					print ids[i], c, models[i]
				}
			}
		' > "$STATE/displays.tmp"
		mv "$STATE/displays.tmp" "$STATE/displays"
	fi
	ID="" CONN="" MODEL=""
	while read -r id c m; do
		if [[ -z $want || $c == "$want" ]]; then
			ID=$id CONN=$c MODEL=$m
			break
		fi
	done < "$STATE/displays"
	case $ID in
		i2c-*) DDC=(--bus "${ID#i2c-}") ;;
		usb-*) DDC=(--enable-usb --usb "${ID#usb-}") ;;
	esac
	P=$STATE/$ID  # per-display state prefix
	[[ -n $ID ]]
}

forget() { rm -f "$STATE/displays"; }  # unplugged or moved; detect again

# Read the monitor: brightness plus the tooltip's live rows, in one call.
# Sets target/applied/max/vcp and prints the brightness percent.
ddc_read() {
	local out code raw max pct contrast="" preset="" hours=""
	out=$(ddcutil "${DDC[@]}" getvcp 10 12 14 C0 --brief 2> /dev/null)
	while read -r _ code _ a b; do
		case $code in
			10) raw=$a max=$b ;;
			12) ((b > 0)) && contrast=$(((a * 100 + b / 2) / b)) ;;
			14) preset=${a#x} ;;
			C0) hours=$a ;;
		esac
	done <<< "$out"
	((max > 0)) || { forget; return 1; }
	pct=$(((raw * 100 + max / 2) / max))
	echo "$max" > "$P-max"
	echo "$pct" > "$P-applied"
	echo "$pct" > "$P-target"
	printf '%s\n' "contrast=$contrast" "preset=$preset" "hours=$hours" > "$P-vcp"
	echo "$pct"
}

ddc_current() {
	local t=$P-target
	if [[ -s $t && -s $P-max ]] && (($(date +%s) - $(stat -c %Y "$t") < FRESH)); then
		cat "$t"
	else
		ddc_read
	fi
}

# MCCS colour preset codes (VCP 0x14)
preset_name() {
	case ${1,,} in
		01) echo "sRGB" ;;        02) echo "Native" ;;
		03) echo "4000 K" ;;      04) echo "5000 K" ;;
		05) echo "6500 K" ;;      06) echo "7500 K" ;;
		07) echo "8200 K" ;;      08) echo "9300 K" ;;
		09) echo "10000 K" ;;     0a) echo "11500 K" ;;
		0b) echo "User 1" ;;      0c) echo "User 2" ;;
		0d) echo "User 3" ;;      "") ;;
		*) echo "0x$1" ;;
	esac
}

# Push the newest target to the monitor. Only one worker runs at a time;
# scrolls that arrive meanwhile just move the target and leave it to us.
ddc_apply() {
	local lk t raw max fails=0
	exec {lk}> "$P-apply.lock"
	while flock -n "$lk"; do
		while t=$(rd "$P-target"); [[ $t != "$(rd "$P-applied")" ]]; do
			max=$(rd "$P-max")
			raw=$(((t * max + 50) / 100))
			if ddcutil "${DDC[@]}" --noverify setvcp 10 "$raw" > /dev/null 2>&1; then
				echo "$t" > "$P-applied"
			elif ((++fails >= 3)); then
				forget
				break
			fi
		done
		flock -u "$lk"
		# a scroll that landed after the last check but before the unlock saw
		# the lock held and left its target for us; pick it up if nobody has
		((fails >= 3)) && break
		[[ $(rd "$P-target") == "$(rd "$P-applied")" ]] && break
	done
	exec {lk}>&-
}

# EDID rows for an output; shared by the working and the failing tooltip, so
# a monitor without DDC/CI still says what it is
identity_rows() {
	edid "$1"
	row "Make" "$E_MAKE"
	row "Model" "${E_MODEL:-$2}"
	row "Serial" "$E_SERIAL"
	row "Size" "$E_SIZE"
	row "Native" "$E_NATIVE"
	row "Made" "$E_YEAR"
}

# tooltip for a screen whose brightness cannot be controlled: <output> <why>
ddc_unavailable() {
	identity_rows "$1"
	rule
	row "Status" "$2"
	emit "" "$1"
}

ddc_tooltip_get() {
	local pct contrast="" preset="" hours="" k v
	pct=$(ddc_current)
	if [[ -z $pct ]]; then
		ddc_unavailable "$CONN" "DDC/CI read failed"
		return
	fi
	while IFS='=' read -r k v; do
		case $k in
			contrast) contrast=$v ;; preset) preset=$v ;; hours) hours=$v ;;
		esac
	done < <(rd "$P-vcp")
	identity_rows "$CONN" "$MODEL"
	rule
	row "Contrast" "${contrast:+$contrast%}"
	row "Preset" "$(preset_name "$preset")"
	row "Usage" "${hours:+$(group "$hours") h}"
	rule
	if [[ $ID == usb-* ]]; then
		row "Control" "USB"
		row "Device" "${ID#usb-}"
	else
		row "Control" "DDC/CI"
		row "Bus" "$ID"
	fi
	emit "$pct" "$CONN"
}

ddc() {
	local action=$1 step=$2 lk cur new
	local out=${WAYBAR_OUTPUT_NAME:-external}
	# get still exits 0 here, so waybar keeps showing the module
	if ! command -v ddcutil > /dev/null; then
		[[ $action == get ]] && { ddc_unavailable "$out" "ddcutil not installed"; return 0; }
		return 1
	fi
	if ! ddc_detect; then
		[[ $action == get ]] && { ddc_unavailable "$out" "no DDC/CI or USB"; return 0; }
		return 1
	fi

	case $action in
		get) ddc_tooltip_get ;;
		up | down)
			[[ $action == down ]] && step=$((-step))
			exec {lk}> "$P-target.lock"
			flock "$lk"
			cur=$(ddc_current) || exit 1
			new=$((cur + step))
			((new < 0)) && new=0
			((new > 100)) && new=100
			echo "$new" > "$P-target"
			exec {lk}>&-
			refresh
			notify "$MODEL" "$new"
			ddc_apply
			;;
	esac
}

main() {
	local action=$1 target=$2 step=${3:-$STEP}
	[[ $action =~ ^(get|up|down)$ ]] || usage
	((step > 0)) || usage
	mkdir -p "$STATE"
	case $target in
		internal) internal "$action" "$step" ;;
		ddc) ddc "$action" "$step" ;;
		*) usage ;;
	esac
}

main "$@"
