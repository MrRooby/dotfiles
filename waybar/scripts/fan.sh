#!/usr/bin/env bash
#
# Print the ThinkPad fan speed in RPM
#
# Requirements:
# 	thinkpad_acpi (loaded automatically on ThinkPads)

main() {
	local path rpm

	# thinkpad_acpi exposes the fan through hwmon, but the hwmon index is not
	# stable across boots, so look the device up by name instead
	for path in /sys/class/hwmon/*; do
		[[ -r $path/name && -r $path/fan1_input ]] || continue

		if [[ $(< "$path/name") == "thinkpad" ]]; then
			rpm=$(< "$path/fan1_input")
			break
		fi
	done

	# fall back to the procfs interface
	if [[ -z $rpm && -r /proc/acpi/ibm/fan ]]; then
		rpm=$(awk '/^speed:/ {print $2}' /proc/acpi/ibm/fan)
	fi

	echo "${rpm:-0}"
}

main "$@"
