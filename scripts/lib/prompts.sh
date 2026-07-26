#!/bin/bash
# Shared confirmation prompts for destructive or security-sensitive steps.

confirm_exact() {
  local expected=$1
  local prompt=$2
  local response

  while true; do
    if ! IFS= read -r -p "$prompt" response; then
      echo "" >&2
      echo "Confirmation input closed; no changes were made." >&2
      return 1
    fi

    if [ "$response" = "$expected" ]; then
      return 0
    fi

    if [ -z "$response" ]; then
      echo "Nothing was entered. Type $expected to continue, or press Ctrl+C to stop."
    else
      echo "That did not match. Type $expected to continue, or press Ctrl+C to stop."
    fi
  done
}
