#!/bin/bash
# tunnel_monitor.sh - Monitor VPN services and report to Home Assistant

# Prevent multiple instances
LOCK_FILE="/tmp/tunnel_monitor.lock"
if [[ -f "$LOCK_FILE" ]]; then
    if ps -p $(cat "$LOCK_FILE") > /dev/null 2>&1; then
        # Another instance is running
        exit 0
    else
        # Stale lock file, remove it
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

# Cleanup on exit
trap 'rm -f "$LOCK_FILE"' EXIT

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi

# Required variables check
if [[ -z "$HA_URL" || -z "$HA_TOKEN" || -z "$HOST_TAG" ]]; then
    echo "Error: Missing required configuration variables"
    exit 1
fi

# Logging
LOG_FILE="$SCRIPT_DIR/tunnel_monitor.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Home Assistant API functions
send_to_ha() {
    local entity_id="$1"
    local state="$2"
    local attributes="$3"
    
    local payload="{\"state\": \"$state\""
    if [[ -n "$attributes" ]]; then
        payload="$payload, \"attributes\": $attributes"
    fi
    payload="$payload}"
    
    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$HA_URL/api/states/$entity_id" >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        log "Updated HA entity: $entity_id = $state"
    else
        log "Failed to update HA entity: $entity_id"
    fi
}

# Monitor Unifi Site Magic
check_site_magic() {
    log "Checking Unifi Site Magic connectivity..."
    
    # Try to reach the Tokyo UDM
    local tokyo_udm_ip="${TOKYO_UDM_IP:-192.168.1.1}"
    
    # Perform multiple pings to get average latency
    local ping_output=$(ping -c 3 -W 3000 "$tokyo_udm_ip" 2>/dev/null)
    local ping_success=$?
    
    if [[ $ping_success -eq 0 ]]; then
        # Extract average latency from macOS ping output
        # From: "round-trip min/avg/max/stddev = 3.199/5.975/7.394/1.963 ms"
        local avg_latency=$(echo "$ping_output" | grep "round-trip" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | cut -d'.' -f1)
        
        # If we can't parse the average, calculate from individual pings
        if [[ -z "$avg_latency" || "$avg_latency" == "" ]]; then
            local latencies=$(echo "$ping_output" | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/')
            if [[ -n "$latencies" ]]; then
                avg_latency=$(echo "$latencies" | awk '{sum+=$1; n++} END {if(n>0) printf "%.0f", sum/n; else print "0"}')
            else
                avg_latency=0
            fi
        fi
        
        send_to_ha "binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability" "on" \
            "{\"friendly_name\": \"${HOST_TAG} Site Magic\", \"device_class\": \"connectivity\", \"latency_ms\": $avg_latency}"
        send_to_ha "sensor.${HOST_TAG}_site_magic_tokyo_udm_latency_ms" "$avg_latency" \
            "{\"friendly_name\": \"${HOST_TAG} Site Magic Latency\", \"unit_of_measurement\": \"ms\"}"
        
        log "Site Magic: UP (${avg_latency}ms avg)"
    else
        send_to_ha "binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability" "off" \
            "{\"friendly_name\": \"${HOST_TAG} Site Magic\", \"device_class\": \"connectivity\", \"latency_ms\": null}"
        send_to_ha "sensor.${HOST_TAG}_site_magic_tokyo_udm_latency_ms" "unavailable" \
            "{\"friendly_name\": \"${HOST_TAG} Site Magic Latency\", \"unit_of_measurement\": \"ms\"}"
        
        log "Site Magic: DOWN"
    fi
}

# Monitor Tailscale
check_tailscale() {
    log "Checking Tailscale connectivity..."
    
    # Use tailscale command from PATH (Homebrew installation)
    if command -v tailscale >/dev/null 2>&1; then
        # Get Tailscale status
        local tailscale_output=$(tailscale status 2>/dev/null)
        local tailscale_exit_code=$?
        
        if [[ $tailscale_exit_code -eq 0 && -n "$tailscale_output" ]]; then
            # Get the current hostname without .local suffix
            local current_hostname=$(hostname -s | sed 's/\.local$//')
            
            # Count connected peers (exclude offline entries, exclude self)
            local peer_count=$(echo "$tailscale_output" | grep -v "offline" | grep -v "$current_hostname" | wc -l | tr -d ' ')
            
            # Check if THIS node offers exit node by looking for our hostname in the status
            local offers_exit_node="false"
            if echo "$tailscale_output" | grep "$current_hostname" | grep -q "offers exit node"; then
                offers_exit_node="true"
            fi
            
            # Get DERP info from JSON status
            local derp_region="Unknown"
            local tailscale_json=$(tailscale status --json 2>/dev/null)
            if [[ -n "$tailscale_json" ]]; then
                derp_region=$(echo "$tailscale_json" | jq -r '.Self.Relay // "Unknown"' 2>/dev/null || echo "Unknown")
            fi
            
            send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "on" \
                "{\"friendly_name\": \"${HOST_TAG} Tailscale Connectivity\", \"device_class\": \"connectivity\", \"state\": \"running\", \"derp_server\": \"$derp_region\", \"connected_peers\": $peer_count}"
            
            log "Tailscale: running (DERP: $derp_region, Peers: $peer_count)"
            
            # Check exit node status for THIS node only
            if [[ "$offers_exit_node" == "true" ]]; then
                send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "on" \
                    "{\"friendly_name\": \"${HOST_TAG} Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
                log "Tailscale Exit Node: Active ($current_hostname offers exit node)"
            else
                send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "off" \
                    "{\"friendly_name\": \"${HOST_TAG} Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
                log "Tailscale Exit Node: Inactive ($current_hostname does not offer exit node)"
            fi
            
            # Check for updates via Homebrew
            check_tailscale_updates
            
        else
            # Tailscale CLI failed or returned empty
            send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
                "{\"friendly_name\": \"${HOST_TAG} Tailscale Connectivity\", \"device_class\": \"connectivity\", \"state\": \"stopped\", \"derp_server\": \"Unknown\", \"connected_peers\": 0}"
            send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "off" \
                "{\"friendly_name\": \"${HOST_TAG} Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
            log "Tailscale: CLI error or not running (exit code: $tailscale_exit_code)"
        fi
    else
        # Tailscale CLI not found
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
            "{\"friendly_name\": \"${HOST_TAG} Tailscale Connectivity\", \"device_class\": \"connectivity\", \"state\": \"stopped\", \"derp_server\": \"Unknown\", \"connected_peers\": 0}"
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "off" \
            "{\"friendly_name\": \"${HOST_TAG} Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
        log "Tailscale: CLI not found in PATH"
    fi
}

check_tailscale_updates() {
    # Get update info from tailscale status output
    if command -v tailscale >/dev/null 2>&1; then
        local tailscale_status=$(tailscale status 2>/dev/null)
        
        # Look for update information in the health check section
        local update_line=$(echo "$tailscale_status" | grep "An update from version")
        
        if [[ -n "$update_line" ]]; then
            # Parse: "An update from version 1.90.2 to 1.90.9 is available"
            local current_version=$(echo "$update_line" | sed 's/.*from version \([0-9.]*\) to.*/\1/')
            local latest_version=$(echo "$update_line" | sed 's/.*to \([0-9.]*\) is available.*/\1/')
            
            send_to_ha "update.${HOST_TAG}_tailscale" "on" \
                "{\"friendly_name\": \"${HOST_TAG} Tailscale Update\", \"installed_version\": \"$current_version\", \"latest_version\": \"$latest_version\"}"
            log "Tailscale update available: $current_version -> $latest_version"
        else
            # No update available, get current version from tailscale version command
            local current_version=$(tailscale version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
            
            send_to_ha "update.${HOST_TAG}_tailscale" "off" \
                "{\"friendly_name\": \"${HOST_TAG} Tailscale Update\", \"installed_version\": \"$current_version\"}"
            log "Tailscale is up to date: $current_version"
        fi
    else
        send_to_ha "update.${HOST_TAG}_tailscale" "off" \
            "{\"friendly_name\": \"${HOST_TAG} Tailscale Update\", \"installed_version\": \"unknown\", \"note\": \"Tailscale CLI not found\"}"
        log "Tailscale CLI not found, cannot check for updates"
    fi
}

# Monitor StrongSwan
check_strongswan() {
    log "Checking StrongSwan connectivity..."
    
    # Check if StrongSwan is running
    if pgrep -f charon >/dev/null 2>&1; then
        # Count connected clients using both swanctl and ipsec status
        local connected_clients=0
        
        if command -v swanctl >/dev/null 2>&1; then
            connected_clients=$(swanctl --list-sas 2>/dev/null | grep -c "ESTABLISHED" || echo 0)
        elif command -v ipsec >/dev/null 2>&1; then
            connected_clients=$(ipsec status 2>/dev/null | grep -c "ESTABLISHED" || echo 0)
        fi
        
        send_to_ha "binary_sensor.${HOST_TAG}_strongswan_connectivity" "on" \
            "{\"friendly_name\": \"${HOST_TAG} StrongSwan Connectivity\", \"device_class\": \"connectivity\", \"connected_clients\": $connected_clients}"
        
        send_to_ha "sensor.${HOST_TAG}_strongswan_connected_clients" "$connected_clients" \
            "{\"friendly_name\": \"${HOST_TAG} StrongSwan Connected Clients\", \"unit_of_measurement\": \"clients\"}"
        
        log "StrongSwan: UP ($connected_clients clients connected)"
        
        # Check for updates
        check_strongswan_updates
    else
        send_to_ha "binary_sensor.${HOST_TAG}_strongswan_connectivity" "off" \
            "{\"friendly_name\": \"${HOST_TAG} StrongSwan Connectivity\", \"device_class\": \"connectivity\", \"connected_clients\": 0}"
        send_to_ha "sensor.${HOST_TAG}_strongswan_connected_clients" "unavailable" \
            "{\"friendly_name\": \"${HOST_TAG} StrongSwan Connected Clients\", \"unit_of_measurement\": \"clients\"}"
        
        log "StrongSwan: DOWN (Process not running)"
    fi
}

check_strongswan_updates() {
    # Check if there's a newer version available via Homebrew (if installed via brew)
    if command -v brew >/dev/null 2>&1; then
        local current_version=$(brew list --versions strongswan 2>/dev/null | awk '{print $2}' || echo "unknown")
        local latest_info=$(brew outdated strongswan 2>/dev/null)
        
        if [[ -n "$latest_info" ]]; then
            local latest_version=$(echo "$latest_info" | awk '{print $3}')
            send_to_ha "update.${HOST_TAG}_strongswan" "on" \
                "{\"friendly_name\": \"${HOST_TAG} StrongSwan Update\", \"installed_version\": \"$current_version\", \"latest_version\": \"$latest_version\"}"
        else
            send_to_ha "update.${HOST_TAG}_strongswan" "off" \
                "{\"friendly_name\": \"${HOST_TAG} StrongSwan Update\", \"installed_version\": \"$current_version\"}"
        fi
    fi
}

# Main execution
main() {
    log "Starting tunnel monitor check..."
    
    check_site_magic
    check_tailscale
    check_strongswan
    
    log "Tunnel monitor check completed"
}

# Run main function
main "$@"