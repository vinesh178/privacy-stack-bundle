#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/env.sh"

cat > "$TEST_DIR/safe.env" <<EOF
SERVER_IP=\$(touch $TEST_DIR/executed)
COMPOSE_PROFILES=docs,vpn
EOF
load_privacy_env "$TEST_DIR/safe.env"
[ "$SERVER_IP" = "\$(touch $TEST_DIR/executed)" ]
[ ! -e "$TEST_DIR/executed" ]

printf 'BASH_ENV=/tmp/attacker\n' > "$TEST_DIR/unsafe.env"
if load_privacy_env "$TEST_DIR/unsafe.env" 2>/dev/null; then
  echo "Unsupported dotenv key was accepted." >&2
  exit 1
fi

echo "Dotenv parser safety passed."
