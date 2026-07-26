#!/bin/bash
# Create a verified full or hot backup of the configured stack.

set -euo pipefail
umask 077

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
HOT_BACKUP=false
BACKUP_PATH=""
STACK_STOPPED=false
TEMP_DIR=""

for arg in "$@"; do
  case "$arg" in
    --hot) HOT_BACKUP=true ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) BACKUP_PATH="$arg" ;;
  esac
done

if [ "$EUID" -ne 0 ] && [ "${PRIVACY_STACK_TESTING:-0}" != "1" ]; then
  echo -e "${RED}Run with sudo: sudo bash scripts/backup.sh [--hot] [output.tar.gz]${NC}"
  exit 1
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  echo -e "${RED}.env not found. Run setup first.${NC}"
  exit 1
fi

set -a
# shellcheck disable=SC1091
. "$INSTALL_DIR/.env"
set +a

PROFILES="${COMPOSE_PROFILES:-docs,media,dns,monitoring,dashboard,vpn}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-privacy-stack}"
BACKUP_DIR="${BACKUP_DIR:-/srv/backups/privacy-stack}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="${BACKUP_PATH:-$BACKUP_DIR/privacy-stack-$TIMESTAMP.tar.gz}"
TEMP_DIR=$(mktemp -d)

cleanup() {
  local exit_code=$?
  [ -n "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
  if [ "$STACK_STOPPED" = true ]; then
    echo "Restarting containers..."
    (cd "$INSTALL_DIR" && docker compose up -d) || exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

has_profile() {
  [[ ",$PROFILES," == *",$1,"* ]]
}

mkdir -p "$BACKUP_DIR" "$TEMP_DIR/volumes" "$TEMP_DIR/data" "$TEMP_DIR/config"
cd "$INSTALL_DIR"

echo "Privacy Stack backup"
echo "Mode: $([ "$HOT_BACKUP" = true ] && echo hot || echo full)"
echo "Output: $BACKUP_PATH"

if [ "$HOT_BACKUP" = true ]; then
  if has_profile "docs"; then
    echo "Dumping Paperless PostgreSQL database..."
    docker exec paperless_db pg_dump \
      --username postgres --dbname paperless --format custom \
      > "$TEMP_DIR/volumes/paperless_db.dump"
    [ -s "$TEMP_DIR/volumes/paperless_db.dump" ] ||
      { echo -e "${RED}Paperless database dump is empty.${NC}"; exit 1; }
  fi
else
  echo "Stopping containers for a consistent volume snapshot..."
  docker compose stop
  STACK_STOPPED=true
fi

profile_volumes() {
  case "$1" in
    proxy) echo "npm_data npm_letsencrypt" ;;
    docs) echo "paperless_data paperless_media paperless_pgdata" ;;
    media) echo "jellyfin_config jellyfin_cache" ;;
    dns) echo "adguard_work adguard_conf" ;;
    passwords) echo "vaultwarden_data" ;;
    monitoring) echo "uptime_kuma_data" ;;
    vpn) echo "tailscale_data" ;;
    dashboard) echo "" ;;
    *) echo -e "${RED}Unsupported profile: $1${NC}" >&2; return 1 ;;
  esac
}

VOLUMES_TO_BACKUP=""
for profile in ${PROFILES//,/ }; do
  profile_volumes=$(profile_volumes "$profile")
  if [ "$HOT_BACKUP" = true ] && [ "$profile" = "docs" ]; then
    profile_volumes="paperless_data paperless_media"
  fi
  VOLUMES_TO_BACKUP="$VOLUMES_TO_BACKUP $profile_volumes"
done

echo "Backing up named volumes..."
for volume in $VOLUMES_TO_BACKUP; do
  full_volume="${PROJECT_NAME}_${volume}"
  if ! docker volume inspect "$full_volume" >/dev/null 2>&1; then
    echo -e "${RED}Required volume is missing: $full_volume${NC}"
    exit 1
  fi
  docker run --rm \
    -v "$full_volume:/data:ro" \
    -v "$TEMP_DIR/volumes:/backup" \
    alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce \
    tar czf "/backup/$volume.tar.gz" -C /data .
  [ -s "$TEMP_DIR/volumes/$volume.tar.gz" ] ||
    { echo -e "${RED}Volume archive is empty: $volume${NC}"; exit 1; }
  echo "  $volume"
done

DATA_DIR="${DATA_DIR:-/srv/privacy-stack}"
if [ -d "$DATA_DIR" ]; then
  tar czf "$TEMP_DIR/data/user-data.tar.gz" -C "$DATA_DIR" .
fi

cp "$INSTALL_DIR/.env" "$TEMP_DIR/config/.env"
cp -R "$INSTALL_DIR/configs" "$TEMP_DIR/config/configs"
cp "$INSTALL_DIR/docker-compose.yml" "$TEMP_DIR/config/docker-compose.yml.reference"

cat > "$TEMP_DIR/manifest.json" <<EOF
{
  "schema_version": 2,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "profiles": "$PROFILES",
  "compose_project": "$PROJECT_NAME",
  "data_dir": "$DATA_DIR",
  "backup_mode": "$([ "$HOT_BACKUP" = true ] && echo hot || echo full)"
}
EOF

tar czf "$BACKUP_PATH" -C "$TEMP_DIR" .
chmod 600 "$BACKUP_PATH"
(cd "$(dirname "$BACKUP_PATH")" &&
  sha256sum "$(basename "$BACKUP_PATH")" > "$(basename "$BACKUP_PATH").sha256")
chmod 600 "$BACKUP_PATH.sha256"

echo -e "${GREEN}Backup verified and complete.${NC}"
echo "Archive: $BACKUP_PATH"
echo "Checksum: $BACKUP_PATH.sha256"
