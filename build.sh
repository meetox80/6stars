#!/bin/zsh
set -e
cd "$(dirname "$0")"
ROOT="$HOME/testing/.cache"
mkdir -p "$ROOT/tmp" "$ROOT/clang" "$ROOT/swiftpm" "$ROOT/swiftpm-config" "$ROOT/swiftpm-security"
export TMPDIR="$ROOT/tmp/"
export CLANG_MODULE_CACHE_PATH="$ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/clang"
swift build -c release \
  --scratch-path "$PWD/.build" \
  --cache-path "$ROOT/swiftpm" \
  --config-path "$ROOT/swiftpm-config" \
  --security-path "$ROOT/swiftpm-security" \
  --manifest-cache local \
  "$@"
