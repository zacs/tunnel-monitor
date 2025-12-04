# tunnel-monitor
Scripts to monitor Tailscale, StrongSwan IPsec VPN, and Unifi Site Magic connectivity from a Mac Mini tunnel server, reporting status to Home Assistant.

For a robust solution to tunneling into my home network (to both access resources on that network, and to appear as if I am on that network even when I'm not), I am leveraging a layered approach:

1. **Unifi Site Magic**: Seamless site-to-site connectivity between compatible Unifi routers
2. **Tailscale**: Mesh VPN with exit node capability for appearing to be at the remote site
3. **StrongSwan IPsec**: Traditional VPN server with native iOS/macOS support

This monitoring system runs on a Mac Mini i7 with 10GB NIC (`seattle-tunnel`) and reports connectivity status, performance metrics, and update availability to Home Assistant.

## Features

### Monitoring Capabilities
- **Site Magic Connectivity**: Binary sensor + latency monitoring to Tokyo UDM
- **Tailscale Status**: Connectivity status + exit node status + update availability
- **StrongSwan Status**: Service status + connected client count + update availability  
- **Automatic Updates**: Check for Tailscale and StrongSwan updates via Home Assistant update entities

### Home Assistant Entities Created
- `binary_sensor.{HOST_TAG}_site_magic_tokyo_udm_availability`
- `binary_sensor.{HOST_TAG}_tailscale_connectivity`
- `binary_sensor.{HOST_TAG}_strongswan_connectivity`
- `binary_sensor.{HOST_TAG}_tailscale_exit_node`
- `sensor.{HOST_TAG}_site_magic_tokyo_udm_latency_ms`
- `sensor.{HOST_TAG}_strongswan_connected_clients`
- `update.{HOST_TAG}_tailscale`
- `update.{HOST_TAG}_strongswan`

### Sensor Attributes

**Tailscale binary sensor includes:**
- `state`: "running", "stopped", or "needslogin"
- `derp_server`: DERP relay region being used
- `connected_peers`: Number of connected Tailscale peers

**StrongSwan binary sensor includes:**
- `connected_clients`: Number of established IPsec tunnels

**Site Magic binary sensor includes:**
- `latency_ms`: Average round-trip time in milliseconds

## Prerequisites

Before installation, ensure you have:
- macOS system with admin privileges
- [Homebrew](https://brew.sh) package manager
- [Tailscale](https://formulae.brew.sh/cask/tailscale) installed via Homebrew (`brew install --cask tailscale`)
- [StrongSwan](https://formulae.brew.sh/formula/strongswan) installed (`brew install strongswan`)
- [jq](https://formulae.brew.sh/formula/jq) for JSON parsing (`brew install jq`)
- Home Assistant with a [Long-lived Access Token](https://developers.home-assistant.io/docs/auth_api/#long-lived-access-token)

> **Note**: Installing Tailscale via Homebrew enables automatic update detection. If you've installed Tailscale via the official installer, update monitoring will be limited.

## Install

Installation is achieved by setting environment variables and running the install script:

```bash
REPO_URL=https://github.com/zacs/tunnel-monitor.git \
HA_URL=https://homeassistant.example.com:8123 \
HA_TOKEN=YOUR_LONG_LIVED_TOKEN \
HOST_TAG=seattle_tunnel \
TOKYO_UDM_IP=192.168.1.1 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zacs/tunnel-monitor/main/install_tunnel_monitor.sh)"
```

### Parameters
- `REPO_URL`: This repository URL
- `HA_URL`: Your Home Assistant URL (include port if not 80/443)
- `HA_TOKEN`: Long-lived access token from Home Assistant
- `HOST_TAG`: Identifier for this tunnel server (used in entity names)
- `TOKYO_UDM_IP`: IP address of your Tokyo UDM for Site Magic monitoring

### Example Installation
```bash
REPO_URL=https://github.com/zacs/tunnel-monitor.git \
HA_URL=http://192.168.2.19:8123 \
HA_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..." \
HOST_TAG=seattle_tunnel \
TOKYO_UDM_IP=192.168.82.1 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zacs/tunnel-monitor/main/install_tunnel_monitor.sh)"
```

The installer will:
1. Install dependencies (jq via Homebrew if needed)
2. Clone the repository to `/usr/local/tunnel-monitor`
3. Create configuration files
4. Install and start a LaunchDaemon that runs every 3 minutes
5. Perform an initial test run

## Configuration

After installation, configuration is stored in `/usr/local/tunnel-monitor/config.env`. You can modify settings there and restart the service:

```bash
sudo launchctl unload /Library/LaunchDaemons/com.tunnel-monitor.monitor.plist
sudo launchctl load /Library/LaunchDaemons/com.tunnel-monitor.monitor.plist
```

## Monitoring & Logs

- **Logs**: `/usr/local/tunnel-monitor/tunnel_monitor.log`
- **Status**: `sudo launchctl list | grep tunnel-monitor`
- **Manual Run**: `/usr/local/tunnel-monitor/tunnel_monitor.sh`

## Dashboard

Here's a sample Home Assistant dashboard configuration:

```yaml
type: vertical-stack
cards:
  - type: entities
    title: Seattle Tunnel • Updates
    entities:
      - entity: update.seattle_tunnel_tailscale
        name: Tailscale
      - entity: update.seattle_tunnel_strongswan
        name: strongSwan
  - type: entities
    title: VPN Services
    entities:
      - entity: binary_sensor.seattle_tunnel_tailscale_connectivity
        name: Tailscale Status
      - entity: binary_sensor.seattle_tunnel_tailscale_exit_node
        name: Tailscale Exit Node
      - entity: binary_sensor.seattle_tunnel_strongswan_connectivity
        name: StrongSwan Status
      - entity: sensor.seattle_tunnel_strongswan_connected_clients
        name: StrongSwan Clients
  - type: entities
    title: Site Magic (Seattle → Tokyo)
    entities:
      - entity: binary_sensor.seattle_tunnel_site_magic_tokyo_udm_availability
        name: Availability
      - entity: sensor.seattle_tunnel_site_magic_tokyo_udm_latency_ms
        name: Latency (ms)
  - type: conditional
    conditions:
      - entity: binary_sensor.seattle_tunnel_site_magic_tokyo_udm_availability
        state_not: "on"
    card:
      type: markdown
      content: |
        ❌ **Site Magic path appears DOWN** (Seattle → Tokyo).
        Check UDM/UXG tunnels, WANs, and routing.
  - type: conditional
    conditions:
      - entity: binary_sensor.seattle_tunnel_tailscale_connectivity
        state_not: "on"
    card:
      type: markdown
      content: |
        ❌ **Tailscale connectivity is DOWN**.
        SSH to seattle-tunnel and check `tailscale status`.
  - type: conditional
    conditions:
      - entity: binary_sensor.seattle_tunnel_strongswan_connectivity
        state_not: "on"
    card:
      type: markdown
      content: |
        ❌ **StrongSwan VPN is DOWN**.
        SSH to seattle-tunnel and check `sudo systemctl status strongswan`.
```

## Uninstall

To remove the tunnel monitor:

```bash
/usr/local/tunnel-monitor/uninstall.sh
```

## Troubleshooting

### Common Issues

1. **"jq: command not found"**
   ```bash
   brew install jq
   ```

2. **Tailscale not responding**
   - Ensure Tailscale is installed and running: `tailscale status`
   - Check if the daemon is running: `brew services list | grep tailscale`

3. **StrongSwan not detected**
   - Install via Homebrew: `brew install strongswan`
   - Check if charon daemon is running: `pgrep -f charon`

4. **Home Assistant connection fails**
   - Verify HA_URL is accessible from the Mac Mini
   - Check that the Long-lived Access Token is valid
   - Test manually: `curl -H "Authorization: Bearer $HA_TOKEN" $HA_URL/api/`

5. **Site Magic monitoring fails**
   - Verify the Tokyo UDM IP address is correct
   - Check routing between sites
   - Ensure ICMP (ping) is allowed through firewalls

### Manual Testing

Test individual components:
```bash
# Test Home Assistant connectivity
curl -H "Authorization: Bearer YOUR_TOKEN" https://homeassistant.example.com:8123/api/

# Test Tailscale
tailscale status

# Test StrongSwan
swanctl --list-sas

# Test Site Magic (replace with your Tokyo UDM IP)
ping -c 3 192.168.1.1
```