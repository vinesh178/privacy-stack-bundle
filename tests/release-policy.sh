#!/bin/bash
# Release security invariants for the opinionated stack.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

. configs/opinionated.env

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

onboarding_line=$(grep -n 'protect-onboarding.sh' scripts/setup.sh | head -1 | cut -d: -f1)
compose_line=$(grep -n 'docker compose up -d' scripts/setup.sh | head -1 | cut -d: -f1)
[ -n "$onboarding_line" ] && [ "$onboarding_line" -lt "$compose_line" ] ||
  fail "public ingress protection is not installed before containers start"

echo "Release security policy passed."
