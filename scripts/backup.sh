#!/bin/bash
# Create a verified full or hot backup of the configured stack.

set -euo pipefail
umask 077

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
HOT_BACKUP=false
ENCRYPT_BACKUP=true
PASSPHRASE_FILE=""
BACKUP_PATH=""
STACK_STOPPED=false
TEMP_DIR=""
PLAIN_ARCHIVE=""
GENERATED_PASSPHRASE=""

for arg in "$@"; do
  case "$arg" in
    --hot) HOT_BACKUP=true ;;
    --unencrypted) ENCRYPT_BACKUP=false ;;
    --passphrase-file)
      echo "--passphrase-file requires a separate path argument." >&2
      exit 1
      ;;
    --passphrase-file=*) PASSPHRASE_FILE=${arg#*=} ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) BACKUP_PATH="$arg" ;;
  esac
done

if [ "$EUID" -ne 0 ] && [ "${PRIVACY_STACK_TESTING:-0}" != "1" ]; then
  echo -e "${RED}Run with sudo: sudo bash scripts/backup.sh [--hot] [output.tar.gz]${NC}"
  exit 1
fi

OPERATION_LOCK="${PRIVACY_STACK_LOCK_FILE:-/var/lock/privacy-stack-operation.lock}"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$OPERATION_LOCK"
  if ! flock -n 9; then
    echo -e "${RED}Another Privacy Stack operation is already running.${NC}"
    exit 1
  fi
elif [ "${PRIVACY_STACK_TESTING:-0}" != "1" ]; then
  echo -e "${RED}flock is required to protect backup operations.${NC}"
  exit 1
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  echo -e "${RED}.env not found. Run setup first.${NC}"
  exit 1
fi

# shellcheck disable=SC1091
. "$INSTALL_DIR/scripts/lib/env.sh"
load_privacy_env "$INSTALL_DIR/.env"

PROFILES="${COMPOSE_PROFILES:-docs,media,dns,monitoring,dashboard,vpn}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-privacy-stack}"
BACKUP_DIR="${BACKUP_DIR:-/srv/backups/privacy-stack}"
DATA_DIR="${DATA_DIR:-/srv/privacy-stack}"
ALLOWED_DATA_ROOT="${PRIVACY_STACK_ALLOWED_DATA_ROOT:-/srv}"
if ! [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo -e "${RED}Invalid Compose project name.${NC}"
  exit 1
fi
for profile in ${PROFILES//,/ }; do
  case "$profile" in
    proxy|docs|media|dns|passwords|monitoring|dashboard|vpn) ;;
    *) echo -e "${RED}Unsupported profile: $profile${NC}"; exit 1 ;;
  esac
done
case "$DATA_DIR" in
  "$ALLOWED_DATA_ROOT"/*) ;;
  *) echo -e "${RED}DATA_DIR must be below $ALLOWED_DATA_ROOT: $DATA_DIR${NC}"; exit 1 ;;
esac
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [ -z "$BACKUP_PATH" ]; then
  BACKUP_PATH="$BACKUP_DIR/privacy-stack-$TIMESTAMP.tar.gz"
  [ "$ENCRYPT_BACKUP" = true ] && BACKUP_PATH="$BACKUP_PATH.age"
elif [ "$ENCRYPT_BACKUP" = true ] && [[ "$BACKUP_PATH" != *.age ]]; then
  BACKUP_PATH="$BACKUP_PATH.age"
fi
TEMP_DIR=$(mktemp -d)

cleanup() {
  local exit_code=$?
  [ -n "$PLAIN_ARCHIVE" ] && rm -f "$PLAIN_ARCHIVE"
  [ -n "$GENERATED_PASSPHRASE" ] && rm -f "$GENERATED_PASSPHRASE"
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

mkdir -p "$BACKUP_DIR" "$(dirname "$BACKUP_PATH")" \
  "$TEMP_DIR/volumes" "$TEMP_DIR/data" "$TEMP_DIR/config"
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

if [ -d "$DATA_DIR" ]; then
  tar czf "$TEMP_DIR/data/user-data.tar.gz" -C "$DATA_DIR" .
fi

cp "$INSTALL_DIR/.env" "$TEMP_DIR/config/.env"
cp -R "$INSTALL_DIR/configs" "$TEMP_DIR/config/configs"
cp "$INSTALL_DIR/docker-compose.yml" "$TEMP_DIR/config/docker-compose.yml.reference"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
MANIFEST_PROFILES=$(json_escape "$PROFILES")
MANIFEST_PROJECT=$(json_escape "$PROJECT_NAME")
MANIFEST_DATA_DIR=$(json_escape "$DATA_DIR")
cat > "$TEMP_DIR/manifest.json" <<EOF
{
  "schema_version": 2,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "profiles": "$MANIFEST_PROFILES",
  "compose_project": "$MANIFEST_PROJECT",
  "data_dir": "$MANIFEST_DATA_DIR",
  "backup_mode": "$([ "$HOT_BACKUP" = true ] && echo hot || echo full)"
}
EOF

PLAIN_ARCHIVE=$(mktemp)
tar czf "$PLAIN_ARCHIVE" -C "$TEMP_DIR" .
if [ "$ENCRYPT_BACKUP" = true ]; then
  command -v age >/dev/null 2>&1 &&
    command -v age-plugin-batchpass >/dev/null 2>&1 ||
    { echo -e "${RED}age and age-plugin-batchpass are required.${NC}"; exit 1; }
  if [ -z "$PASSPHRASE_FILE" ]; then
    PASSPHRASE_FILE=$(mktemp)
    GENERATED_PASSPHRASE="$PASSPHRASE_FILE"
    read -r -s -p "Backup passphrase: " passphrase </dev/tty
    echo
    read -r -s -p "Confirm passphrase: " confirmation </dev/tty
    echo
    [ -n "$passphrase" ] && [ "$passphrase" = "$confirmation" ] ||
      { echo -e "${RED}Passphrases are empty or do not match.${NC}"; exit 1; }
    printf '%s' "$passphrase" > "$PASSPHRASE_FILE"
    unset passphrase confirmation
  fi
  [ -f "$PASSPHRASE_FILE" ] ||
    { echo -e "${RED}Passphrase file not found.${NC}"; exit 1; }
  AGE_PASSPHRASE_FD=3 age -e -j batchpass \
    -o "$BACKUP_PATH" "$PLAIN_ARCHIVE" 3< "$PASSPHRASE_FILE"
else
  cp "$PLAIN_ARCHIVE" "$BACKUP_PATH"
fi
rm -f "$PLAIN_ARCHIVE"
chmod 600 "$BACKUP_PATH"
(cd "$(dirname "$BACKUP_PATH")" &&
  sha256sum "$(basename "$BACKUP_PATH")" > "$(basename "$BACKUP_PATH").sha256")
chmod 600 "$BACKUP_PATH.sha256"

echo -e "${GREEN}Backup verified and complete.${NC}"
echo "Encryption: $([ "$ENCRYPT_BACKUP" = true ] && echo age-authenticated || echo disabled)"
echo "Archive: $BACKUP_PATH"
echo "Checksum: $BACKUP_PATH.sha256"
