#!/bin/bash
# Release security invariants for the opinionated stack.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

. configs/opinionated.conf

[ "$PRIVACY_STACK_PROFILES" = "docs,media,dns,monitoring,dashboard,vpn" ] ||
  fail "opinionated profiles include a deferred or HTTPS-dependent service"

retired_pattern='im''mich|profile[^[:alnum:]]+pho''tos'
if rg -i "$retired_pattern" \
  --glob '!.git/**' --glob '!go.sum' . >/dev/null; then
  fail "retired photo service remains in the release tree"
fi

compose_json=$(mktemp)
trap 'rm -f "$compose_json"' EXIT
docker compose --env-file .env.example --profile "*" \
  config --format json > "$compose_json"

node - "$compose_json" <<'NODE'
const fs = require("fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const homepageMounts = config.services.homepage.volumes || [];
if (homepageMounts.some((mount) => mount.source === "/var/run/docker.sock")) {
  throw new Error("Homepage must not mount the Docker daemon socket");
}
if (!config.services["nginx-proxy-manager"].profiles.includes("proxy")) {
  throw new Error("Nginx Proxy Manager must be opt-in");
}
for (const [name, service] of Object.entries(config.services)) {
  if (!service.image.includes("@sha256:")) {
    throw new Error(`${name} image is not digest-pinned: ${service.image}`);
  }
}
NODE

grep -q 'chmod 600 .env credentials.txt' scripts/setup.sh ||
  fail "generated secret files are not both mode 600"

dotenv_exec_pattern='^[[:space:]]*(sou''rce|\\.)[[:space:]]+.*\\.env([[:space:]]|$)'
if rg -n "$dotenv_exec_pattern" \
  --glob '*.sh' . >/dev/null; then
  fail "a shell script executes dotenv content"
fi

onboarding_line=$(grep -n 'protect-onboarding.sh' scripts/setup.sh | head -1 | cut -d: -f1)
compose_line=$(grep -n 'docker compose up -d' scripts/setup.sh | head -1 | cut -d: -f1)
[ -n "$onboarding_line" ] && [ "$onboarding_line" -lt "$compose_line" ] ||
  fail "public ingress protection is not installed before containers start"

for firewall_script in scripts/protect-onboarding.sh scripts/lockdown-vpn.sh; do
  grep -q 'Before=docker.service' "$firewall_script" ||
    fail "$firewall_script does not restore host firewall rules before Docker"
  grep -q 'PRIVACY_STACK_FORWARD' "$firewall_script" ||
    fail "$firewall_script does not fail closed for forwarded container traffic"
done

age_install_line=$(grep -n 'platform_install_age' scripts/restore.sh | head -1 | cut -d: -f1)
decrypt_detection_line=$(grep -n "head -c 24" scripts/restore.sh | head -1 | cut -d: -f1)
[ -n "$age_install_line" ] && [ "$age_install_line" -lt "$decrypt_detection_line" ] ||
  fail "fresh-server restore checks encrypted input before installing age"

for invariant in \
  'systemctl is-active --quiet privacy-stack-vpn-lockdown.service' \
  'iptables -C DOCKER-USER' \
  'ip6tables -C DOCKER-USER' \
  'installed commit exactly matches origin/main' \
  'git fetch --quiet origin main' \
  'git ls-files --others --exclude-standard' \
  'dig @PUBLIC_IP example.com A' \
  'AdGuard resolves DNS through Tailscale'; do
  grep -Fq "$invariant" scripts/release-acceptance.sh ||
    fail "post-reboot acceptance gate omits: $invariant"
done

for firewall_script in scripts/protect-onboarding.sh scripts/lockdown-vpn.sh; do
  grep -Fq 'PUBLIC_INTERFACE_V6=$(ip -6 route show default' "$firewall_script" ||
    fail "$firewall_script does not resolve the IPv6 public interface independently"
done

echo "Release security policy passed."
