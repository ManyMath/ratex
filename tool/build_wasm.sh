#!/usr/bin/env bash
# Builds ratex_ffi for wasm32-unknown-unknown and copies the binary where the
# web examples and apps expect it. Run from the repo root (melos does):
#   melos run native:build:web
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/packages/ratex/rust"

# Honor CARGO_TARGET_DIR. Cargo resolves a relative value against the
# directory it runs in, which is the crate directory (see below).
target_dir="${CARGO_TARGET_DIR:-target}"
case "$target_dir" in
  /*) ;;
  *) target_dir="$crate/$target_dir" ;;
esac
wasm="$target_dir/wasm32-unknown-unknown/release/ratex_ffi.wasm"

if ! rustup target list --installed --toolchain stable | grep -q wasm32-unknown-unknown; then
  echo "Installing the wasm32-unknown-unknown target for the stable toolchain..."
  rustup target add wasm32-unknown-unknown --toolchain stable
fi

(cd "$crate" && cargo build --release --target wasm32-unknown-unknown)

# The Flutter apps serve the binary from their web/ directory (everything in
# web/ ships verbatim with a Flutter web build), matching the default
# Ratex.wasmUrl of 'ratex_ffi.wasm'; native builds are unaffected.
destinations=(
  "$root/packages/ratex_dart/example/web/ratex_ffi.wasm"
  "$root/packages/ratex/example/web/ratex_ffi.wasm"
  "$root/apps/ratex_example/web/ratex_ffi.wasm"
)
for dest in "${destinations[@]}"; do
  mkdir -p "$(dirname "$dest")"
  cp "$wasm" "$dest"
  echo "Copied $(basename "$wasm") -> ${dest#"$root"/}"
done

echo "Done. ($(du -h "$wasm" | cut -f1), includes the embedded KaTeX fonts)"
