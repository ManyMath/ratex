#!/usr/bin/env bash
# Builds ratex_ffi for wasm32-unknown-unknown and copies the binary where the
# web examples and apps expect it. Run from the repo root (melos does):
#   melos run native:build:web
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/native/ratex-ffi"
wasm="$crate/target/wasm32-unknown-unknown/release/ratex_ffi.wasm"

if ! rustup target list --installed --toolchain stable | grep -q wasm32-unknown-unknown; then
  echo "Installing the wasm32-unknown-unknown target for the stable toolchain..."
  rustup target add wasm32-unknown-unknown --toolchain stable
fi

(cd "$crate" && cargo build --release --target wasm32-unknown-unknown)

destinations=(
  "$root/packages/ratex/example/web/ratex_ffi.wasm"
  "$root/packages/ratex_flutter/example/assets/ratex_ffi.wasm"
  "$root/apps/ManyMath/assets/ratex_ffi.wasm"
)
for dest in "${destinations[@]}"; do
  mkdir -p "$(dirname "$dest")"
  cp "$wasm" "$dest"
  echo "Copied $(basename "$wasm") -> ${dest#"$root"/}"
done

echo "Done. ($(du -h "$wasm" | cut -f1), includes the embedded KaTeX fonts)"
