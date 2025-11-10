#!/bin/bash

# install_tunnel_monitor.sh - Install tunnel monitoring system
set -e

# Default values
REPO_URL="${REPO_URL:-https://github.com/zacs/tunnel-monitor.git}"
INSTALL_DIR="/usr/local/tunnel-monitor"
SERVICE_NAME="com.tunnel-monitor.monitor"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root"
fi

# Check required parameters
if [[ -z "$HA_URL" || -z "$HA_TOKEN" || -z "$HOST_TAG" ]]; then
    error "Missing required environment variables. Usage:
    bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/zacs/tunnel-monitor/main/install_tunnel_monitor.sh)\" -- \\
      REPO_URL=https://github.com/zacs/tunnel-monitor.git \\
      HA_URL=https://homeassistant.example.com:8123 \\
      HA_TOKEN=YOUR_LONG_LIVED_TOKEN \\
      HOST_TAG=seattle_tunnel \\
      TOKYO_UDM_IP=192.168.1.1"
fi

log "Installing Tunnel Monitor..."
log "Target directory: $INSTALL_DIR"
log "Home Assistant URL: $HA_URL"
log "Host tag: $HOST_TAG"

# Check dependencies
log "Checking dependencies..."
command -v git >/dev/null 2>&1 || error "Git is required but not installed"
command -v curl >/dev/null 2>&1 || error "Curl is required but not installed"
command -v jq >/dev/null 2>&1 || {
    warn "jq not found, attempting to install via Homebrew..."
    if command -v brew >/dev/null 2>&1; then
        brew install jq
    else
        error "jq is required but not installed. Please install jq first: brew install jq"
    fi
}

# Check if Tailscale is installed
command -v tailscale >/dev/null 2>&1 || warn "Tailscale not found. Install from: https://tailscale.com/download/mac"

# Check if StrongSwan is installed
if ! pgrep -f charon >/dev/null 2>&1 && ! command -v swanctl >/dev/null 2>&1; then
    warn "StrongSwan not found. Install via: brew install strongswan"
fi

# Create installation directory
log "Creating installation directory..."
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(whoami):$(id -gn)" "$INSTALL_DIR"

# Clone or update repository
if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Updating existing installation..."
    cd "$INSTALL_DIR"
    git pull origin main
else
    log "Cloning repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Create configuration file
log "Creating configuration file..."
cat > "$INSTALL_DIR/config.env" <<EOF
# Tunnel Monitor Configuration
HA_URL="$HA_URL"
HA_TOKEN="$HA_TOKEN"
HOST_TAG="$HOST_TAG"
TOKYO_UDM_IP="${TOKYO_UDM_IP:-192.168.1.1}"
EOF

# Make scripts executable
chmod +x "$INSTALL_DIR/tunnel_monitor.sh"

# Create LaunchDaemon plist
log "Creating LaunchDaemon..."
sudo tee "/Library/LaunchDaemons/$SERVICE_NAME.plist" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SERVICE_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/tunnel_monitor.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>180</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/tunnel_monitor.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/tunnel_monitor.log</string>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

# Load and start the service
log "Loading and starting the service..."
sudo launchctl unload "/Library/LaunchDaemons/$SERVICE_NAME.plist" 2>/dev/null || true
sudo launchctl load "/Library/LaunchDaemons/$SERVICE_NAME.plist"

# Test the configuration
log "Testing configuration..."
if "$INSTALL_DIR/tunnel_monitor.sh"; then
    log "Initial test run completed successfully!"
else
    warn "Initial test run failed. Check the logs at $INSTALL_DIR/tunnel_monitor.log"
fi

# Create uninstall script
cat > "$INSTALL_DIR/uninstall.sh" <<EOF
#!/bin/bash
echo "Uninstalling Tunnel Monitor..."
sudo launchctl unload "/Library/LaunchDaemons/$SERVICE_NAME.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$SERVICE_NAME.plist"
sudo rm -rf "$INSTALL_DIR"
echo "Tunnel Monitor uninstalled successfully!"
EOF
chmod +x "$INSTALL_DIR/uninstall.sh"

log "Installation completed successfully!"
log ""
log "Service will run every 3 minutes and report to Home Assistant."
log "Logs are available at: $INSTALL_DIR/tunnel_monitor.log"
log "To uninstall, run: $INSTALL_DIR/uninstall.sh"
log ""
log "You may want to configure your Home Assistant dashboard with the entities:"
echo "  - binary_sensor.${HOST_TAG}_site_magic_tokyo_udm_availability"
echo "  - binary_sensor.${HOST_TAG}_tailscale_connectivity"
echo "  - binary_sensor.${HOST_TAG}_strongswan_connectivity"
echo "  - binary_sensor.${HOST_TAG}_tailscale_exit_node"
echo "  - sensor.${HOST_TAG}_site_magic_tokyo_udm_latency_ms"
echo "  - sensor.${HOST_TAG}_strongswan_connected_clients"
echo "  - update.${HOST_TAG}_tailscale"
echo "  - update.${HOST_TAG}_strongswan"