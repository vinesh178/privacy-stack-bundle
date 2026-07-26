#!/bin/bash
# ============================================================
# Privacy Stack — One-Line Installer
# Usage: curl -fsSL <url>/install.sh | sudo bash
#
# Environment variables (optional):
#   INSTALL_DIR  — where to install (default: /opt/privacy-stack)
#   BRANCH       — git branch/tag to checkout (default: main)
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/privacy-stack}"
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/vinesh178/privacy-stack-bundle.git}"

# Must be root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run with sudo: curl -sL <url>/install.sh | sudo bash${NC}"
  exit 1
fi

echo ""
echo "Privacy Stack — One-Line Installer"
echo "===================================="
echo ""

# Check platform capabilities needed to acquire the repository.
if [ "$(uname -s)" != "Linux" ] || ! command -v systemctl >/dev/null 2>&1; then
  echo -e "${RED}This installer requires a Linux server with systemd.${NC}"
  exit 1
fi

# Install git if missing
if ! command -v git &> /dev/null; then
  echo "Installing git..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq git >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git >/dev/null
  else
    echo -e "${RED}No supported package manager found (apt, dnf, or yum).${NC}"
    exit 1
  fi
fi

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing installation at $INSTALL_DIR..."
  cd "$INSTALL_DIR"
  git fetch origin
  git checkout "$BRANCH"
  git pull origin "$BRANCH"
else
  echo "Installing to $INSTALL_DIR..."
  git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

echo -e "${GREEN}Download complete.${NC}"
echo ""

# Hand off to the single supported fresh-server setup.
exec bash setup-server.sh
