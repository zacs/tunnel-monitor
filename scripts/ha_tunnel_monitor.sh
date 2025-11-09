#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---------- Load HA env ----------
[[ -f /etc/ha_env ]] || { echo "Missing /etc/ha_env"; exit 1; }
# shellcheck source=/etc/ha_env
source /etc/ha_env
HA_URL="${HA_URL:?}"; HA_TOKEN="${HA_TOKEN:?}"; HOST_TAG="${HOST_TAG:-macmini}"

# ---------- Load tunnel options ----------
[[ -f /etc/sitemagic_env ]] || { echo "Missing /etc/sitemagic_env"; exit 1; }
# shellcheck source=/etc/sitemagic_env
source /etc/sitemagic_env
TARGET_NAME="${TARGET_NAME:-tokyo-target}"
TARGET_IP="${TARGET_IP:?}"
TS_PING_TARGET="${TS_PING_TARGET:-}"
TS_PING_COUNT="${TS_PING_COUNT:-3}"
TS_SKIP_NETCHECK="${TS_SKIP_NETCHECK:-false}"

SAFE_HOST="${HOST_TAG//-/_}"
SAFE_TGT="${TARGET_NAME//-/_}"

post_ha() {
  local entity="$1" json="$2"
  curl -sS -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    "$HA_URL/api/states/$entity" \
    -d "$json" >/dev/null
}

json_attr() {
  python3 - "$@" <<'PY'
import json, sys
d = {}
for kv in sys.argv[1:]:
    k,v = kv.split('=',1)
    d[k]=v
print(json.dumps(d))
PY
}

# =====================================================================
# 1) Site Magic (binary_sensor + latency)
# =====================================================================
ENTITY_AVAIL="binary_sensor.${SAFE_HOST}_site_magic_${SAFE_TGT}_availability"
ENTITY_LAT="sensor.${SAFE_HOST}_site_magic_${SAFE_TGT}_latency_ms"

OUT="$(ping -n -q -c 3 -W 1000 "$TARGET_IP" 2>/dev/null || true)"
RECV="$(printf "%s\n" "$OUT" | awk -F', ' '/packets transmitted/ {print $2}' | awk '{print $1}')"

if [[ -z "$RECV" || "$RECV" -eq 0 ]]; then
  SM_STATE="off"; SM_LAT="unavailable"
else
  SM_STATE="on"
  SM_LAT="$(printf "%s\n" "$OUT" | awk -F'[/= ]+' '/round-trip/ {printf("%.1f",$6)}')"
  [[ -z "$SM_LAT" ]] && SM_LAT="unavailable"
fi

ATTR_SM=$(json_attr "device_class=connectivity" "host=$HOST_TAG" "target_name=$TARGET_NAME" "target_ip=$TARGET_IP")
post_ha "$ENTITY_AVAIL" "$(printf '{"state":"%s","attributes":%s}' "$SM_STATE" "$ATTR_SM")"
if [[ "$SM_LAT" == "unavailable" ]]; then
  post_ha "$ENTITY_LAT" "$(printf '{"state":"unavailable","attributes":%s}' "$ATTR_SM")"
else
  post_ha "$ENTITY_LAT" "$(printf '{"state":"%s","attributes":%s}' "$SM_LAT" "$ATTR_SM")"
fi

# =====================================================================
# 2) Tailscale (binary_sensor + optional latency)
# =====================================================================
ENTITY_TS_STATUS="binary_sensor.${SAFE_HOST}_tailscale_status"
ENTITY_TS_LAT="sensor.${SAFE_HOST}_tailscale_latency_ms"

TS_STATE="off"
TS_LAT="unavailable"
TS_BACKEND="unknown"
TS_PEERS="0"
TS_SUFFIX=""
TS_DERP=""

if command -v tailscale >/dev/null 2>&1; then
  TS_JSON="$(tailscale status --json 2>/dev/null || true)"
  if [[ -n "$TS_JSON" ]]; then
    read -r TS_BACKEND TS_PEERS TS_SUFFIX <<<"$(python3 - <<'PY' "$TS_JSON"
import json,sys
j=json.loads(sys.argv[1])
backend=j.get("BackendState","unknown")
peers = len(j.get("Peer","")) if isinstance(j.get("Peer"),list) else len(j.get("Peer",{}))
suffix=j.get("MagicDNSSuffix","") or (j.get("Self",{}).get("DNSName","").split('.',1)[-1] if j.get("Self",{}).get("DNSName") else "")
print(backend, peers, suffix)
PY
)"
    if [[ "$TS_SKIP_NETCHECK" != "true" ]]; then
      TS_NET="$(tailscale netcheck --format=json 2>/dev/null || true)"
      if [[ -n "$TS_NET" ]]; then
        TS_DERP="$(python3 - <<'PY' "$TS_NET"
import json,sys ; j=json.loads(sys.argv[1]); print(j.get("PreferredDERP",""))
PY
)"
      fi
    fi
    [[ "$TS_BACKEND" == "Running" ]] && TS_STATE="on"
  fi

  if [[ -n "$TS_PING_TARGET" ]]; then
    PING_OUT="$(tailscale ping -c "${TS_PING_COUNT}" -q "$TS_PING_TARGET" 2>/dev/null || true)"
    TS_LAT="$(printf "%s\n" "$PING_OUT" | awk '/in [0-9.]+ms/ {for(i=1;i<=NF;i++){if($i=="in"){g=$(i+1); gsub("ms","",g); sum+=g; c++}}} END{if(c>0){printf("%.1f",sum/c)} }')"
    [[ -z "$TS_LAT" ]] && TS_LAT="unavailable"
  fi
fi

ATTR_TS=$(json_attr "device_class=connectivity" "host=$HOST_TAG" "backend_state=$TS_BACKEND" "peer_count=$TS_PEERS" "magic_dns_suffix=$TS_SUFFIX" "derp_region=$TS_DERP")
post_ha "$ENTITY_TS_STATUS" "$(printf '{"state":"%s","attributes":%s}' "$TS_STATE" "$ATTR_TS")"
if [[ "$TS_LAT" == "unavailable" ]]; then
  post_ha "$ENTITY_TS_LAT" "$(printf '{"state":"unavailable","attributes":%s}' "$ATTR_TS")"
else
  post_ha "$ENTITY_TS_LAT" "$(printf '{"state":"%s","attributes":%s}' "$TS_LAT" "$ATTR_TS")"
fi

# =====================================================================
# 3) strongSwan (binary_sensor + client count)
# =====================================================================
ENTITY_SW_SERVICE="binary_sensor.${SAFE_HOST}_strongswan_service"
ENTITY_SW_CLIENTS="sensor.${SAFE_HOST}_strongswan_clients"

SW_SERVICE="unknown"
SW_STATE="off"
SW_CLIENTS="0"

if command -v brew >/dev/null 2>&1; then
  SW_SERVICE="$(brew services list 2>/dev/null | awk '$1=="strongswan"{print $2; found=1} END{if(!found) print "unknown"}')"
fi
if [[ "$SW_SERVICE" == "unknown" || -z "$SW_SERVICE" ]]; then
  if pgrep -x charon >/dev/null 2>&1; then SW_SERVICE="started"; else SW_SERVICE="stopped"; fi
fi
[[ "$SW_SERVICE" == "started" ]] && SW_STATE="on" || SW_STATE="off"

if command -v ipsec >/dev/null 2>&1; then
  SW_CLIENTS="$(ipsec statusall 2>/dev/null | awk '/ESTABLISHED/ {c++} END{print (c+0)}')"
fi

ATTR_SW=$(json_attr "device_class=running" "host=$HOST_TAG")
post_ha "$ENTITY_SW_SERVICE" "$(printf '{"state":"%s","attributes":%s}' "$SW_STATE" "$ATTR_SW")"
post_ha "$ENTITY_SW_CLIENTS" "$(printf '{"state":"%s","attributes":%s}' "$SW_CLIENTS" "$ATTR_SW")"