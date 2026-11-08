#!/usr/bin/env bash
# Installs roku-browser on this Linux laptop and the Browser app on your Roku.
# Run it again any time to update. The Roku needs two settings first; see README.md.
#
#   ROKU_IP=192.168.1.50 ./install.sh        skip discovery
#   ROKU_DEV_PASSWORD=... ./install.sh       don't prompt for the developer password
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/.local/share/roku-browser/app"
CONFIG="$HOME/.config/roku/config.json"
UNIT="$HOME/.config/systemd/user/roku-browser.service"
PORT=8765

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

cfg_get() {
    python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except FileNotFoundError: pass' "$CONFIG" "$1"
}

cfg_set() {
    mkdir -p "$(dirname "$CONFIG")"
    python3 - "$CONFIG" "$1" "$2" <<'EOF'
import json, os, sys
path, key, value = sys.argv[1:]
try:
    cfg = json.load(open(path))
except FileNotFoundError:
    cfg = {}
cfg[key] = value
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
EOF
}

xml() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" <<<"$2"; }

# ---- 1. what the laptop needs ----------------------------------------------
say "Checking this laptop"
missing=()
command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || missing+=("python3 (3.9+)")
python3 -c 'import aiohttp' 2>/dev/null || missing+=(aiohttp)
python3 -c 'import PIL' 2>/dev/null || missing+=(pillow)
command -v curl >/dev/null || missing+=(curl)
browser=""
for b in brave brave-browser chromium chromium-browser google-chrome-stable google-chrome; do
    if command -v "$b" >/dev/null; then browser=$b; break; fi
done
[ -n "$browser" ] || missing+=("a Chromium-based browser")
if ((${#missing[@]})); then
    echo "Missing: ${missing[*]}. Install them with your package manager, for example:"
    echo "  Arch:          sudo pacman -S python python-aiohttp python-pillow curl chromium"
    echo "  Debian/Ubuntu: sudo apt install python3 python3-aiohttp python3-pil curl chromium"
    echo "  Fedora:        sudo dnf install python3 python3-aiohttp python3-pillow curl chromium"
    exit 1
fi
command -v systemctl >/dev/null || fail "roku-browser runs as a systemd user service, and systemctl isn't available."
echo "    python3, aiohttp, pillow, curl and $browser are all here."

# ---- 2. find the Roku ------------------------------------------------------
roku_ip="${ROKU_IP:-$(cfg_get roku)}"
if [ -z "$roku_ip" ]; then
    say "Looking for Rokus on this network"
    mapfile -t found < <(python3 "$SRC/bin/roku" find 2>/dev/null || true)
    ((${#found[@]})) || fail "No Roku answered. Make sure it's on and on the same Wi-Fi as this laptop (guest networks often block devices from seeing each other), or run: ROKU_IP=<its address> ./install.sh"
    pick=0
    if ((${#found[@]} > 1)) && [ -t 0 ]; then
        for i in "${!found[@]}"; do echo "  $((i + 1))) ${found[$i]}"; done
        read -rp "Which one? [1] " n
        pick=$(( ${n:-1} - 1 ))
    fi
    roku_ip="${found[$pick]%% *}"
fi
info=$(curl -s -m 5 "http://$roku_ip:8060/query/device-info") || fail "Can't reach a Roku at $roku_ip."
name="$(xml friendly-device-name "$info") ($(xml model-name "$info"), Roku OS $(xml software-version "$info"))"
echo "    $name at $roku_ip"
cfg_set roku "$roku_ip"

# ---- 3. the Roku's software and its two settings ---------------------------
version=$(xml software-version "$info")
if [ -n "$version" ] && [ "${version%%.*}" -lt 10 ]; then
    fail "This Roku runs Roku OS $version; the Browser app needs Roku OS 10 or newer. Update it under Settings > System > System update > Check now."
fi
mode=$(xml ecp-setting-mode "$info")
if [ "$mode" = "limited" ] || [ "$mode" = "disabled" ]; then
    fail "The Roku only allows limited network control. On the Roku open Settings > System > Advanced system settings > Control by mobile apps > Network access, choose Enabled, then run this again."
fi
if [ "$(xml developer-enabled "$info")" != "true" ]; then
    fail "Developer mode is off. On the Roku remote press Home 3 times, Up 2 times, then Right, Left, Right, Left, Right, and follow README.md step 4. Then run this again."
fi

dev_ok() {
    [ -n "$1" ] && [ "$(printf 'user = "rokudev:%s"\n' "$1" | curl -s -m 10 -o /dev/null -w '%{http_code}' --digest -K - "http://$roku_ip/")" = 200 ]
}
password="${ROKU_DEV_PASSWORD:-$(cfg_get dev_password)}"
until dev_ok "$password"; do
    [ -t 0 ] || fail "The Roku's developer password is missing or wrong. Run: ROKU_DEV_PASSWORD='...' ./install.sh"
    [ -z "$password" ] || echo "    That password didn't work."
    read -rsp "Roku developer password (the one you set when enabling developer mode): " password
    echo
done
cfg_set dev_user rokudev
cfg_set dev_password "$password"
echo "    Developer mode is on and the password works; saved to $CONFIG (only you can read it)."

# ---- 4. the laptop service -------------------------------------------------
say "Installing roku-browser to $APP"
rm -rf "$APP.new"
mkdir -p "$APP.new"
cp -r "$SRC/server" "$SRC/bin" "$SRC/channel" "$APP.new/"
find "$APP.new" -name __pycache__ -prune -exec rm -rf {} +
rm -rf "$APP"
mv "$APP.new" "$APP"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/bin/roku" "$HOME/.local/bin/roku"

mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<EOF
[Unit]
Description=roku-browser: renders web pages for the Roku Browser app
After=network-online.target

[Service]
ExecStart=$(command -v python3) -I %h/.local/share/roku-browser/app/server/roku_browser.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable roku-browser.service >/dev/null 2>&1
systemctl --user restart roku-browser.service
for _ in $(seq 20); do
    curl -s -m 1 "http://127.0.0.1:$PORT/hello" >/dev/null && break
    sleep 0.5
done
curl -s -m 1 "http://127.0.0.1:$PORT/hello" >/dev/null ||
    fail "The service didn't start. See: journalctl --user -u roku-browser -n 30"
echo "    Service running and starting with your login."

if systemctl is-active -q ufw 2>/dev/null; then
    echo "    ufw is on; let the Roku reach this laptop with: sudo ufw allow $PORT/tcp && sudo ufw allow 8766/udp"
elif systemctl is-active -q firewalld 2>/dev/null; then
    echo "    firewalld is on; let the Roku reach this laptop with:"
    echo "      sudo firewall-cmd --permanent --add-port=$PORT/tcp --add-port=8766/udp && sudo firewall-cmd --reload"
fi

# ---- 5. the Roku app -------------------------------------------------------
say "Installing the Browser app on the Roku"
"$APP/bin/roku" sideload | sed 's/^/    /'
sleep 2
"$APP/bin/roku" browser >/dev/null

say "Waiting for the TV to connect"
for _ in $(seq 40); do
    if curl -s -m 2 "http://127.0.0.1:$PORT/state" | grep -q '"running": true'; then
        echo "    Connected. The Browser app is showing on your TV."
        cat <<EOF

Done. On the Roku remote: arrows move the cursor, OK clicks, Play/Pause searches,
* opens the menu, Back goes back. The app is also on the Roku home screen as "Browser".

From this laptop:
  roku open bbc.co.uk           show a page on the TV
  roku play ~/Videos/film.mp4   play a video (YouTube links open the YouTube app)
  roku                          use the keyboard as a remote
  roku --help                   everything else
EOF
        command -v roku >/dev/null || echo "(Add ~/.local/bin to your PATH to use the roku command.)"
        exit 0
    fi
    sleep 1
done
fail "The Browser app is installed but hasn't connected yet. If the TV says \"Looking for your laptop\", check that both are on the same network and that a firewall isn't blocking ports $PORT/tcp and 8766/udp."
