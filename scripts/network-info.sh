#!/bin/bash
# Print network access details without exposing credentials.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

has_profile() {
  [[ ",${COMPOSE_PROFILES:-}," == *",$1,"* ]]
}

TAILSCALE_IPV4=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1 || true)
TAILSCALE_IPV6=$(docker exec tailscale tailscale ip -6 2>/dev/null | head -1 || true)
SSH_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -z "$SSH_USER" ] || [ "$SSH_USER" = "root" ]; then
  SSH_USER="<server-user>"
fi

if [ -z "$TAILSCALE_IPV4" ]; then
  echo "Tailscale is not connected. Run:"
  echo "  sudo docker exec -it tailscale tailscale up --accept-dns=false"
  exit 1
fi

echo "Privacy Stack network details"
echo "============================="
echo ""
echo "Server Tailscale addresses:"
echo "  IPv4: $TAILSCALE_IPV4"
[ -n "$TAILSCALE_IPV6" ] && echo "  IPv6: $TAILSCALE_IPV6"
echo ""
echo "SSH:"
echo "  ssh $SSH_USER@$TAILSCALE_IPV4"
echo "  ssh -i /path/to/private-key.pem $SSH_USER@$TAILSCALE_IPV4"
echo ""
echo "Application URLs:"
echo "  Proxy Manager: http://$TAILSCALE_IPV4:81"
has_profile "docs"       && echo "  Paperless:     http://$TAILSCALE_IPV4:8000"
has_profile "media"      && echo "  Jellyfin:      http://$TAILSCALE_IPV4:8096"
has_profile "dns"        && echo "  AdGuard:       http://$TAILSCALE_IPV4:3003"
has_profile "passwords"  && echo "  Vaultwarden:   http://$TAILSCALE_IPV4:8080"
has_profile "monitoring" && echo "  Uptime Kuma:   http://$TAILSCALE_IPV4:3001"
has_profile "dashboard"  && echo "  Homepage:      http://$TAILSCALE_IPV4:3002"
echo ""

if has_profile "dns"; then
  echo "DNS:"
  echo "  Manual device DNS:       $TAILSCALE_IPV4"
  echo "  Tailscale global server: $TAILSCALE_IPV4"
  echo "  Test: dig @$TAILSCALE_IPV4 google.com"
  echo ""
fi

echo "Nginx Proxy Manager targets:"
has_profile "docs"       && echo "  Paperless:   paperless:8000"
has_profile "media"      && echo "  Jellyfin:    jellyfin:8096"
has_profile "dns"        && echo "  AdGuard:     adguard:80"
has_profile "passwords"  && echo "  Vaultwarden: vaultwarden:80"
has_profile "monitoring" && echo "  Uptime Kuma: uptime_kuma:3001"
has_profile "dashboard"  && echo "  Homepage:    homepage:3000"
echo ""

if has_profile "monitoring"; then
  echo "Uptime Kuma HTTP(s) monitor URLs:"
  has_profile "docs"       && echo "  Paperless:     http://paperless:8000"
  has_profile "media"      && echo "  Jellyfin:      http://jellyfin:8096"
  has_profile "passwords"  && echo "  Vaultwarden:   http://vaultwarden:80"
  has_profile "dashboard"  && echo "  Homepage:      http://homepage:3000"
  echo "  Proxy Manager: http://nginx-proxy-manager:81"
  has_profile "dns"        && echo "  AdGuard:       http://adguard:80"
  echo ""
fi

echo "Tailnet devices:"
docker exec tailscale tailscale status 2>/dev/null || true
