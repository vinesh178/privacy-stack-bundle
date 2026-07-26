#!/bin/bash
# Opinionated fresh-server setup for the Privacy Stack.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"
. scripts/lib/platform.sh

RESUME=0
case "${1:-}" in
  "") ;;
  --resume) RESUME=1 ;;
  *)
    echo "Usage: sudo bash setup-server.sh [--resume]"
    exit 1
    ;;
esac

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Run this command with sudo:${NC}"
  echo "  sudo bash setup-server.sh"
  exit 1
fi

if ! platform_preflight; then
  echo -e "${RED}This server does not provide the required Linux capabilities.${NC}"
  exit 1
fi

platform_install_prerequisites

AVAILABLE_MEMORY_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "${AVAILABLE_MEMORY_KB:-0}" -lt 7000000 ]; then
  echo -e "${RED}This setup requires at least 8 GB RAM.${NC}"
  echo "On AWS, choose any available x86 general-purpose instance with at least 8 GiB memory."
  exit 1
fi

AVAILABLE_DISK_KB=$(df -Pk "$ROOT_DIR" | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_DISK_KB:-0}" -lt 40000000 ]; then
  echo -e "${RED}This setup requires at least 40 GB of free disk space.${NC}"
  echo "Use a 60 GB or larger server disk."
  exit 1
fi

if [ -f .env ] && [ "$RESUME" -ne 1 ]; then
  echo -e "${RED}An existing Privacy Stack configuration was found.${NC}"
  echo "This command is only for a fresh server and will not overwrite it."
  echo "To continue an interrupted setup: sudo bash setup-server.sh --resume"
  exit 1
fi

if [ "$RESUME" -eq 1 ] && [ ! -f .env ]; then
  echo -e "${RED}No existing Privacy Stack configuration was found to resume.${NC}"
  echo "Start a fresh installation with: sudo bash setup-server.sh"
  exit 1
fi

if [ "$RESUME" -eq 1 ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  echo ""
  echo "Resuming Privacy Stack setup..."
else
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

  DEFER_ACCESS_ONBOARDING=1 bash scripts/setup.sh
fi

resume_after_interrupt() {
  echo ""
  echo -e "${YELLOW}Setup interrupted. Public access has not been disabled.${NC}"
  echo "Continue without overwriting the stack:"
  echo "  sudo bash $ROOT_DIR/setup-server.sh --resume"
  exit 130
}

get_tailscale_ip() {
  docker exec tailscale tailscale ip -4 2>/dev/null | head -1 || true
}

trap resume_after_interrupt INT TERM

echo ""
echo "Connecting this server to Tailscale..."
TAILSCALE_IP=$(get_tailscale_ip)
if [ -z "$TAILSCALE_IP" ]; then
  echo "Open the login URL below and approve the privacy-stack device."
  if ! docker exec -it tailscale tailscale up --accept-dns=false </dev/tty >/dev/tty 2>&1; then
    echo -e "${YELLOW}The login command disconnected; waiting for browser approval...${NC}"
  fi
  for _ in $(seq 1 60); do
    TAILSCALE_IP=$(get_tailscale_ip)
    [ -n "$TAILSCALE_IP" ] && break
    sleep 5
  done
else
  docker exec tailscale tailscale set --accept-dns=false
fi

if [ -z "$TAILSCALE_IP" ]; then
  echo -e "${RED}Tailscale did not provide a VPN address. Public access has not been disabled.${NC}"
  echo "After approving the device, verify it with:"
  echo "  sudo docker exec tailscale tailscale ip -4"
  echo "Then continue safely with:"
  echo "  sudo bash setup-server.sh --resume"
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

trap - INT TERM
bash scripts/lockdown-vpn.sh

echo ""
echo -e "${GREEN}Opinionated Privacy Stack installation completed.${NC}"
echo "Use the Tailscale IP for SSH and application access: $TAILSCALE_IP"
