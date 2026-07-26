#!/bin/bash
# Opinionated fresh-server setup for the Privacy Stack.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Run this command with sudo:${NC}"
  echo "  sudo bash setup-server.sh"
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  echo -e "${RED}Could not identify this server's operating system.${NC}"
  exit 1
fi

. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || { [ "${VERSION_ID:-}" != "22.04" ] && [ "${VERSION_ID:-}" != "24.04" ]; }; then
  echo -e "${RED}This setup requires Ubuntu 22.04 or Ubuntu 24.04.${NC}"
  echo "Current system: ${PRETTY_NAME:-unknown}"
  exit 1
fi

AVAILABLE_MEMORY_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "${AVAILABLE_MEMORY_KB:-0}" -lt 7000000 ]; then
  echo -e "${RED}This setup requires at least 8 GB RAM.${NC}"
  echo "On AWS, choose m7i-flex.large or t3.large."
  exit 1
fi

AVAILABLE_DISK_KB=$(df -Pk "$ROOT_DIR" | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_DISK_KB:-0}" -lt 40000000 ]; then
  echo -e "${RED}This setup requires at least 40 GB of free disk space.${NC}"
  echo "Use a 60 GB or larger server disk."
  exit 1
fi

if [ -f .env ]; then
  echo -e "${RED}An existing Privacy Stack configuration was found.${NC}"
  echo "This command is only for a fresh server and will not overwrite it."
  exit 1
fi

. configs/opinionated.env
export COMPOSE_PROFILES="$PRIVACY_STACK_PROFILES"

echo ""
echo "Privacy Stack — Fresh Server Setup"
echo "=================================="
echo ""
echo "This installs:"
echo "  Photos      Immich"
echo "  Documents   Paperless-ngx"
echo "  Media       Jellyfin"
echo "  DNS         AdGuard Home"
echo "  Passwords   Vaultwarden"
echo "  Monitoring  Uptime Kuma"
echo "  Dashboard   Homepage"
echo "  Proxy       Nginx Proxy Manager"
echo "  VPN         Tailscale"
echo ""

bash scripts/setup.sh

echo ""
echo "Connecting this server to Tailscale..."
TAILSCALE_IP=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TAILSCALE_IP" ]; then
  docker exec -it tailscale tailscale up --accept-dns=false </dev/tty >/dev/tty 2>&1
  TAILSCALE_IP=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1 || true)
else
  docker exec tailscale tailscale set --accept-dns=false
fi

if [ -z "$TAILSCALE_IP" ]; then
  echo -e "${RED}Tailscale did not provide a VPN address. Public access has not been disabled.${NC}"
  exit 1
fi

PUBLIC_IP=$(awk -F= '$1 == "SERVER_IP" {print $2}' .env)
sed -i \
  -e "s|^SERVER_IP=.*|SERVER_IP=$TAILSCALE_IP|" \
  -e "s|^PAPERLESS_URL=.*|PAPERLESS_URL=http://$TAILSCALE_IP:8000|" \
  -e "s|^JELLYFIN_URL=.*|JELLYFIN_URL=http://$TAILSCALE_IP:8096|" \
  -e "s|^VAULTWARDEN_URL=.*|VAULTWARDEN_URL=http://$TAILSCALE_IP:8080|" \
  .env

if [ -n "$PUBLIC_IP" ] && [ -f credentials.txt ]; then
  sed -i "s|$PUBLIC_IP|$TAILSCALE_IP|g" credentials.txt
fi

bash scripts/generate-homepage.sh
docker compose up -d

echo ""
echo "Configure AdGuard before the final health check:"
echo "  1. Open http://$TAILSCALE_IP:3000 on a device connected to Tailscale."
echo "  2. Keep the admin interface on port 3000."
echo "  3. Configure DNS on port 53."
echo "  4. Return here and type ADGUARD."
echo ""
read -r -p "Type ADGUARD after its setup wizard is complete: " ADGUARD_CONFIRMATION </dev/tty
if [ "$ADGUARD_CONFIRMATION" != "ADGUARD" ]; then
  echo -e "${RED}AdGuard setup was not confirmed; public access has not been disabled.${NC}"
  exit 1
fi

bash scripts/test.sh

echo ""
echo "Tailscale address: $TAILSCALE_IP"
echo ""
echo "Before public access is disabled:"
echo "  1. Open a second terminal."
echo "  2. Confirm this works: ssh $(logname 2>/dev/null || echo ubuntu)@$TAILSCALE_IP"
echo "  3. Return here and type LOCKDOWN."
echo ""
read -r -p "Type LOCKDOWN after VPN SSH works: " CONFIRMATION </dev/tty
if [ "$CONFIRMATION" != "LOCKDOWN" ]; then
  echo -e "${RED}Lockdown cancelled. Public SSH remains available.${NC}"
  echo "Run this after confirming VPN access: sudo bash scripts/lockdown-vpn.sh"
  exit 1
fi

bash scripts/lockdown-vpn.sh

echo ""
echo -e "${GREEN}Opinionated Privacy Stack installation completed.${NC}"
echo "Use the Tailscale IP for SSH and application access: $TAILSCALE_IP"
