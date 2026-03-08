#!/bin/bash

# Nazwa Twojego połączenia hotspot w nmcli
NAME="RBMK-1000"

if [ "$1" == "toggle" ]; then
    # Sprawdź czy jest aktywny
    if nmcli connection show --active | grep -q "$NAME"; then
        nmcli connection down "$NAME"
    else
        nmcli connection up "$NAME"
    fi
fi

# Zwracanie danych do Waybara w formacie JSON
if nmcli connection show --active | grep -q "$NAME"; then
    echo '{"text": "󱂇", "class": "active", "tooltip": "Hotspot: ON"}'
else
    echo '{"text": "󰠅", "class": "inactive", "tooltip": "Hotspot: OFF"}'
fi
