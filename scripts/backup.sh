#!/bin/bash
# ============================================================
# Privacy Stack — Backup Script
# Usage:
#   sudo bash scripts/backup.sh                  # Full backup (stops containers)
#   sudo bash scripts/backup.sh --hot            # Hot backup (no downtime)
#   sudo bash scripts/backup.sh /path/to/file    # Custom output path
#   sudo bash scripts/backup.sh --hot /path/to   # Both
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
HOT_BACKUP=false
BACKUP_PATH=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --hot) HOT_BACKUP=true ;;
    *) BACKUP_PATH="$arg" ;;
  esac
done

# Must be root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run with sudo: sudo bash scripts/backup.sh${NC}"
  exit 1
fi

# Source .env
if [ -f "${INSTALL_DIR}/.env" ]; then
  set -a
  source "${INSTALL_DIR}/.env"
  set +a
else
  echo -e "${RED}.env not found. Run setup first.${NC}"
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-/srv/backups/privacy-stack}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="${BACKUP_PATH:-${BACKUP_DIR}/privacy-stack-${TIMESTAMP}.tar.gz}"
TEMP_DIR=$(mktemp -d)
PROFILES="${COMPOSE_PROFILES:-photos,docs,media,dns,passwords,monitoring,dashboard,vpn}"

mkdir -p "$BACKUP_DIR"
mkdir -p "${TEMP_DIR}/volumes"
mkdir -p "${TEMP_DIR}/data"
mkdir -p "${TEMP_DIR}/config"

has_profile() {
  [[ ",$PROFILES," == *",$1,"* ]]
}

echo ""
echo "Privacy Stack — Backup"
echo "======================"
echo "Mode: $([ "$HOT_BACKUP" = true ] && echo "Hot (no downtime)" || echo "Full (brief downtime)")"
echo "Output: ${BACKUP_PATH}"
echo ""

cd "$INSTALL_DIR"

# ---- Database dumps (for hot backup consistency) ----
if [ "$HOT_BACKUP" = true ]; then
  echo "Dumping databases..."

  if has_profile "photos"; then
    docker exec immich_postgres pg_dumpall -U "${IMMICH_DB_USER:-postgres}" \
      > "${TEMP_DIR}/volumes/immich_db.sql" 2>/dev/null && \
      echo -e "  ${GREEN}Immich DB dumped${NC}" || \
      echo -e "  ${YELLOW}Immich DB dump skipped (not running?)${NC}"
  fi

  if has_profile "docs"; then
    docker exec paperless_db pg_dumpall -U postgres \
      > "${TEMP_DIR}/volumes/paperless_db.sql" 2>/dev/null && \
      echo -e "  ${GREEN}Paperless DB dumped${NC}" || \
      echo -e "  ${YELLOW}Paperless DB dump skipped (not running?)${NC}"
  fi
else
  # Full backup — stop containers for consistency
  echo "Stopping containers..."
  docker compose stop
  echo -e "${GREEN}Containers stopped${NC}"
fi

# ---- Backup Docker named volumes ----
echo "Backing up volumes..."

# Map profiles to their volumes
declare -A PROFILE_VOLUMES
PROFILE_VOLUMES[photos]="immich_db immich_ml_cache"
PROFILE_VOLUMES[docs]="paperless_data paperless_media paperless_pgdata"
PROFILE_VOLUMES[media]="jellyfin_config jellyfin_cache"
PROFILE_VOLUMES[dns]="adguard_work adguard_conf"
PROFILE_VOLUMES[passwords]="vaultwarden_data"
PROFILE_VOLUMES[monitoring]="uptime_kuma_data"
PROFILE_VOLUMES[vpn]="tailscale_data"

# Always backup NPM
VOLUMES_TO_BACKUP="npm_data npm_letsencrypt"

# Add volumes for enabled profiles
for profile in ${PROFILES//,/ }; do
  if [ -n "${PROFILE_VOLUMES[$profile]}" ]; then
    VOLUMES_TO_BACKUP="${VOLUMES_TO_BACKUP} ${PROFILE_VOLUMES[$profile]}"
  fi
done

PROJECT_NAME=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="privacystackbundle"
fi

for vol in $VOLUMES_TO_BACKUP; do
  full_vol="${PROJECT_NAME}_${vol}"
  if docker volume inspect "$full_vol" &>/dev/null; then
    docker run --rm -v "${full_vol}:/data" -v "${TEMP_DIR}/volumes:/backup" \
      alpine tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null && \
      echo -e "  ${GREEN}${vol}${NC}" || \
      echo -e "  ${YELLOW}${vol} (empty or failed)${NC}"
  fi
done

# ---- Backup bind-mount data directories ----
echo "Backing up data directories..."

DATA_DIR="${DATA_DIR:-/srv/privacy-stack}"
if [ -d "$DATA_DIR" ]; then
  tar czf "${TEMP_DIR}/data/user-data.tar.gz" -C "$DATA_DIR" . 2>/dev/null && \
    echo -e "  ${GREEN}${DATA_DIR}${NC}" || \
    echo -e "  ${YELLOW}${DATA_DIR} (empty or failed)${NC}"
fi

# ---- Backup config files ----
echo "Backing up configuration..."
cp "${INSTALL_DIR}/.env" "${TEMP_DIR}/config/.env"
cp -r "${INSTALL_DIR}/configs" "${TEMP_DIR}/config/configs" 2>/dev/null || true
cp "${INSTALL_DIR}/docker-compose.yml" "${TEMP_DIR}/config/docker-compose.yml"

# ---- Create manifest ----
cat > "${TEMP_DIR}/manifest.json" << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "hostname": "$(hostname)",
  "profiles": "${PROFILES}",
  "data_dir": "${DATA_DIR}",
  "backup_mode": "$([ "$HOT_BACKUP" = true ] && echo "hot" || echo "full")",
  "volumes": "$(echo $VOLUMES_TO_BACKUP | tr ' ' ',')",
  "ubuntu_version": "$(lsb_release -rs 2>/dev/null || echo "unknown")"
}
EOF

# ---- Create final archive ----
echo "Creating archive..."
tar czf "$BACKUP_PATH" -C "$TEMP_DIR" .

# Cleanup temp
rm -rf "$TEMP_DIR"

# ---- Restart if we stopped ----
if [ "$HOT_BACKUP" != true ]; then
  echo "Restarting containers..."
  docker compose up -d
  echo -e "${GREEN}Containers restarted${NC}"
fi

BACKUP_SIZE=$(du -h "$BACKUP_PATH" | awk '{print $1}')

echo ""
echo -e "${GREEN}======================${NC}"
echo -e "${GREEN}Backup complete!${NC}"
echo -e "${GREEN}======================${NC}"
echo "  File: ${BACKUP_PATH}"
echo "  Size: ${BACKUP_SIZE}"
echo ""
echo "To restore on a new server:"
echo "  sudo bash scripts/restore.sh ${BACKUP_PATH}"
echo ""
