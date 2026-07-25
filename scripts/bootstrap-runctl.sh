#!/bin/bash
# Build and launch runctl on a fresh Ubuntu host.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ "$EUID" -ne 0 ]; then
  echo "Please run this bootstrap with sudo."
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Preparing the installer..."
  if ! command -v snap >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq snapd >/dev/null
  fi
  snap install go --classic
  export PATH="/snap/bin:$PATH"
fi

mkdir -p bin
go build -o bin/runctl ./cmd/runctl

exec bin/runctl install privacy-stack --non-interactive "$@"
