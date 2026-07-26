#!/bin/bash
# Shared capability-based Linux platform helpers.

platform_preflight() {
  if [ "$(uname -s)" != "Linux" ]; then
    echo "This setup requires a Linux server."
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "This setup requires systemd."
    return 1
  fi
  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *)
      echo "Unsupported CPU architecture: $(uname -m)"
      return 1
      ;;
  esac
  if [ ! -f /etc/os-release ]; then
    echo "Could not identify this Linux distribution."
    return 1
  fi
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian|amzn) ;;
    *)
      echo "Supported distribution families: Ubuntu, Debian, and Amazon Linux."
      return 1
      ;;
  esac
  platform_package_manager >/dev/null
}

platform_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  else
    echo "No supported package manager found (apt, dnf, or yum)." >&2
    return 1
  fi
}

platform_install_prerequisites() {
  local manager
  manager=$(platform_package_manager)
  case "$manager" in
    apt)
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates coreutils curl git iproute2 iptables openssl util-linux >/dev/null
      ;;
    dnf)
      dnf install -y ca-certificates coreutils curl git iproute iptables openssl util-linux >/dev/null
      ;;
    yum)
      yum install -y ca-certificates coreutils curl git iproute iptables openssl util-linux >/dev/null
      ;;
  esac
}

platform_install_docker() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  else
    local manager distribution_id
    manager=$(platform_package_manager)
    distribution_id=""
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      distribution_id="${ID:-}"
    fi

    if [ "$distribution_id" = "amzn" ]; then
      "$manager" install -y docker >/dev/null
    else
      curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
  fi

  if ! docker compose version >/dev/null 2>&1; then
    local compose_arch
    case "$(uname -m)" in
      x86_64) compose_arch=x86_64 ;;
      aarch64|arm64) compose_arch=aarch64 ;;
    esac
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL \
      "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose v2 could not be installed."
    return 1
  fi
}
