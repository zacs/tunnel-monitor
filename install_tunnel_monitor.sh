#!/usr/bin/env bash
set -euo pipefail

# --------------------- configurable via env ---------------------
REPO_URL="${REPO_URL:-}"          # e.g. https://github.com/you/ha-tunnel-monitor.git
HOST_TAG="${HOST_TAG:-macmini-seattle}"
HA_URL="${HA_URL:-}"              # e.g. https://homeassistant.example.com:8123
HA_TOKEN="${HA_TOKEN:-}"          # long-lived HA token
CODE_DIR="${CODE_DIR:-$HOME/Code}"   # where to clone/update the repo
BREW_BIN_PATHS="/opt/homebrew/bin:/usr/local/bin"

# Tunnel monitor defaults (edit later in /etc/sitemagic_env if needed)
TARGET_NAME_DEFAULT="tokyo-udm"
TARGET_IP_DEFAULT="192.168.81.1"
# Optional tailscale peer for latency:
TS_PING_TARGET_DEFAULT=""
TS_PING_COUNT_DEFAULT="3"
TS_SKIP_NETCHECK_DEFAULT="false"
# ----------------------------------------------------------------

usage() {
  cat <<EOF
Usage (env vars):

  REPO_URL=<git url> HA_URL=<url> HA_TOKEN=<token> [HOST_TAG=<name>] [CODE_DIR=~/Code] $0

Example:
  REPO_URL=https://github.com/you/ha-tunnel-monitor.git \\
  HA_URL=https://homeassistant.example.com:8123 \\
  HA_TOKEN=eyJ0eXAiOiJK... \\
  HOST_TAG=macmini-seattle \\
  $0
EOF
}

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'"; exit 1; } }

[[ -z "${REPO_URL}" || -z "${HA_URL}" || -z "${HA_TOKEN}" ]] && { usage; exit 1; }
require git
require curl
export PATH="$BREW_BIN_PATHS:$PATH"

# --- clone or update repo locally ---
mkdir -p "$CODE_DIR"
cd "$CODE_DIR"
REPO_NAME="$(basename -s .git "$REPO_URL")"
if [[ -d "$REPO_NAME/.git" ]]; then
  echo "Updating existing repo $REPO_NAME ..."
  git -C "$REPO_NAME" pull --ff-only
else
  echo "Cloning $REPO_URL into $CODE_DIR ..."
  git clone "$REPO_URL"
fi
REPO_DIR="$CODE_DIR/$REPO_NAME"

# --- files expected in repo ---
REST_UPDATE_SCRIPT_REL="scripts/ha_update_rest.sh"
REST_UPDATE_LAUNCHD_REL="launchdaemons/com.local.ha-update-rest.plist"
UPDATE_SCRIPT_REL="scripts/ha_brew_update_db.sh"
UPDATE_LAUNCHD_REL="launchdaemons/com.local.ha-brew-update-db.plist"
TUN_MONITOR_REL="scripts/ha_tunnel_monitor.sh"
TUN_LAUNCHD_REL="launchdaemons/com.local.ha-tunnel-monitor.plist"

for f in "$REST_UPDATE_SCRIPT_REL" "$REST_UPDATE_LAUNCHD_REL" \
         "$UPDATE_SCRIPT_REL" "$UPDATE_LAUNCHD_REL" \
         "$TUN_MONITOR_REL" "$TUN_LAUNCHD_REL"; do
  [[ -f "$REPO_DIR/$f" ]] || { echo "Missing $f in repo"; exit 1; }
done

# --- write HA env (root-only) ---
echo "Writing /etc/ha_env ..."
sudo bash -c "cat > /etc/ha_env" <<EOF
HA_URL="$HA_URL"
HA_TOKEN="$HA_TOKEN"
HOST_TAG="$HOST_TAG"
EOF
sudo chmod 600 /etc/ha_env

# --- tunnel monitor env (Site Magic target + Tailscale knobs) ---
SM_ENV="/etc/sitemagic_env"
if [[ ! -f "$SM_ENV" ]]; then
  echo "Writing default $SM_ENV ..."
  sudo bash -c "cat > $SM_ENV" <<EOF
TARGET_NAME="$TARGET_NAME_DEFAULT"
TARGET_IP="$TARGET_IP_DEFAULT"
TS_PING_TARGET="$TS_PING_TARGET_DEFAULT"
TS_PING_COUNT="$TS_PING_COUNT_DEFAULT"
TS_SKIP_NETCHECK="$TS_SKIP_NETCHECK_DEFAULT"
EOF
  sudo chmod 600 "$SM_ENV"
fi

# --- install scripts to /usr/local/sbin ---
echo "Symlinking scripts to /usr/local/sbin ..."
sudo mkdir -p /usr/local/sbin
sudo ln -sf "$REPO_DIR/$REST_UPDATE_SCRIPT_REL" /usr/local/sbin/ha_update_rest.sh
sudo ln -sf "$REPO_DIR/$UPDATE_SCRIPT_REL"      /usr/local/sbin/ha_brew_update_db.sh
sudo ln -sf "$REPO_DIR/$TUN_MONITOR_REL"        /usr/local/sbin/ha_tunnel_monitor.sh
sudo chmod 755 /usr/local/sbin/ha_update_rest.sh /usr/local/sbin/ha_brew_update_db.sh /usr/local/sbin/ha_tunnel_monitor.sh

# --- install LaunchDaemons ---
echo "Symlinking LaunchDaemons ..."
sudo ln -sf "$REPO_DIR/$REST_UPDATE_LAUNCHD_REL" /Library/LaunchDaemons/com.local.ha-update-rest.plist
sudo ln -sf "$REPO_DIR/$UPDATE_LAUNCHD_REL"      /Library/LaunchDaemons/com.local.ha-brew-update-db.plist
sudo ln -sf "$REPO_DIR/$TUN_LAUNCHD_REL"         /Library/LaunchDaemons/com.local.ha-tunnel-monitor.plist
sudo chown root:wheel /Library/LaunchDaemons/com.local.ha-update-rest.plist \
                      /Library/LaunchDaemons/com.local.ha-brew-update-db.plist \
                      /Library/LaunchDaemons/com.local.ha-tunnel-monitor.plist
sudo chmod 644 /Library/LaunchDaemons/com.local.ha-update-rest.plist \
               /Library/LaunchDaemons/com.local.ha-brew-update-db.plist \
               /Library/LaunchDaemons/com.local.ha-tunnel-monitor.plist

# --- load LaunchDaemons ---
echo "Loading LaunchDaemons ..."
for job in com.local.ha-update-rest com.local.ha-brew-update-db com.local.ha-tunnel-monitor; do
  sudo launchctl unload "/Library/LaunchDaemons/${job}.plist" >/dev/null 2>&1 || true
  sudo launchctl load -w "/Library/LaunchDaemons/${job}.plist"
done

# --- trigger first runs ---
echo "Triggering first runs ..."
/usr/local/sbin/ha_brew_update_db.sh   || true
/usr/local/sbin/ha_update_rest.sh      || true
/usr/local/sbin/ha_tunnel_monitor.sh   || true

echo "Done. Entities should appear in Home Assistant shortly:
  - update.${HOST_TAG//-/_}_tailscale
  - update.${HOST_TAG//-/_}_strongswan
  - binary_sensor.${HOST_TAG//-/_}_site_magic_${TARGET_NAME_DEFAULT//-/_}_availability
  - sensor.${HOST_TAG//-/_}_site_magic_${TARGET_NAME_DEFAULT//-/_}_latency_ms
  - binary_sensor.${HOST_TAG//-/_}_tailscale_status
  - sensor.${HOST_TAG//-/_}_tailscale_latency_ms
  - binary_sensor.${HOST_TAG//-/_}_strongswan_service
  - sensor.${HOST_TAG//-/_}_strongswan_clients

Edit /etc/sitemagic_env to change targets/knobs, then:
  sudo launchctl kickstart -k system/com.local.ha-tunnel-monitor
"