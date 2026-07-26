#!/bin/bash
# Verify a hot Paperless database dump replaces an incompatible existing DB.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
PROJECT_NAME="privacy-stack-hot-test-$$"
BACKUP_FILE="$TEST_DIR/hot-roundtrip.tar.gz.enc"
PASSPHRASE_FILE="$TEST_DIR/passphrase"
POSTGRES_IMAGE="postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777"

cleanup() {
  (cd "$TEST_DIR" && docker compose down --volumes >/dev/null 2>&1) || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_DIR/configs" "$TEST_DIR/data" "$TEST_DIR/scripts/lib"
cp "$ROOT_DIR/scripts/lib/env.sh" "$TEST_DIR/scripts/lib/env.sh"
cat > "$TEST_DIR/docker-compose.yml" <<YAML
name: \${COMPOSE_PROJECT_NAME}
services:
  paperless-db:
    image: $POSTGRES_IMAGE
    container_name: paperless_db
    profiles: ["docs"]
    environment:
      POSTGRES_PASSWORD: \${PAPERLESS_DB_PASSWORD}
      POSTGRES_DB: paperless
    volumes:
      - paperless_pgdata:/var/lib/postgresql/data
  volume-holder:
    image: alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
    command: ["sleep", "infinity"]
    profiles: ["docs"]
    volumes:
      - paperless_data:/data
      - paperless_media:/media
volumes:
  paperless_data:
  paperless_media:
  paperless_pgdata:
YAML
write_env() {
  local password=$1
  cat > "$TEST_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=$PROJECT_NAME
COMPOSE_PROFILES=docs
DATA_DIR=$TEST_DIR/data
BACKUP_DIR=$TEST_DIR/backups
PAPERLESS_DB_PASSWORD=$password
EOF
  chmod 600 "$TEST_DIR/.env"
}

write_env backup-password
printf 'hot-roundtrip-test-passphrase' > "$PASSPHRASE_FILE"
chmod 600 "$PASSPHRASE_FILE"
(cd "$TEST_DIR" && docker compose up -d)
for _ in $(seq 1 30); do
  docker exec paperless_db pg_isready -U postgres -d paperless >/dev/null 2>&1 && break
  sleep 1
done
docker exec paperless_db psql -U postgres -d paperless -c \
  "CREATE TABLE release_probe(value text); INSERT INTO release_probe VALUES ('from-backup');"

PRIVACY_STACK_TESTING=1 INSTALL_DIR="$TEST_DIR" \
  PRIVACY_STACK_LOCK_FILE="$TEST_DIR/operation.lock" \
  bash "$ROOT_DIR/scripts/backup.sh" --hot \
    --passphrase-file="$PASSPHRASE_FILE" "$BACKUP_FILE"

(cd "$TEST_DIR" && docker compose down --volumes)
write_env incompatible-password
(cd "$TEST_DIR" && docker compose up -d)
for _ in $(seq 1 30); do
  docker exec paperless_db pg_isready -U postgres -d paperless >/dev/null 2>&1 && break
  sleep 1
done

PRIVACY_STACK_TESTING=1 PRIVACY_STACK_SKIP_HOST_SETUP=1 \
  PRIVACY_STACK_ALLOWED_DATA_ROOT="$TEST_DIR" INSTALL_DIR="$TEST_DIR" \
  PRIVACY_STACK_LOCK_FILE="$TEST_DIR/operation.lock" \
  bash "$ROOT_DIR/scripts/restore.sh" --yes \
    --passphrase-file="$PASSPHRASE_FILE" "$BACKUP_FILE"

result=$(docker exec paperless_db psql -U postgres -d paperless -Atc \
  "SELECT value FROM release_probe;")
[ "$result" = "from-backup" ]
echo "Hot backup/restore round trip passed."
