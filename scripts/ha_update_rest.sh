#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

[[ -f /etc/ha_env ]] || { echo "Missing /etc/ha_env"; exit 1; }
# shellcheck source=/etc/ha_env
source /etc/ha_env
HA_URL="${HA_URL:?}"; HA_TOKEN="${HA_TOKEN:?}"; HOST_TAG="${HOST_TAG:-macmini-seattle}"

SAFE_HOST="${HOST_TAG//-/_}"
ENTITY_TS="update.${SAFE_HOST}_tailscale"
ENTITY_SW="update.${SAFE_HOST}_strongswan"

curl_ha() {
  local entity="$1" json="$2"
  curl -sS -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    "${HA_URL%/}/api/states/${entity}" \
    -d "${json}" >/dev/null
}

installed_version() { brew list --versions "$1" 2>/dev/null | awk '{print $2}' | head -n1; }
latest_version()    { brew info "$1" 2>/dev/null | awk -v pfx="$1: stable " 'index($0,pfx)==1{print $3; exit}'; }
is_outdated()       { brew outdated --quiet | grep -qx "$1"; }

publish_update_entity() {
  local pkg="$1" entity="$2" pretty="$3"
  local inst ver state notes
  inst="$(installed_version "$pkg" || true)"; [[ -z "$inst" ]] && inst="unknown"
  ver="$(latest_version "$pkg" || true)";   [[ -z "$ver"  ]] && ver="unknown"
  if is_outdated "$pkg"; then
    state="on";  notes="${pretty} update available: ${inst} → ${ver}"
  else
    state="off"; notes="${pretty} is up to date."
  fi
  curl_ha "$entity" "$(printf '{"state":"%s","attributes":{"installed_version":"%s","latest_version":"%s","release_notes":"%s","host":"%s"}}' \
    "$state" "$inst" "$ver" "$notes" "$HOST_TAG")"
}

publish_update_entity "tailscale"  "$ENTITY_TS" "Tailscale"
publish_update_entity "strongswan" "$ENTITY_SW" "strongSwan"