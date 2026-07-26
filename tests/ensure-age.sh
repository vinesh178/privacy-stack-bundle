#!/bin/bash
# Install the pinned age test binary in an ignored repository-local directory.

AGE_TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGE_TEST_BIN="$AGE_TEST_ROOT/.test-bin"
AGE_VERSION=v1.3.1
if [ -x "$AGE_TEST_BIN/age" ] && [ -x "$AGE_TEST_BIN/age-plugin-batchpass" ]; then
  export PATH="$AGE_TEST_BIN:$PATH"
  return 0 2>/dev/null || exit 0
fi
if command -v age >/dev/null 2>&1 &&
  command -v age-plugin-batchpass >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    AGE_PLATFORM=linux-amd64
    AGE_SHA256=bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377 ;;
  Linux-aarch64|Linux-arm64)
    AGE_PLATFORM=linux-arm64
    AGE_SHA256=c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a ;;
  Darwin-x86_64)
    AGE_PLATFORM=darwin-amd64
    AGE_SHA256=2b233301ad21ab7b1eabd9ae1198a164005fa4928fcdd745d47c39f8593209d7 ;;
  Darwin-arm64)
    AGE_PLATFORM=darwin-arm64
    AGE_SHA256=01120ea2cbf0463d4c6bd767f99f3271bbed1cdc8a9aa718a76ba1fe4f01998b ;;
  *) echo "Unsupported age test platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$AGE_TEST_BIN"
AGE_ARCHIVE="$AGE_TEST_BIN/age.tar.gz"
curl -fsSL \
  "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-$AGE_PLATFORM.tar.gz" \
  -o "$AGE_ARCHIVE"
echo "$AGE_SHA256  $AGE_ARCHIVE" | sha256sum -c -
tar xzf "$AGE_ARCHIVE" --strip-components=1 -C "$AGE_TEST_BIN" \
  age/age age/age-plugin-batchpass
rm -f "$AGE_ARCHIVE"
export PATH="$AGE_TEST_BIN:$PATH"
