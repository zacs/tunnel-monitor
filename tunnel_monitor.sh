#!/bin/bash
# tunnel_monitor.sh - Monitor VPN services and report to Home Assistant
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
    
    # Try to reach the Tokyo UDM (adjust IP as needed)
    local tokyo_udm_ip="${TOKYO_UDM_IP:-192.168.1.1}"
    
    # Perform multiple pings to get average latency
    local ping_output=$(ping -c 3 -W 3000 "$tokyo_udm_ip" 2>/dev/null)
    local ping_success=$?
    
    if [[ $ping_success -eq 0 ]]; then
        # Extract average latency from ping output
        local avg_latency=$(echo "$ping_output" | grep "round-trip" | awk -F'/' '{print $5}' | cut -d'.' -f1)
        
        # If we can't parse the average, try to get it from individual pings
        if [[ -z "$avg_latency" || "$avg_latency" == "" ]]; then
            local latencies=$(echo "$ping_output" | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/')
            if [[ -n "$latencies" ]]; then
                avg_latency=$(echo "$latencies" | awk '{sum+=$1; n++} END {if(n>0) printf "%.0f", sum/n; else print "0"}')
            else
                avg_latency=0
            fi
        fi
        
        send_to_ha "binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability" "on" \
            "{\"friendly_name\": \"Site Magic Tokyo UDM\", \"device_class\": \"connectivity\", \"latency_ms\": $avg_latency}"
        send_to_ha "sensor.${HOST_TAG}_site_magic_tokyo_udm_latency_ms" "$avg_latency" \
            "{\"friendly_name\": \"Site Magic Latency\", \"unit_of_measurement\": \"ms\"}"
        
        log "Site Magic: UP (${avg_latency}ms avg)"
    else
        send_to_ha "binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability" "off" \
            "{\"friendly_name\": \"Site Magic Tokyo UDM\", \"device_class\": \"connectivity\", \"latency_ms\": null}"
        send_to_ha "sensor.${HOST_TAG}_site_magic_tokyo_udm_latency_ms" "unavailable" \
            "{\"friendly_name\": \"Site Magic Latency\", \"unit_of_measurement\": \"ms\"}"
        
        log "Site Magic: DOWN"
    fi
}

# Monitor Tailscale
check_tailscale() {
    log "Checking Tailscale connectivity..."
    
    # Check if Tailscale is running
    if pgrep -f tailscaled >/dev/null 2>&1; then
        # Check Tailscale status
        local tailscale_status=$(tailscale status --json 2>/dev/null)
        
        if [[ -n "$tailscale_status" ]]; then
            local backend_state=$(echo "$tailscale_status" | jq -r '.BackendState // "Unknown"')
            local derp_server=$(echo "$tailscale_status" | jq -r '.CurrentTailnet.MagicDNSSuffix // "Unknown"')
            local peer_count=$(echo "$tailscale_status" | jq '.Peer | length' 2>/dev/null || echo 0)
            
            # Get DERP region info
            local derp_region=$(echo "$tailscale_status" | jq -r '.Self.Relay // "Unknown"')
            
            # Determine state
            local state="stopped"
            local connectivity_state="off"
            if [[ "$backend_state" == "Running" ]]; then
                state="running"
                connectivity_state="on"
            elif [[ "$backend_state" == "NeedsLogin" ]]; then
                state="needslogin"
                connectivity_state="off"
            fi
            
            send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "$connectivity_state" \
                "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\", \"state\": \"$state\", \"derp_server\": \"$derp_region\", \"connected_peers\": $peer_count}"
            
            log "Tailscale: $state (DERP: $derp_region, Peers: $peer_count)"
            
            # Check for updates
            check_tailscale_updates
        else
            send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
                "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\", \"state\": \"stopped\", \"derp_server\": \"Unknown\", \"connected_peers\": 0}"
            log "Tailscale: Cannot get status"
        fi
    else
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
            "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\", \"state\": \"stopped\", \"derp_server\": \"Unknown\", \"connected_peers\": 0}"
        log "Tailscale: Process not running"
    fi
}

check_tailscale_updates() {
    # Update brew catalog first to get latest version info
    log "Updating Homebrew catalog..."
    brew update >/dev/null 2>&1
    
    # Check if Tailscale is installed via Homebrew
    if command -v brew >/dev/null 2>&1 && brew list tailscale >/dev/null 2>&1; then
        local current_version=$(brew list --versions tailscale 2>/dev/null | awk '{print $2}' || echo "unknown")
        local latest_info=$(brew outdated tailscale 2>/dev/null)
        
        if [[ -n "$latest_info" ]]; then
            local latest_version=$(echo "$latest_info" | awk '{print $3}')
            send_to_ha "update.${HOST_TAG}_tailscale" "on" \
                "{\"friendly_name\": \"Tailscale Update\", \"installed_version\": \"$current_version\", \"latest_version\": \"$latest_version\"}"
            log "Tailscale update available: $current_version -> $latest_version"
        else
            send_to_ha "update.${HOST_TAG}_tailscale" "off" \
                "{\"friendly_name\": \"Tailscale Update\", \"installed_version\": \"$current_version\"}"
            log "Tailscale is up to date: $current_version"
        fi
    else
        # Fallback for non-Homebrew installations
        local current_version=$(tailscale version | head -n1 | awk '{print $1}' 2>/dev/null || echo "unknown")
        send_to_ha "update.${HOST_TAG}_tailscale" "off" \
            "{\"friendly_name\": \"Tailscale Update\", \"installed_version\": \"$current_version\", \"note\": \"Not installed via Homebrew\"}"
        log "Tailscale not installed via Homebrew, cannot check for updates automatically"
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
            "{\"friendly_name\": \"StrongSwan Connectivity\", \"device_class\": \"connectivity\", \"connected_clients\": $connected_clients}"
        
        send_to_ha "sensor.${HOST_TAG}_strongswan_connected_clients" "$connected_clients" \
            "{\"friendly_name\": \"StrongSwan Connected Clients\", \"unit_of_measurement\": \"clients\"}"
        
        log "StrongSwan: UP ($connected_clients clients connected)"
        
        # Check for updates
        check_strongswan_updates
    else
        send_to_ha "binary_sensor.${HOST_TAG}_strongswan_connectivity" "off" \
            "{\"friendly_name\": \"StrongSwan Connectivity\", \"device_class\": \"connectivity\", \"connected_clients\": 0}"
        send_to_ha "sensor.${HOST_TAG}_strongswan_connected_clients" "unavailable" \
            "{\"friendly_name\": \"StrongSwan Connected Clients\", \"unit_of_measurement\": \"clients\"}"
        
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
                "{\"friendly_name\": \"StrongSwan Update\", \"installed_version\": \"$current_version\", \"latest_version\": \"$latest_version\"}"
        else
            send_to_ha "update.${HOST_TAG}_strongswan" "off" \
                "{\"friendly_name\": \"StrongSwan Update\", \"installed_version\": \"$current_version\"}"
        fi
    fi
}

# Additional useful monitoring
check_network_performance() {
    log "Checking Tailscale exit node status..."
    
    # Check internet connectivity through Tailscale exit node
    if tailscale status --json 2>/dev/null | jq -r '.ExitNodeStatus.Online' 2>/dev/null | grep -q true; then
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "on" \
            "{\"friendly_name\": \"Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
        log "Tailscale Exit Node: Active"
    else
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "off" \
            "{\"friendly_name\": \"Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
        log "Tailscale Exit Node: Inactive"
    fi
}

# Main execution
main() {
    log "Starting tunnel monitor check..."
    
    check_site_magic
    check_tailscale
    check_strongswan
    check_network_performance
    
    log "Tunnel monitor check completed"
}

# Run main function
main "$@"