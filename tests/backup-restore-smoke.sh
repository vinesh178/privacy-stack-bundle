#!/bin/bash
# Destructive round-trip test isolated to a unique temporary Compose project.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
PROJECT_NAME="privacy-stack-test-$$"
VOLUME_NAME="${PROJECT_NAME}_uptime_kuma_data"
BACKUP_FILE="$TEST_DIR/roundtrip.tar.gz.enc"
PASSPHRASE_FILE="$TEST_DIR/passphrase"

cleanup() {
  (cd "$TEST_DIR" && docker compose down --volumes >/dev/null 2>&1) || true
  docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_DIR/configs" "$TEST_DIR/data" "$TEST_DIR/scripts/lib"
cp "$ROOT_DIR/scripts/lib/env.sh" "$TEST_DIR/scripts/lib/env.sh"
cat > "$TEST_DIR/docker-compose.yml" <<'YAML'
name: ${COMPOSE_PROJECT_NAME}
services:
  probe:
    image: alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
    command: ["sleep", "infinity"]
    profiles: ["monitoring"]
    volumes:
      - uptime_kuma_data:/data
volumes:
  uptime_kuma_data:
YAML
cat > "$TEST_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=$PROJECT_NAME
COMPOSE_PROFILES=monitoring
DATA_DIR=$TEST_DIR/data
BACKUP_DIR=$TEST_DIR/backups
EOF
chmod 600 "$TEST_DIR/.env"
printf 'roundtrip-test-passphrase' > "$PASSPHRASE_FILE"
chmod 600 "$PASSPHRASE_FILE"

(cd "$TEST_DIR" && docker compose up -d)
docker run --rm -v "$VOLUME_NAME:/data" \
  alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce \
  sh -c 'printf release-roundtrip > /data/sentinel'

PRIVACY_STACK_TESTING=1 INSTALL_DIR="$TEST_DIR" \
  PRIVACY_STACK_LOCK_FILE="$TEST_DIR/operation.lock" \
  bash "$ROOT_DIR/scripts/backup.sh" --passphrase-file="$PASSPHRASE_FILE" "$BACKUP_FILE"
(cd "$TEST_DIR" && docker compose down --volumes)

PRIVACY_STACK_TESTING=1 PRIVACY_STACK_SKIP_HOST_SETUP=1 \
  PRIVACY_STACK_ALLOWED_DATA_ROOT="$TEST_DIR" INSTALL_DIR="$TEST_DIR" \
  PRIVACY_STACK_LOCK_FILE="$TEST_DIR/operation.lock" \
  bash "$ROOT_DIR/scripts/restore.sh" --yes \
    --passphrase-file="$PASSPHRASE_FILE" "$BACKUP_FILE"

result=$(docker run --rm -v "$VOLUME_NAME:/data:ro" \
  alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce \
  cat /data/sentinel)
[ "$result" = "release-roundtrip" ]
echo "Backup/restore round trip passed."
