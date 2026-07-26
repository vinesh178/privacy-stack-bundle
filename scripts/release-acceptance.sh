#!/bin/bash
# Post-reboot acceptance gate for a fresh release-candidate server.

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR" || exit 1

PASS=0
FAIL=0

pass() {
  echo -e "  ${GREEN}PASS${NC}  $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "  ${RED}FAIL${NC}  $1"
  FAIL=$((FAIL + 1))
}

check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash scripts/release-acceptance.sh"
  exit 1
fi

if [ ! -f .env ]; then
  echo "Run this command from an installed Privacy Stack repository."
  exit 1
fi

# shellcheck disable=SC1091
. scripts/lib/env.sh
load_privacy_env .env

PUBLIC_INTERFACE=$(ip route show default | awk 'NR==1 {print $5}')
TAILSCALE_IP=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1 || true)
EXPECTED_PROFILES="docs,media,dns,monitoring,dashboard,vpn"
LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
ORIGIN_MAIN=$(git rev-parse refs/remotes/origin/main 2>/dev/null || true)

echo "Privacy Stack release acceptance"
echo "================================"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "Boot:   $(uptime -s 2>/dev/null || echo unknown)"
echo ""

echo "Release and service health:"
[ "${COMPOSE_PROFILES:-}" = "$EXPECTED_PROFILES" ] &&
  pass "fixed MVP profile set is exact" ||
  fail "fixed MVP profile set is exact"
check "repository is on main" test "$(git branch --show-current 2>/dev/null)" = main
check "tracked release files are unchanged" \
  git diff --quiet HEAD -- . ':(exclude)configs/homepage/services.yaml'
if git ls-files --others --exclude-standard | grep -q .; then
  fail "repository has no unexpected untracked files"
else
  pass "repository has no unexpected untracked files"
fi
if [ -n "$LOCAL_HEAD" ] &&
  [ -n "$ORIGIN_MAIN" ] &&
  [ "$LOCAL_HEAD" = "$ORIGIN_MAIN" ]; then
  pass "installed commit exactly matches origin/main"
else
  fail "installed commit exactly matches origin/main"
fi
if bash scripts/test.sh; then
  pass "container, HTTP, DNS, resource, and Tailscale health gate"
else
  fail "container, HTTP, DNS, resource, and Tailscale health gate"
fi

echo ""
echo "Post-reboot firewall persistence:"
check "VPN lockdown unit is enabled" \
  systemctl is-enabled --quiet privacy-stack-vpn-lockdown.service
check "VPN lockdown unit ran successfully this boot" \
  systemctl is-active --quiet privacy-stack-vpn-lockdown.service
if systemctl is-enabled --quiet privacy-stack-onboarding-firewall.service; then
  fail "temporary onboarding firewall is disabled"
else
  pass "temporary onboarding firewall is disabled"
fi
if [ -n "$PUBLIC_INTERFACE" ]; then
  pass "public interface detected as $PUBLIC_INTERFACE"
  check "public INPUT enters the release-owned deny chain" \
    iptables -C INPUT -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT
  check "public forwarding enters the release-owned deny chain" \
    iptables -C FORWARD -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_FORWARD
  check "Docker forwarding enters the release-owned deny chain" \
    iptables -C DOCKER-USER -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_FORWARD
  check "Docker's first user rule is the release-owned deny chain" \
    sh -c "iptables -S DOCKER-USER | grep '^-A DOCKER-USER ' | head -1 | grep -qx -- '-A DOCKER-USER -i $PUBLIC_INTERFACE -j PRIVACY_STACK_FORWARD'"
else
  fail "public interface detected"
fi
if iptables -C PRIVACY_STACK_INPUT -p tcp --dport 22 -j ACCEPT >/dev/null 2>&1; then
  fail "public SSH is absent from the final allowlist"
else
  pass "public SSH is absent from the final allowlist"
fi
check "final public-input chain ends in DROP" \
  sh -c "iptables -S PRIVACY_STACK_INPUT | tail -1 | grep -qx -- '-A PRIVACY_STACK_INPUT -j DROP'"
check "final public-forward chain ends in DROP" \
  sh -c "iptables -S PRIVACY_STACK_FORWARD | tail -1 | grep -qx -- '-A PRIVACY_STACK_FORWARD -j DROP'"

if [ -n "$PUBLIC_INTERFACE" ] &&
  ip -6 address show dev "$PUBLIC_INTERFACE" scope global |
  grep -q 'inet6 '; then
  echo ""
  echo "Public IPv6 firewall persistence:"
  check "IPv6 public INPUT enters the release-owned deny chain" \
    ip6tables -C INPUT -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_INPUT
  check "IPv6 public forwarding enters the release-owned deny chain" \
    ip6tables -C FORWARD -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_FORWARD
  check "IPv6 Docker forwarding enters the release-owned deny chain" \
    ip6tables -C DOCKER-USER -i "$PUBLIC_INTERFACE" -j PRIVACY_STACK_FORWARD
  check "IPv6 Docker's first user rule is the release-owned deny chain" \
    sh -c "ip6tables -S DOCKER-USER | grep '^-A DOCKER-USER ' | head -1 | grep -qx -- '-A DOCKER-USER -i $PUBLIC_INTERFACE -j PRIVACY_STACK_FORWARD'"
  if ip6tables -C PRIVACY_STACK_INPUT -p tcp --dport 22 -j ACCEPT >/dev/null 2>&1; then
    fail "public IPv6 SSH is absent from the final allowlist"
  else
    pass "public IPv6 SSH is absent from the final allowlist"
  fi
  check "final IPv6 public-input chain ends in DROP" \
    sh -c "ip6tables -S PRIVACY_STACK_INPUT | tail -1 | grep -qx -- '-A PRIVACY_STACK_INPUT -j DROP'"
  check "final IPv6 public-forward chain ends in DROP" \
    sh -c "ip6tables -S PRIVACY_STACK_FORWARD | tail -1 | grep -qx -- '-A PRIVACY_STACK_FORWARD -j DROP'"
else
  pass "server has no public IPv6 address requiring firewall validation"
fi

echo ""
echo "Private access after reboot:"
check "tailscale0 interface exists" ip link show tailscale0
if [ -n "$TAILSCALE_IP" ]; then
  pass "Tailscale IPv4 is $TAILSCALE_IP"
  check "Paperless responds through Tailscale" curl -fsS --max-time 10 "http://$TAILSCALE_IP:8000"
  check "Jellyfin responds through Tailscale" curl -fsS --max-time 10 "http://$TAILSCALE_IP:8096"
  check "AdGuard dashboard responds through Tailscale" curl -fsS --max-time 10 "http://$TAILSCALE_IP:3003"
  check "Uptime Kuma responds through Tailscale" curl -fsS --max-time 10 "http://$TAILSCALE_IP:3001"
  check "Homepage responds through Tailscale" curl -fsS --max-time 10 "http://$TAILSCALE_IP:3002"
  if dig "@$TAILSCALE_IP" example.com +short +time=3 2>/dev/null | grep -q .; then
    pass "AdGuard resolves DNS through Tailscale"
  else
    fail "AdGuard resolves DNS through Tailscale"
  fi
else
  fail "Tailscale IPv4 is assigned"
fi

echo ""
echo "================================"
echo "Result: $PASS passed, $FAIL failed"
echo ""
echo "From a computer outside the server, verify the public address is closed:"
echo "  nc -vz -w 5 PUBLIC_IP 22"
echo "  for port in 53 80 81 443 3000 3001 3002 3003 8000 8096; do"
echo "    nc -vz -w 5 PUBLIC_IP \"\$port\""
echo "  done"
echo "  dig @PUBLIC_IP example.com A +time=3 +tries=1"
echo "If the server has public IPv6, repeat the TCP probes with nc -6 and run:"
echo "  dig -6 @PUBLIC_IPV6 example.com A +time=3 +tries=1"
echo "Every command above must fail or time out."

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
