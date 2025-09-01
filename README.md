# tunnel-monitor
Scripts to monitor/update Tailscale and IPsec, monitor Unifi Site Magic, and do so via Home Assistant. 

For a robust solution to tunneling into my home network (to both access resources on that network, and to appear as if I am on that network even when I'm not), I am leveraging a layered approach:

1. Unifi Site Magic (both sites have compatible Unifi routers): This is for seemlessly accessing self-hosted services at one site from the other site.
2. Tailscale: Used optionally to make it appear as if I am at the other site to the broader internet. Helpful to avoid web pages assuming a language, and to use some paid services only available in one site's country.
3. StrongSwan IPsec: VPN that is supported as a system VPN in iOS and MacOS for ease of use.

This set of scripts monitors the above services, and reports to Home Assistant (installed at one of the sites). 

## Install

Installation is achieve via a common remote curl command, but with a couple env vars needed:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zacs/tunnel-monitor/main/install_tunnel_monitor.sh)" -- \
  REPO_URL=https://github.com/zacs/tunnel-monitor.git \
  HA_URL=https://homeassistant.example.com:8123 \
  HA_TOKEN=YOUR_LONG_LIVED_TOKEN \
  HOST_TAG=YOUR_TUNNEL_MACHINES_NAME
```

The `HOST_TAG` is just to name the entities in Home Assistant and doesn't actually impact the functionality. 

## Dashboard

I generally use the HA sensors in my own automations, but if you like pretty dashboards:

```
type: vertical-stack
cards:
  - type: entities
    title: Mac mini • Updates
    entities:
      - entity: update.macmini_seattle_tailscale
        name: Tailscale
      - entity: update.macmini_seattle_strongswan
        name: strongSwan
  - type: entities
    title: Site Magic (Seattle → Tokyo)
    entities:
      - entity: sensor.macmini_seattle_site_magic_tokyo_udm_availability
        name: Availability
      - entity: sensor.macmini_seattle_site_magic_tokyo_udm_latency_ms
        name: Latency (ms)
  - type: conditional
    conditions:
      - entity: sensor.macmini_seattle_site_magic_tokyo_udm_availability
        state_not: up
    card:
      type: markdown
      content: |
        ❌ **Site Magic path appears DOWN** (Seattle → Tokyo).
        Check UDM/UXG tunnels, WANs, and routing.
```

> Make sure to change the titles and entity names. I'm using a Mac Mini to tunnel from Tokyo to Seattle, hence the example. 
