#!/bin/bash
# ============================================================
# Privacy Stack — Restore Script
# Usage: sudo bash scripts/restore.sh /path/to/backup.tar.gz
#
# Works on both:
#   - Existing server (overwrites current data)
#   - Fresh server (installs Docker, restores everything)
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

BACKUP_FILE="$1"
INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -z "$BACKUP_FILE" ]; then
  echo -e "${RED}Usage: sudo bash scripts/restore.sh /path/to/backup.tar.gz${NC}"
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo -e "${RED}Backup file not found: ${BACKUP_FILE}${NC}"
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run with sudo${NC}"
  exit 1
fi

echo ""
echo "Privacy Stack — Restore"
echo "========================"
echo "Backup: ${BACKUP_FILE}"
echo ""

TEMP_DIR=$(mktemp -d)

# ---- Extract backup ----
echo "Extracting backup..."
tar xzf "$BACKUP_FILE" -C "$TEMP_DIR"

# ---- Read manifest ----
if [ -f "${TEMP_DIR}/manifest.json" ]; then
  echo "Backup info:"
  # Parse manifest with basic tools (no jq dependency)
  BACKUP_TS=$(grep -o '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' "${TEMP_DIR}/manifest.json" | cut -d'"' -f4)
  BACKUP_PROFILES=$(grep -o '"profiles"[[:space:]]*:[[:space:]]*"[^"]*"' "${TEMP_DIR}/manifest.json" | cut -d'"' -f4)
  BACKUP_DATA_DIR=$(grep -o '"data_dir"[[:space:]]*:[[:space:]]*"[^"]*"' "${TEMP_DIR}/manifest.json" | cut -d'"' -f4)
  echo "  Date:     ${BACKUP_TS}"
  echo "  Services: ${BACKUP_PROFILES}"
  echo "  Data dir: ${BACKUP_DATA_DIR}"
  echo ""
fi

# ---- Install Docker if needed ----
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing..."
  curl -fsSL https://get.docker.com | sh
  echo -e "${GREEN}Docker installed${NC}"
fi

# ---- Stop existing containers ----
cd "$INSTALL_DIR"
if docker compose ps -q 2>/dev/null | grep -q .; then
  echo "Stopping existing containers..."
  docker compose down 2>/dev/null || true
fi

# ---- Restore config files ----
echo "Restoring configuration..."
if [ -f "${TEMP_DIR}/config/.env" ]; then
  cp "${TEMP_DIR}/config/.env" "${INSTALL_DIR}/.env"
  echo -e "  ${GREEN}.env restored${NC}"
fi

if [ -d "${TEMP_DIR}/config/configs" ]; then
  cp -r "${TEMP_DIR}/config/configs"/* "${INSTALL_DIR}/configs/" 2>/dev/null || true
  echo -e "  ${GREEN}configs/ restored${NC}"
fi

if [ -f "${TEMP_DIR}/config/docker-compose.yml" ]; then
  cp "${TEMP_DIR}/config/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
  echo -e "  ${GREEN}docker-compose.yml restored${NC}"
fi

# ---- Source restored .env ----
if [ -f "${INSTALL_DIR}/.env" ]; then
  set -a
  source "${INSTALL_DIR}/.env"
  set +a
fi

DATA_DIR="${DATA_DIR:-/srv/privacy-stack}"
PROFILES="${COMPOSE_PROFILES:-${BACKUP_PROFILES:-photos,docs,media,dns,passwords,monitoring,dashboard,vpn}}"

# ---- Create data directories ----
echo "Creating data directories..."
mkdir -p "${DATA_DIR}"/{immich/upload,media,paperless/consume,paperless/export}

# ---- Restore bind-mount data ----
if [ -f "${TEMP_DIR}/data/user-data.tar.gz" ]; then
  echo "Restoring data files..."
  tar xzf "${TEMP_DIR}/data/user-data.tar.gz" -C "$DATA_DIR"
  echo -e "  ${GREEN}${DATA_DIR} restored${NC}"
fi

# ---- Restore Docker volumes ----
echo "Restoring Docker volumes..."

PROJECT_NAME=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="privacystackbundle"
fi

# Create volumes by briefly starting and stopping compose
docker compose create 2>/dev/null || true

for vol_archive in "${TEMP_DIR}/volumes/"*.tar.gz; do
  if [ -f "$vol_archive" ]; then
    vol_name=$(basename "$vol_archive" .tar.gz)
    full_vol="${PROJECT_NAME}_${vol_name}"

    # Create volume if it doesn't exist
    docker volume create "$full_vol" &>/dev/null || true

    docker run --rm -v "${full_vol}:/data" -v "${vol_archive}:/backup.tar.gz:ro" \
      alpine sh -c "cd /data && tar xzf /backup.tar.gz" 2>/dev/null && \
      echo -e "  ${GREEN}${vol_name}${NC}" || \
      echo -e "  ${YELLOW}${vol_name} (failed)${NC}"
  fi
done

# ---- Restore database dumps (from hot backups) ----
if [ -f "${TEMP_DIR}/volumes/immich_db.sql" ] || [ -f "${TEMP_DIR}/volumes/paperless_db.sql" ]; then
  echo "Restoring database dumps..."

  # Start just the database containers
  docker compose up -d immich-postgres paperless-db 2>/dev/null || true
  sleep 10

  if [ -f "${TEMP_DIR}/volumes/immich_db.sql" ]; then
    docker exec -i immich_postgres psql -U "${IMMICH_DB_USER:-postgres}" \
      < "${TEMP_DIR}/volumes/immich_db.sql" 2>/dev/null && \
      echo -e "  ${GREEN}Immich DB restored${NC}" || \
      echo -e "  ${YELLOW}Immich DB restore skipped${NC}"
  fi

  if [ -f "${TEMP_DIR}/volumes/paperless_db.sql" ]; then
    docker exec -i paperless_db psql -U postgres \
      < "${TEMP_DIR}/volumes/paperless_db.sql" 2>/dev/null && \
      echo -e "  ${GREEN}Paperless DB restored${NC}" || \
      echo -e "  ${YELLOW}Paperless DB restore skipped${NC}"
  fi
fi

# ---- Fix port 53 if AdGuard is enabled ----
if [[ ",$PROFILES," == *",dns,"* ]]; then
  if ss -tlnp 2>/dev/null | grep -q ':53 '; then
    echo "Freeing port 53 (systemd-resolved)..."
    systemctl disable systemd-resolved 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

# ---- Start everything ----
echo ""
echo "Starting containers..."
docker compose up -d

# ---- Cleanup ----
rm -rf "$TEMP_DIR"

# ---- Health check ----
echo ""
echo "Waiting for services to start..."
sleep 15

echo ""
echo -e "${GREEN}========================${NC}"
echo -e "${GREEN}Restore complete!${NC}"
echo -e "${GREEN}========================${NC}"
echo ""
echo "Run the health check to verify:"
echo "  bash scripts/test.sh"
echo ""
