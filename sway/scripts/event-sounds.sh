#!/usr/bin/env bash
#
# Half-Life sound effects for hardware and session events.
#
#   event-sounds.sh                -> watch for the events, forever
#                                     (sway execs this)
#   event-sounds.sh play <event>   -> play that event's sound and exit
#
# The events are connect and disconnect, for the charger, usb-in and usb-out,
# for anything plugged into a USB port, display-in and display-out, for a
# monitor, fingerprint and fingerprint-wrong, for a scan that matched and one
# that did not, password, for a password that did not, shutdown, for the
# machine powering off, lock, for the screen locking, and battery-low and
# battery-critical. Those last three nothing here watches for: lock.sh plays
# lock on its way to the lock screen, and waybar's battery.sh plays the battery
# pair alongside its own notifications, at its own thresholds.
#
# Which file each one plays is the table below; the files are in sounds/hl2,
# all Half-Life sounds:
#
#   big-zap-warmup, access-denied, access-granted, power-deadbolt-1 and -2,
#   keycard
#       buttons/button1, 2, 3, 5, 6 and 9, untouched -- the names are the ones
#       the map editor gives them
#   gravity-gun-pickup, gravity-gun-drop
#       weapons/physcannon/physcannon_pickup and _drop, untouched
#   half-life-button, ne-nazhimaetsia, half-life-health-charger
#       not from the game files but from myinstants.com, under these names
#       ("... health-charger-sound" for the last); converted from mp3, the
#       first with its trailing silence cut off, the last cut down from 13.8s
#       to its first 1.6s and faded out
#   hev-power-20, hev-power-10
#       the suit's voice, its words strung end to end as the game does it:
#       fvox/fuzz twice, power_level_is, twenty, percent -- and for the other
#       boop three times, warning, power_level_is, ten, percent. The figures
#       are spoken, so they only hold while battery.sh warns at 20 and 10.
#   power-down
#       the first 3.2s of ambient/energy/powerdown2.wav, faded out
#   power-cut
#       ambient/energy/zap1.wav over the first two seconds of
#       ambient/energy/powerdown2.wav, which comes in 0.25s later: the spark
#       as the plug comes out, then the supply winding down
#   health-charger
#       the wall health charger, put together the way the game plays it:
#       items/medshot4.wav, then items/medcharge4.wav looping from 0.56s in,
#       faded out after two rounds
#   health-charger-empty
#       items/medshotno1.wav, the buzz the same charger gives when it has run
#       dry, brought up to the level of the other

set -uo pipefail

SOUNDS="$(dirname "$(readlink -f "$0")")/../sounds/hl2"
VOLUME=0.6     # 0-1.0, on top of the sink volume

declare -A SOUND=(
	[connect]=health-charger.wav
	[disconnect]=big-zap-warmup.wav
	[usb-in]=half-life-button.wav
	[usb-out]=ne-nazhimaetsia.wav
	[display-in]=half-life-button.wav
	[display-out]=ne-nazhimaetsia.wav
	[fingerprint]=keycard.wav
	[fingerprint-wrong]=access-denied.wav
	[password]=access-denied.wav
	[lock]=power-deadbolt-2.wav
	[shutdown]=power-down.wav
	[battery-low]=hev-power-20.wav
	[battery-critical]=hev-power-10.wav
)

play() {
	# Notification, so it is not paused or ducked like a music stream
	pw-play --media-role Notification --volume "$VOLUME" "$SOUNDS/${SOUND[$1]}" &
}

# ---- charger ---------------------------------------------------------------

# udev rather than polling: the kernel sends a power_supply uevent the moment
# the adapter's `online` flips, and `udevadm monitor` relays those to an
# ordinary user, so this needs no root, no udev rule and no timer.
#
# The events themselves are not worth parsing -- plugging in produces a burst
# of them, from the adapter and the battery both -- so each one is only a cue
# to re-read sysfs once the burst has gone quiet. A sound plays when the state
# that comes out differs from the one the last sound was for.

# How long the events must stop for before the state counts. Long enough to
# swallow a burst, and a USB-C charger that drops out for a moment while it
# negotiates; short enough that the sound still feels tied to the plug.
SETTLE=0.3

# Mains is a barrel or slim-tip adapter. USB is a type-C port, which reports
# online only while the laptop is the one drawing power -- a phone charging
# off the port does not count.
plugged() {
	local d
	for d in /sys/class/power_supply/*; do
		case "$(cat "$d/type" 2>/dev/null)" in
			Mains|USB) ;;
			*) continue ;;
		esac
		[ "$(cat "$d/online" 2>/dev/null)" = "1" ] && return 0
	done
	return 1
}

watch_charger() {
	local said now

	exec 3< <(udevadm monitor --udev --subsystem-match=power_supply 9>&-)
	trap "kill $! 2>/dev/null" EXIT

	# the state the last sound was played for
	said=0
	plugged && said=1

	# block for an event, then drain whatever follows it within SETTLE
	while read -r _ <&3; do
		while read -r -t "$SETTLE" _ <&3; do :; done

		now=0
		plugged && now=1
		[ "$now" -eq "$said" ] && continue

		if [ "$now" -eq 1 ]; then
			play connect
		else
			play disconnect
		fi
		said=$now
	done
}

# ---- usb -------------------------------------------------------------------

# One usb_device event per physical device, which is what the devtype filter
# is for: without it every interface of a device reports in as well.
#
# Two kinds of device are not somebody plugging something in. Root hubs, named
# usbN, come and go with their controller. And the laptop's own parts sit on
# the bus too -- camera, bluetooth, fingerprint reader -- and can drop off it
# and return on their own, with a radio switch say; sysfs marks those `fixed`.
# A device that has just been removed has no sysfs left to ask, so the fixed
# ones are remembered by path from the moment they are first seen.

# A hub or a dock brings its devices along one after another: the same action
# again within this many seconds is the same plug and passes in silence. The
# opposite action never waits -- that is a device going and coming straight
# back, a board being reset say, and both halves get their sound.
USB_SETTLE=1

watch_usb() {
	local action path d now _
	local last="" at=0
	local -A fixed=()

	exec 3< <(udevadm monitor --udev --subsystem-match=usb/usb_device 9>&-)
	trap "kill $! 2>/dev/null" EXIT

	for d in /sys/bus/usb/devices/*; do
		[ "$(cat "$d/removable" 2>/dev/null)" = "fixed" ] || continue
		path=$(readlink -f "$d")
		fixed[${path#/sys}]=1
	done

	# UDEV  [3059.341380] add      /devices/pci0000:00/.../usb3/3-2 (usb)
	while read -r _ _ action path _ <&3; do
		case "$action" in
			add)
				[[ ${path##*/} == usb* ]] && continue
				if [ "$(cat "/sys$path/removable" 2>/dev/null)" = "fixed" ]; then
					fixed[$path]=1
					continue
				fi
				;;
			remove)
				[[ ${path##*/} == usb* || -n ${fixed[$path]:-} ]] && continue
				;;
			*)
				continue
				;;
		esac

		# microseconds; the separator is a comma in some locales
		now=${EPOCHREALTIME/[.,]/}
		if [ "$action" != "$last" ] || [ $((now - at)) -ge $((USB_SETTLE * 1000000)) ]; then
			case "$action" in
				add)    play usb-in ;;
				remove) play usb-out ;;
			esac
		fi
		last=$action
		at=$now
	done
}

# ---- display ---------------------------------------------------------------

# The same shape as the charger: a drm uevent is only the cue to count the
# connectors that have something on them, and a sound plays when the count has
# moved. Counting the connectors rather than asking sway keeps this to cables
# -- an output switched off for idle, or disabled in the config, still has its
# monitor attached and says nothing.
displays() {
	local s n=0
	for s in /sys/class/drm/card*-*/status; do
		[ "$(cat "$s" 2>/dev/null)" = "connected" ] && n=$((n + 1))
	done
	echo "$n"
}

watch_display() {
	local said now

	exec 3< <(udevadm monitor --udev --subsystem-match=drm 9>&-)
	trap "kill $! 2>/dev/null" EXIT

	said=$(displays)

	while read -r _ <&3; do
		while read -r -t "$SETTLE" _ <&3; do :; done

		now=$(displays)
		if [ "$now" -gt "$said" ]; then
			play display-in
		elif [ "$now" -lt "$said" ]; then
			play display-out
		fi
		said=$now
	done
}

# ---- fingerprint -----------------------------------------------------------

# fprintd broadcasts the outcome of every scan on the system bus, whoever asked
# for it -- hyprlock, which talks to it directly, or sudo through pam_fprintd --
# so listening in covers them all and needs no hook in either.
#
# verify-match is a finger that was accepted. verify-no-match is not always one
# that was rejected: it is also what fprintd sends when the caller gives up, as
# hyprlock does once the password has been typed instead. What tells the two
# apart is whether a finger was on the reader in between -- the finger-present
# property going true since the scan was asked for. The retry outcomes, a
# smudged or off-centre read, are neither and stay silent.
#
#   ...Device.VerifyFingerSelected ('right-index-finger',)
#   ...Properties.PropertiesChanged ('net.reactivated.Fprint.Device',
#                                    {'finger-present': <true>}, @as [])
#   ...Device.VerifyStatus ('verify-no-match', true)
watch_fingerprint() {
	local line touched=0

	exec 3< <(gdbus monitor --system --dest net.reactivated.Fprint 2>/dev/null 9>&-)
	trap "kill $! 2>/dev/null" EXIT

	while read -r line <&3; do
		case "$line" in
			*"Device.VerifyFingerSelected "*)
				touched=0
				;;
			*"'finger-present': <true>"*)
				touched=1
				;;
			*"Device.VerifyStatus ('verify-match',"*)
				play fingerprint
				touched=0
				;;
			*"Device.VerifyStatus ('verify-no-match',"*)
				[ "$touched" -eq 1 ] && play fingerprint-wrong
				touched=0
				;;
		esac
	done
}

# ---- password --------------------------------------------------------------

# A password that did not match is logged by pam_unix from inside whichever
# program asked for it -- hyprlock, sudo, polkit, the login screen -- and the
# journal is the one place they all meet. Reading it takes membership of wheel
# or adm; without that there is nothing to follow and this watcher is silent.
#
#   pam_unix(hyprlock:auth): authentication failure; logname=bartek uid=1000
#   euid=1000 tty= ruser= rhost=  user=bartek
#
# The empty rhost is what makes it local. sshd fills it in, and somebody
# guessing passwords over the network should not be heard in the room.
watch_password() {
	local line

	exec 3< <(journalctl --follow --lines=0 --output=cat SYSLOG_FACILITY=10 2>/dev/null 9>&-)
	trap "kill $! 2>/dev/null" EXIT

	while read -r line <&3; do
		case "$line" in
			"pam_unix("*":auth): authentication failure;"*" rhost= "* | \
			"pam_unix("*":auth): authentication failure;"*" rhost=")
				play password
				;;
		esac
	done
}

# ---- shutdown --------------------------------------------------------------

# logind announces a shutdown before it starts one, and holds it back for
# whoever has taken a delay lock -- for InhibitDelayMaxSec at most, 5s unless
# logind.conf says otherwise, which is the ceiling on how long this sound can
# be. Without the lock the announcement and the session going down are the same
# moment and nothing would be heard.
#
# The lock is held by a `cat` under systemd-inhibit, reading a pipe this shell
# keeps open: closing the pipe releases it, and so does this script dying,
# however it dies. The pipe is opened last so that the monitor does not inherit
# its writing end and keep it open.
#
# Only a power-off gets the sound, but any shutdown gets the lock released at
# once -- a reboot has nothing to wait for. Which kind it is comes with the
# WithMetadata signal; logind sends that one first and the plain one after it.
watch_shutdown() {
	local line hold

	exec 3< <(gdbus monitor --system --dest org.freedesktop.login1 \
		--object-path /org/freedesktop/login1 2>/dev/null 9>&-)
	trap "kill $! 2>/dev/null" EXIT

	exec {hold}> >(systemd-inhibit --what=shutdown --mode=delay --who=event-sounds \
		--why="Playing the power down sound" cat >/dev/null 2>&1 9>&-)

	while read -r line <&3; do
		case "$line" in
			*"Manager.PrepareForShutdown"*"(true,"*) ;;
			*) continue ;;
		esac

		if [[ $line == *"<'power-off'>"* || $line == *"<'halt'>"* ]]; then
			play shutdown
			wait $!
		fi

		if [ -n "$hold" ]; then
			exec {hold}>&-
			hold=""
		fi
	done
}

# ---- main ------------------------------------------------------------------

# test is the old name for play
if [ "${1:-}" = "play" ] || [ "${1:-}" = "test" ]; then
	if [[ -z ${2:-} || ! -v SOUND[$2] ]]; then
		echo "usage: ${0##*/} play connect|disconnect|usb-in|usb-out|display-in|display-out|fingerprint|fingerprint-wrong|password|lock|shutdown|battery-low|battery-critical" >&2
		exit 2
	fi
	play "$2"
	wait
	exit
fi

# one set of watchers per session, so a second exec cannot double the sounds
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/event-sounds.lock"
flock -n 9 || exit 0

watch_charger &
watch_usb &
watch_display &
watch_fingerprint &
watch_password &
watch_shutdown &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
wait
