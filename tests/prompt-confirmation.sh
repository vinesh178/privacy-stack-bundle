#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/prompts.sh"

output=$(
  printf '\nNOT-YET\nADGUARD\n' |
    confirm_exact "ADGUARD" "Confirm: " 2>&1
)
grep -Fq "Nothing was entered." <<< "$output"
grep -Fq "That did not match." <<< "$output"

if eof_output=$(confirm_exact "LOCKDOWN" "Confirm: " </dev/null 2>&1); then
  echo "Confirmation unexpectedly accepted EOF." >&2
  exit 1
fi
grep -Fq "Confirmation input closed; no changes were made." <<< "$eof_output"

echo "Confirmation prompt retry safety passed."
