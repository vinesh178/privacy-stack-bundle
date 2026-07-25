#!/bin/bash
# ============================================================
# Privacy Stack — Health Check / Test Script
# Run after setup to verify all services are up
# Usage: bash scripts/test.sh
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source .env for profile and IP info
if [ -f "${INSTALL_DIR}/.env" ]; then
  set -a
  source "${INSTALL_DIR}/.env"
  set +a
fi

PROFILES="${COMPOSE_PROFILES:-photos,docs,media,dns,passwords,monitoring,dashboard,vpn}"

has_profile() {
  [[ ",$PROFILES," == *",$1,"* ]]
}

PASS=0
FAIL=0
WARN=0

check_service() {
  local name=$1
  local url=$2
  local expected_code=${3:-200}

  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

  if [ "$code" = "$expected_code" ] || [ "$code" = "302" ] || [ "$code" = "301" ]; then
    echo -e "  ${GREEN}$name${NC} — HTTP $code"
    PASS=$((PASS + 1))
  elif [ "$code" = "000" ]; then
    echo -e "  ${RED}$name${NC} — Connection refused (not running?)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${YELLOW}$name${NC} — HTTP $code (expected $expected_code)"
    WARN=$((WARN + 1))
  fi
}

check_container() {
  local name=$1
  local container=$2

  status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")

  if [ "$status" = "running" ]; then
    echo -e "  ${GREEN}$name${NC} — running"
    PASS=$((PASS + 1))
  elif [ "$status" = "not_found" ]; then
    echo -e "  ${RED}$name${NC} — container not found"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${RED}$name${NC} — $status"
    FAIL=$((FAIL + 1))
  fi
}

IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

echo ""
echo "Privacy Stack Health Check"
echo "=============================="
echo "Server IP: $IP"
echo "Profiles:  $PROFILES"
echo ""

# ---- Container Status ----
echo "Container Status:"
check_container "Nginx Proxy Manager" "npm"

if has_profile "photos"; then
  check_container "Immich Server" "immich_server"
  check_container "Immich ML" "immich_ml"
  check_container "Immich Redis" "immich_redis"
  check_container "Immich Postgres" "immich_postgres"
fi

if has_profile "docs"; then
  check_container "Paperless" "paperless"
  check_container "Paperless DB" "paperless_db"
  check_container "Paperless Redis" "paperless_redis"
  check_container "Paperless Gotenberg" "paperless_gotenberg"
  check_container "Paperless Tika" "paperless_tika"
fi

has_profile "media"      && check_container "Jellyfin" "jellyfin"
has_profile "dns"        && check_container "AdGuard Home" "adguard"
has_profile "passwords"  && check_container "Vaultwarden" "vaultwarden"
has_profile "monitoring" && check_container "Uptime Kuma" "uptime_kuma"
has_profile "dashboard"  && check_container "Homepage" "homepage"
has_profile "vpn"        && check_container "Tailscale" "tailscale"
echo ""

# ---- HTTP Endpoints ----
echo "HTTP Endpoints:"
check_service "Nginx Proxy Manager" "http://localhost:81"
has_profile "photos"     && check_service "Immich" "http://localhost:2283"
has_profile "docs"       && check_service "Paperless" "http://localhost:8000"
has_profile "media"      && check_service "Jellyfin" "http://localhost:8096"
has_profile "dns"        && check_service "AdGuard Home" "http://localhost:3000"
has_profile "passwords"  && check_service "Vaultwarden" "http://localhost:8080"
has_profile "monitoring" && check_service "Uptime Kuma" "http://localhost:3001"
has_profile "dashboard"  && check_service "Homepage" "http://localhost:3002"
echo ""

# ---- DNS ----
if has_profile "dns"; then
  echo "DNS (AdGuard):"
  dns_result=$(dig @localhost google.com +short +time=3 2>/dev/null | head -1)
  if [ -n "$dns_result" ]; then
    echo -e "  ${GREEN}DNS resolving${NC} — google.com → $dns_result"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}DNS not resolving${NC}"
    FAIL=$((FAIL + 1))
  fi
  echo ""
fi

# ---- Disk & RAM ----
echo "Resources:"
echo "  RAM: $(free -h 2>/dev/null | awk '/^Mem:/{print $3 "/" $2}' || echo "N/A")"
echo "  Disk: $(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 " used)"}' || echo "N/A")"
echo "  Containers: $(docker ps -q | wc -l | tr -d ' ') running"
echo ""

# ---- Tailscale ----
if has_profile "vpn"; then
  echo "Tailscale:"
  ts_status=$(docker exec tailscale tailscale status --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Self',{}).get('TailscaleIPs',['not connected'])[0])" 2>/dev/null || echo "not connected")
  if [ "$ts_status" != "not connected" ]; then
    echo -e "  ${GREEN}Connected${NC} — Tailscale IP: $ts_status"
    PASS=$((PASS + 1))
  else
    echo -e "  ${YELLOW}Not connected${NC} — Run: docker exec tailscale tailscale up"
    WARN=$((WARN + 1))
  fi
  echo ""
fi

# ---- Summary ----
TOTAL=$((PASS + FAIL + WARN))
echo "=============================="
echo -e "Results: ${GREEN}$PASS passed${NC} | ${RED}$FAIL failed${NC} | ${YELLOW}$WARN warnings${NC} | $TOTAL total"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}All services healthy!${NC}"
  echo ""
  echo "Access your stack:"
  echo "  NPM:        http://$IP:81"
  has_profile "photos"     && echo "  Photos:     http://$IP:2283"
  has_profile "docs"       && echo "  Documents:  http://$IP:8000"
  has_profile "media"      && echo "  Media:      http://$IP:8096"
  has_profile "dns"        && echo "  DNS/Ads:    http://$IP:3000"
  has_profile "passwords"  && echo "  Passwords:  http://$IP:8080"
  has_profile "monitoring" && echo "  Monitoring: http://$IP:3001"
  has_profile "dashboard"  && echo "  Dashboard:  http://$IP:3002"
else
  echo -e "${RED}Some services failed. Check logs:${NC}"
  echo "  docker compose logs <service_name>"
fi
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
