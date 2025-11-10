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
    local start_time=$(date +%s%3N)
    
    if ping -c 1 -W 3000 "$tokyo_udm_ip" >/dev/null 2>&1; then
        local end_time=$(date +%s%3N)
        local latency=$((end_time - start_time))
        
        send_to_ha "binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability" "on" \
            "{\"friendly_name\": \"Site Magic Tokyo UDM\", \"device_class\": \"connectivity\"}"
        send_to_ha "sensor.${HOST_TAG}_site_magic_tokyo_udm_latency_ms" "$latency" \
            "{\"friendly_name\": \"Site Magic Latency\", \"unit_of_measurement\": \"ms\"}"
        
        log "Site Magic: UP (${latency}ms)"
    else
        send_to_ha "binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability" "off" \
            "{\"friendly_name\": \"Site Magic Tokyo UDM\", \"device_class\": \"connectivity\"}"
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
            
            if [[ "$backend_state" == "Running" ]]; then
                send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "on" \
                    "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\"}"
                log "Tailscale: UP"
            else
                send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
                    "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\"}"
                log "Tailscale: DOWN (State: $backend_state)"
            fi
            
            # Check for updates
            check_tailscale_updates
        else
            send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
                "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\"}"
            log "Tailscale: Cannot get status"
        fi
    else
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_connectivity" "off" \
            "{\"friendly_name\": \"Tailscale Connectivity\", \"device_class\": \"connectivity\"}"
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
        send_to_ha "binary_sensor.${HOST_TAG}_strongswan_connectivity" "on" \
            "{\"friendly_name\": \"StrongSwan Connectivity\", \"device_class\": \"connectivity\"}"
        
        # Count connected clients
        local connected_clients=0
        if command -v swanctl >/dev/null 2>&1; then
            connected_clients=$(swanctl --list-sas 2>/dev/null | grep -c "ESTABLISHED" || echo 0)
        fi
        
        send_to_ha "sensor.${HOST_TAG}_strongswan_connected_clients" "$connected_clients" \
            "{\"friendly_name\": \"StrongSwan Connected Clients\", \"unit_of_measurement\": \"clients\"}"
        
        log "StrongSwan: UP ($connected_clients clients connected)"
        
        # Check for updates
        check_strongswan_updates
    else
        send_to_ha "binary_sensor.${HOST_TAG}_strongswan_connectivity" "off" \
            "{\"friendly_name\": \"StrongSwan Connectivity\", \"device_class\": \"connectivity\"}"
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
    log "Checking network performance..."
    
    # Check internet connectivity through Tailscale exit node
    if tailscale status --json 2>/dev/null | jq -r '.ExitNodeStatus.Online' 2>/dev/null | grep -q true; then
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "on" \
            "{\"friendly_name\": \"Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
    else
        send_to_ha "binary_sensor.${HOST_TAG}_tailscale_exit_node" "off" \
            "{\"friendly_name\": \"Tailscale Exit Node\", \"device_class\": \"connectivity\"}"
    fi
    
    # Check system resources
    local cpu_usage=$(top -l 1 | grep "CPU usage" | awk '{print $3}' | sed 's/%//')
    local memory_usage=$(vm_stat | grep "Pages active" | awk '{print $3}' | sed 's/\.//')
    
    send_to_ha "sensor.${HOST_TAG}_cpu_usage" "$cpu_usage" \
        "{\"friendly_name\": \"CPU Usage\", \"unit_of_measurement\": \"%\"}"
    
    # Network interface stats for 10GB NIC
    local interface=$(route get default | grep interface | awk '{print $2}')
    if [[ -n "$interface" ]]; then
        local rx_bytes=$(netstat -ibn | grep "$interface" | awk '{sum+=$7} END {print sum/1024/1024}')
        local tx_bytes=$(netstat -ibn | grep "$interface" | awk '{sum+=$10} END {print sum/1024/1024}')
        
        send_to_ha "sensor.${HOST_TAG}_network_rx_mb" "${rx_bytes:-0}" \
            "{\"friendly_name\": \"Network RX\", \"unit_of_measurement\": \"MB\"}"
        send_to_ha "sensor.${HOST_TAG}_network_tx_mb" "${tx_bytes:-0}" \
            "{\"friendly_name\": \"Network TX\", \"unit_of_measurement\": \"MB\"}"
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