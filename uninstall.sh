#!/usr/bin/env bash
# Removes roku-browser from this laptop and the Browser app from the Roku.
#   ./uninstall.sh            keeps ~/.config/roku/config.json (Roku address, developer password)
#   ./uninstall.sh --forget   removes that too
set -uo pipefail

CONFIG="$HOME/.config/roku/config.json"
DATA="$HOME/.local/share/roku-browser"
UNIT="$HOME/.config/systemd/user/roku-browser.service"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }

if [ -f "$CONFIG" ]; then
    read -r ip password < <(python3 -c 'import json, sys
c = json.load(open(sys.argv[1])); print(c.get("roku", ""), c.get("dev_password", ""))' "$CONFIG")
    if [ -n "$ip" ] && [ -n "$password" ]; then
        say "Removing the Browser app from the Roku at $ip"
        printf 'user = "rokudev:%s"\n' "$password" |
            curl -s -m 30 --digest -K - -F mysubmit=Delete -F archive= "http://$ip/plugin_install" >/dev/null &&
            echo "    Removed." || echo "    Couldn't reach the Roku; remove it later from its developer page."
    fi
fi

say "Removing roku-browser from this laptop"
systemctl --user disable --now roku-browser.service 2>/dev/null
rm -f "$UNIT"
systemctl --user daemon-reload
[ "$(readlink "$HOME/.local/bin/roku" 2>/dev/null)" = "$DATA/app/bin/roku" ] && rm -f "$HOME/.local/bin/roku"
rm -rf "$DATA"
echo "    Service, app and browser profile removed."

if [ "${1:-}" = "--forget" ]; then
    rm -f "$CONFIG"
    rmdir "$(dirname "$CONFIG")" 2>/dev/null
    echo "    Forgot the Roku address and developer password."
fi
