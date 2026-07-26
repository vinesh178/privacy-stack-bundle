#!/bin/bash
# ============================================================
# Privacy Stack — Auto-configure Nginx Proxy Manager
# Called by setup.sh after containers are running.
#
# - Changes default admin password
# - Creates proxy hosts for enabled services (if domain is set)
# - Requests Let's Encrypt SSL certificates (if domain + email set)
# - Skips proxy config for IP-only mode (users access via IP:port)
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source .env
if [ -f "${INSTALL_DIR}/.env" ]; then
  set -a
  source "${INSTALL_DIR}/.env"
  set +a
fi

NPM_URL="http://localhost:81"
NPM_DEFAULT_EMAIL="admin@example.com"
NPM_DEFAULT_PASS="changeme"
PROFILES="${COMPOSE_PROFILES:-proxy,docs,media,dns,passwords,monitoring,dashboard,vpn}"

has_profile() {
  [[ ",$PROFILES," == *",$1,"* ]]
}

# ---- Wait for NPM to be ready ----
echo "Waiting for Nginx Proxy Manager API..."
MAX_WAIT=60
WAITED=0
while ! curl -s -o /dev/null -w "%{http_code}" "${NPM_URL}/api/" 2>/dev/null | grep -q "401\|200"; do
  sleep 3
  WAITED=$((WAITED + 3))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}NPM API not responding after ${MAX_WAIT}s. Skipping auto-config.${NC}"
    exit 0
  fi
done
echo -e "${GREEN}NPM API ready${NC}"

# ---- Login with default credentials ----
TOKEN_RESPONSE=$(curl -s -X POST "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_DEFAULT_EMAIL}\",\"secret\":\"${NPM_DEFAULT_PASS}\"}" 2>/dev/null)

TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  # Default password may already be changed (re-run scenario)
  echo -e "${YELLOW}Default NPM login failed — password likely already changed. Skipping NPM auto-config.${NC}"
  exit 0
fi

AUTH="Authorization: Bearer ${TOKEN}"

# ---- Change default password ----
NPM_NEW_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
NPM_NEW_EMAIL="${ACME_EMAIL:-admin@privacy-stack.local}"

# Update user profile
curl -s -X PUT "${NPM_URL}/api/users/1" \
  -H "${AUTH}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"Admin\",\"nickname\":\"Admin\",\"email\":\"${NPM_NEW_EMAIL}\"}" > /dev/null

# Change password
curl -s -X PUT "${NPM_URL}/api/users/1/auth" \
  -H "${AUTH}" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"password\",\"current\":\"${NPM_DEFAULT_PASS}\",\"secret\":\"${NPM_NEW_PASS}\"}" > /dev/null

echo -e "${GREEN}NPM default password changed${NC}"

# Re-login with new credentials
TOKEN_RESPONSE=$(curl -s -X POST "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_NEW_EMAIL}\",\"secret\":\"${NPM_NEW_PASS}\"}" 2>/dev/null)

TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
AUTH="Authorization: Bearer ${TOKEN}"

# Save NPM credentials
cat >> "${INSTALL_DIR}/credentials.txt" << EOF

Nginx Proxy Manager (updated):
  URL:      http://${SERVER_IP}:81
  Email:    ${NPM_NEW_EMAIL}
  Password: ${NPM_NEW_PASS}
EOF

# ---- If no domain, we're done ----
if [ -z "$DOMAIN" ]; then
  echo -e "${YELLOW}No domain configured — skipping proxy host creation.${NC}"
  echo "Access services directly via IP:port (see credentials.txt)."
  exit 0
fi

echo "Configuring proxy hosts for ${DOMAIN}..."

# ---- Create proxy hosts for each enabled service ----
create_proxy_host() {
  local subdomain=$1
  local forward_host=$2
  local forward_port=$3
  local domain_name="${subdomain}.${DOMAIN}"

  # Build the proxy host JSON
  local ssl_forced=false
  local cert_id=0

  # Request SSL certificate if email is set
  if [ -n "$ACME_EMAIL" ]; then
    local cert_response
    cert_response=$(curl -s -X POST "${NPM_URL}/api/nginx/certificates" \
      -H "${AUTH}" \
      -H "Content-Type: application/json" \
      -d "{
        \"domain_names\":[\"${domain_name}\"],
        \"meta\":{
          \"letsencrypt_email\":\"${ACME_EMAIL}\",
          \"letsencrypt_agree\":true,
          \"dns_challenge\":false
        },
        \"provider\":\"letsencrypt\"
      }" 2>/dev/null)

    cert_id=$(echo "$cert_response" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    if [ -n "$cert_id" ] && [ "$cert_id" != "0" ] && [ "$cert_id" != "null" ]; then
      ssl_forced=true
      echo -e "  ${GREEN}SSL cert for ${domain_name}${NC}"
    else
      cert_id=0
      echo -e "  ${YELLOW}SSL cert failed for ${domain_name} — creating without SSL${NC}"
    fi
  fi

  # Create the proxy host
  local proxy_response
  proxy_response=$(curl -s -X POST "${NPM_URL}/api/nginx/proxy-hosts" \
    -H "${AUTH}" \
    -H "Content-Type: application/json" \
    -d "{
      \"domain_names\":[\"${domain_name}\"],
      \"forward_scheme\":\"http\",
      \"forward_host\":\"${forward_host}\",
      \"forward_port\":${forward_port},
      \"block_exploits\":true,
      \"allow_websocket_upgrade\":true,
      \"ssl_forced\":${ssl_forced},
      \"certificate_id\":${cert_id},
      \"http2_support\":true,
      \"access_list_id\":0,
      \"advanced_config\":\"\",
      \"meta\":{\"letsencrypt_agree\":true,\"dns_challenge\":false}
    }" 2>/dev/null)

  local host_id
  host_id=$(echo "$proxy_response" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
  if [ -n "$host_id" ] && [ "$host_id" != "null" ]; then
    echo -e "  ${GREEN}${domain_name} → ${forward_host}:${forward_port}${NC}"
  else
    echo -e "  ${RED}Failed: ${domain_name}${NC}"
  fi
}

# Service mapping: profile|subdomain|container_name|port
PROXY_HOSTS=(
  "docs|docs|paperless|8000"
  "media|media|jellyfin|8096"
  "dns|dns|adguard|80"
  "passwords|vault|vaultwarden|80"
  "monitoring|status|uptime_kuma|3001"
  "dashboard|home|homepage|3000"
)

for entry in "${PROXY_HOSTS[@]}"; do
  IFS='|' read -r profile subdomain container port <<< "$entry"
  if has_profile "$profile"; then
    create_proxy_host "$subdomain" "$container" "$port"
  fi
done

echo ""
echo -e "${GREEN}NPM configuration complete!${NC}"
if [ -n "$ACME_EMAIL" ]; then
  echo "SSL certificates requested for all services."
  echo "Note: DNS must point *.${DOMAIN} to ${SERVER_IP} for SSL to work."
fi
