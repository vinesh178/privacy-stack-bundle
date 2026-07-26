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
        ca-certificates coreutils curl dnsutils git iproute2 iptables openssl util-linux >/dev/null
      ;;
    dnf)
      dnf install -y bind-utils ca-certificates coreutils curl git iproute iptables openssl util-linux >/dev/null
      ;;
    yum)
      yum install -y bind-utils ca-certificates coreutils curl git iproute iptables openssl util-linux >/dev/null
      ;;
  esac
}

platform_install_docker() {
  local docker_install_commit="5ce20f2eef3615d08fea941eda5a109e949e8ebf"
  local docker_install_sha256="b991f2806186f7287bb9e53362060c382e906d154599b2fb0982f34246bacfd4"
  local compose_version="v5.1.4"

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
      local docker_installer
      docker_installer=$(mktemp)
      curl -fsSL \
        "https://raw.githubusercontent.com/docker/docker-install/${docker_install_commit}/install.sh" \
        -o "$docker_installer"
      echo "$docker_install_sha256  $docker_installer" | sha256sum -c -
      sh "$docker_installer"
      rm -f "$docker_installer"
    fi
    systemctl enable --now docker
  fi

  if ! docker compose version >/dev/null 2>&1; then
    local compose_arch compose_sha256 compose_binary
    case "$(uname -m)" in
      x86_64)
        compose_arch=x86_64
        compose_sha256="33b208d7e76639db742fae84b966cc01dacae58ca3fc4dabbc907045aefdf0c4"
        ;;
      aarch64|arm64)
        compose_arch=aarch64
        compose_sha256="d4fb48b72857810314d3ee77123c89954101844efa4788031221f4c370495946"
        ;;
    esac
    mkdir -p /usr/local/lib/docker/cli-plugins
    compose_binary=/usr/local/lib/docker/cli-plugins/docker-compose
    curl -fsSL \
      "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${compose_arch}" \
      -o "$compose_binary"
    echo "$compose_sha256  $compose_binary" | sha256sum -c -
    chmod 0755 "$compose_binary"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose v2 could not be installed."
    return 1
  fi
}

platform_install_age() {
  local age_version="v1.3.1"
  local age_arch age_sha256 archive temp_dir

  if command -v age >/dev/null 2>&1 &&
    command -v age-plugin-batchpass >/dev/null 2>&1; then
    return 0
  fi

  case "$(uname -m)" in
    x86_64)
      age_arch=amd64
      age_sha256="bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377"
      ;;
    aarch64|arm64)
      age_arch=arm64
      age_sha256="c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a"
      ;;
    *) echo "Unsupported architecture for age: $(uname -m)" >&2; return 1 ;;
  esac

  temp_dir=$(mktemp -d)
  archive="$temp_dir/age.tar.gz"
  curl -fsSL \
    "https://github.com/FiloSottile/age/releases/download/${age_version}/age-${age_version}-linux-${age_arch}.tar.gz" \
    -o "$archive"
  echo "$age_sha256  $archive" | sha256sum -c -
  tar xzf "$archive" -C "$temp_dir"
  install -m 0755 "$temp_dir/age/age" /usr/local/bin/age
  install -m 0755 "$temp_dir/age/age-plugin-batchpass" /usr/local/bin/age-plugin-batchpass
  rm -rf "$temp_dir"
}
