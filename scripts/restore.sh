#!/bin/bash
# Restore a schema-v2 Privacy Stack backup using the current release definition.

set -euo pipefail
umask 077

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BACKUP_FILE=""
ASSUME_YES=false
TEMP_DIR=""

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=true ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) [ -z "$BACKUP_FILE" ] || { echo "Only one backup may be restored." >&2; exit 1; }
       BACKUP_FILE="$arg" ;;
  esac
done

if [ "$EUID" -ne 0 ] && [ "${PRIVACY_STACK_TESTING:-0}" != "1" ]; then
  echo -e "${RED}Run with sudo: sudo bash scripts/restore.sh BACKUP.tar.gz${NC}"
  exit 1
fi
if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo -e "${RED}Backup file not found: ${BACKUP_FILE:-<missing>}${NC}"
  exit 1
fi

BACKUP_FILE=$(readlink -f "$BACKUP_FILE")
TEMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT INT TERM

validate_archive() {
  local archive=$1
  if ! tar tzf "$archive" | awk '
    {
      path=$0
      if (path ~ /^\//) bad=1
      sub(/^\.\//, "", path)
      if (path ~ /(^|\/)\.\.(\/|$)/) bad=1
    }
    END { exit bad }
  '; then
    echo -e "${RED}Unsafe path found in archive: $archive${NC}"
    return 1
  fi
  if ! tar tvzf "$archive" | awk '
    {
      type=substr($1, 1, 1)
      if (type != "-" && type != "d") bad=1
    }
    END { exit bad }
  '; then
    echo -e "${RED}Links or special files are not allowed in archive: $archive${NC}"
    return 1
  fi
}

if [ -f "$BACKUP_FILE.sha256" ]; then
  echo "Verifying backup checksum..."
  (cd "$(dirname "$BACKUP_FILE")" && sha256sum -c "$(basename "$BACKUP_FILE").sha256")
else
  echo -e "${YELLOW}No checksum sidecar found; archive structure will still be validated.${NC}"
fi

validate_archive "$BACKUP_FILE"
tar xzf "$BACKUP_FILE" -C "$TEMP_DIR"
for nested_archive in "$TEMP_DIR"/data/*.tar.gz "$TEMP_DIR"/volumes/*.tar.gz; do
  [ -f "$nested_archive" ] && validate_archive "$nested_archive"
done
MANIFEST="$TEMP_DIR/manifest.json"
if [ ! -f "$MANIFEST" ] ||
  ! grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*2([,[:space:]}]|$)' "$MANIFEST"; then
  echo -e "${RED}This release requires a schema-v2 backup manifest.${NC}"
  exit 1
fi

BACKUP_MODE=$(sed -n 's/.*"backup_mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")
BACKUP_PROFILES=$(sed -n 's/.*"profiles"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")
if [ "$BACKUP_MODE" != "full" ] && [ "$BACKUP_MODE" != "hot" ]; then
  echo -e "${RED}Unsupported backup mode in manifest.${NC}"
  exit 1
fi

required_volumes() {
  case "$1" in
    proxy) echo "npm_data npm_letsencrypt" ;;
    docs)
      if [ "$BACKUP_MODE" = "hot" ]; then
        echo "paperless_data paperless_media"
      else
        echo "paperless_data paperless_media paperless_pgdata"
      fi
      ;;
    media) echo "jellyfin_config jellyfin_cache" ;;
    dns) echo "adguard_work adguard_conf" ;;
    passwords) echo "vaultwarden_data" ;;
    monitoring) echo "uptime_kuma_data" ;;
    vpn) echo "tailscale_data" ;;
    dashboard) echo "" ;;
    *) echo -e "${RED}Backup contains unsupported profile: $1${NC}" >&2; return 1 ;;
  esac
}

for profile in ${BACKUP_PROFILES//,/ }; do
  for volume in $(required_volumes "$profile"); do
    [ -s "$TEMP_DIR/volumes/$volume.tar.gz" ] ||
      { echo -e "${RED}Backup is missing required volume: $volume${NC}"; exit 1; }
  done
done
if [ "$BACKUP_MODE" = "hot" ] && [[ ",$BACKUP_PROFILES," == *",docs,"* ]] &&
  [ ! -s "$TEMP_DIR/volumes/paperless_db.dump" ]; then
  echo -e "${RED}Hot backup is missing the Paperless database dump.${NC}"
  exit 1
fi

echo "Privacy Stack restore"
echo "Mode: $BACKUP_MODE"
echo "Profiles: $BACKUP_PROFILES"
echo "Current containers and application data will be replaced."
if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type RESTORE to continue: " CONFIRMATION </dev/tty
  [ "$CONFIRMATION" = "RESTORE" ] || { echo "Restore cancelled."; exit 1; }
fi

cd "$INSTALL_DIR"
if [ "${PRIVACY_STACK_SKIP_HOST_SETUP:-0}" != "1" ]; then
  # shellcheck disable=SC1091
  . scripts/lib/platform.sh
  platform_install_prerequisites
  platform_install_docker
  bash scripts/protect-onboarding.sh
fi

docker compose down

if [ ! -f "$TEMP_DIR/config/.env" ]; then
  echo -e "${RED}Backup does not contain config/.env.${NC}"
  exit 1
fi
install -m 600 "$TEMP_DIR/config/.env" "$INSTALL_DIR/.env"
if [ -d "$TEMP_DIR/config/configs" ]; then
  cp -R "$TEMP_DIR/config/configs/." "$INSTALL_DIR/configs/"
fi

env_value() {
  sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | tail -1 | tr -d '\r'
}

PROFILES=$(env_value COMPOSE_PROFILES)
PROFILES="${PROFILES:-$BACKUP_PROFILES}"
PROJECT_NAME=$(env_value COMPOSE_PROJECT_NAME)
PROJECT_NAME="${PROJECT_NAME:-privacy-stack}"
DATA_DIR=$(env_value DATA_DIR)
DATA_DIR="${DATA_DIR:-/srv/privacy-stack}"
if ! [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo -e "${RED}Invalid Compose project name in backup.${NC}"
  exit 1
fi
[ "$PROFILES" = "$BACKUP_PROFILES" ] ||
  { echo -e "${RED}Manifest and .env profiles do not match.${NC}"; exit 1; }
case "$DATA_DIR" in
  ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    echo -e "${RED}Refusing unsafe DATA_DIR: $DATA_DIR${NC}"
    exit 1 ;;
esac

mkdir -p "$DATA_DIR"/{media,paperless/consume,paperless/export}
if [ -f "$TEMP_DIR/data/user-data.tar.gz" ]; then
  find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  tar xzf "$TEMP_DIR/data/user-data.tar.gz" -C "$DATA_DIR"
fi

docker compose create
shopt -s nullglob
for volume_archive in "$TEMP_DIR"/volumes/*.tar.gz; do
  volume=$(basename "$volume_archive" .tar.gz)
  full_volume="${PROJECT_NAME}_${volume}"
  docker volume inspect "$full_volume" >/dev/null
  docker run --rm \
    -v "$full_volume:/data" \
    -v "$volume_archive:/backup.tar.gz:ro" \
    alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce \
    sh -eu -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar xzf /backup.tar.gz -C /data'
  echo -e "  ${GREEN}$volume restored${NC}"
done

if [ "$BACKUP_MODE" = "hot" ] && [[ ",$PROFILES," == *",docs,"* ]]; then
  DUMP="$TEMP_DIR/volumes/paperless_db.dump"
  [ -s "$DUMP" ] || { echo -e "${RED}Hot backup is missing the Paperless database dump.${NC}"; exit 1; }
  docker compose up -d paperless-db
  for _ in $(seq 1 30); do
    docker exec paperless_db pg_isready --username postgres --dbname paperless >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec paperless_db pg_isready --username postgres --dbname paperless >/dev/null
  docker exec -i paperless_db pg_restore \
    --username postgres --dbname paperless --clean --if-exists --no-owner < "$DUMP"
fi

if [[ ",$PROFILES," == *",dns,"* ]] && ss -tlnp 2>/dev/null | grep -q ':53 '; then
  systemctl disable --now systemd-resolved 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi

docker compose up -d
echo -e "${GREEN}Restore complete.${NC}"
echo "Run: sudo bash scripts/test.sh"
echo "Then verify Tailscale SSH and resume the final lockdown:"
echo "  sudo bash setup-server.sh --resume"
