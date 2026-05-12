#!/bin/bash
# ============================================================
# Privacy Stack — One-Line Installer
# Usage: curl -sL <url>/install.sh | sudo bash
#
# Environment variables (optional):
#   INSTALL_DIR  — where to install (default: /opt/privacy-stack)
#   BRANCH       — git branch/tag to checkout (default: main)
#   NON_INTERACTIVE=1 — skip wizard, use defaults
# ============================================================

set -e

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

# Check OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
    echo -e "${RED}Warning: This script is tested on Ubuntu/Debian. Your OS ($ID) may work but is unsupported.${NC}"
    echo "Continuing in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
  fi
fi

# Install git if missing
if ! command -v git &> /dev/null; then
  echo "Installing git..."
  apt-get update -qq && apt-get install -y -qq git > /dev/null
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

# Hand off to setup
if [ "${NON_INTERACTIVE}" = "1" ]; then
  exec bash scripts/setup.sh --non-interactive
else
  exec bash scripts/setup.sh
fi
