#!/bin/bash
# ============================================================
# Privacy Stack — Generate Homepage Config
# Reads .env and generates configs/homepage/services.yaml
# with only enabled services and correct URLs
# ============================================================

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source .env
if [ -f "${INSTALL_DIR}/.env" ]; then
  set -a
  source "${INSTALL_DIR}/.env"
  set +a
fi

DOMAIN="${DOMAIN:-}"
SERVER_IP="${SERVER_IP:-localhost}"
PROFILES="${COMPOSE_PROFILES:-docs,media,dns,monitoring,dashboard,vpn}"

# Build URL for a service
make_url() {
  local subdomain=$1
  local port=$2
  if [ -n "$DOMAIN" ]; then
    echo "https://${subdomain}.${DOMAIN}"
  else
    echo "http://${SERVER_IP}:${port}"
  fi
}

has_profile() {
  [[ ",$PROFILES," == *",$1,"* ]]
}

CONFIG_DIR="${INSTALL_DIR}/configs/homepage"
mkdir -p "$CONFIG_DIR"

# Build services.yaml
{
  echo "---"
  echo "- My Stack:"

  if has_profile "docs"; then
    cat << YAML
    - Documents:
        icon: paperless-ngx.png
        href: $(make_url docs 8000)
        description: Document management + OCR
YAML
  fi

  if has_profile "media"; then
    cat << YAML
    - Media:
        icon: jellyfin.png
        href: $(make_url media 8096)
        description: Media server
        widget:
          type: jellyfin
          url: http://jellyfin:8096
YAML
  fi

  if has_profile "passwords"; then
    cat << YAML
    - Passwords:
        icon: vaultwarden.png
        href: $(make_url vault 8080)
        description: Password manager
YAML
  fi

  if has_profile "dns"; then
    cat << YAML
    - DNS & Ads:
        icon: adguard-home.png
        href: $(make_url dns 3003)
        description: Ad blocking + DNS
        widget:
          type: adguard
          url: http://adguard:80
YAML
  fi

  if has_profile "monitoring"; then
    cat << YAML
    - Monitoring:
        icon: uptime-kuma.png
        href: $(make_url status 3001)
        description: Service monitoring
        widget:
          type: uptimekuma
          url: http://uptime_kuma:3001
YAML
  fi

  cat << YAML
    - Proxy Manager:
        icon: nginx-proxy-manager.png
        href: $(make_url manage 81)
        description: Reverse proxy + SSL
YAML

} > "${CONFIG_DIR}/services.yaml"

echo "Homepage config generated at ${CONFIG_DIR}/services.yaml"
