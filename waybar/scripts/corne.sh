#!/bin/bash
# Get the percentage line, strip the percentage sign and whitespace
perc=$(upower -i /org/freedesktop/UPower/devices/keyboard_dev_FC_6D_F5_51_64_3B | grep percentage | awk '{print $2}' | tr -d '%')

if [ -z "$perc" ]; then
    echo "" # Hide if device is disconnected
else
    echo "{\"text\": \" $perc%\", \"tooltip\": \"Keyboard Battery: $perc%\", \"class\": \"keyboard\", \"percentage\": $perc}"
fi
