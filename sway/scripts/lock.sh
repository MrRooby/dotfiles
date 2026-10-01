#!/usr/bin/env bash
#
# Lock the screen: the lock sound, then hyprlock.
#
# Everything that locks runs this -- the keybinding in sway's config,
# hypridle's lock_cmd, which is where `loginctl lock-session`, the idle timeout
# and suspend all end up, and caffeine.sh for the lid. Nothing announces a lock
# under sway for event-sounds.sh to listen for: sway has no event for it and
# hyprlock does not set logind's LockedHint, so the sound has to be played by
# whoever starts the lock screen.
#
# The pidof check is the one hypridle's lock_cmd used to carry: a second
# hyprlock on top of the first would hold its own claim on the fingerprint
# reader.

pidof hyprlock >/dev/null && exit 0

"$(dirname "$(readlink -f "$0")")/event-sounds.sh" play lock &
exec hyprlock
