#!/usr/bin/env bash
# Builds ratex_ffi for wasm32-unknown-unknown and copies the binary where the
# web examples and apps expect it. Run from the repo root (melos does):
#   melos run native:build:web
#
# The module is built without the `system-fonts` feature (which would link
# web-sys and leave it with wasm-bindgen imports; there are no system fonts
# on the web anyway) under the size-tuned `wasm-release` profile, then
# shrunk with `wasm-opt -Oz` from binaryen when it is on PATH. The result
# has no imports: instantiate it with an empty import object.
# Set RATEX_REQUIRE_WASM_OPT=1 to fail instead of skipping wasm-opt.
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
built="$target_dir/wasm32-unknown-unknown/wasm-release/ratex_ffi.wasm"
wasm="$target_dir/wasm32-unknown-unknown/wasm-release/ratex_ffi.opt.wasm"

if ! rustup target list --installed --toolchain stable | grep -q wasm32-unknown-unknown; then
  echo "Installing the wasm32-unknown-unknown target for the stable toolchain..."
  rustup target add wasm32-unknown-unknown --toolchain stable
fi

(cd "$crate" && cargo build --profile wasm-release --no-default-features \
  --target wasm32-unknown-unknown)

if command -v wasm-opt >/dev/null; then
  # The features rustc's wasm32 target enables by default; the stripped
  # module has no target_features section for wasm-opt to read them from.
  wasm-opt -Oz \
    --enable-bulk-memory --enable-multivalue --enable-mutable-globals \
    --enable-nontrapping-float-to-int --enable-reference-types \
    --enable-sign-ext \
    -o "$wasm" "$built"
elif [ "${RATEX_REQUIRE_WASM_OPT:-}" = 1 ]; then
  echo "wasm-opt not found (install binaryen)" >&2
  exit 1
else
  echo "wasm-opt not found; skipping it (install binaryen for a smaller module)" >&2
  cp "$built" "$wasm"
fi

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
  echo "Copied ratex_ffi.wasm -> ${dest#"$root"/}"
done

bytes=$(wc -c <"$wasm")
gzipped=$(gzip -9c "$wasm" | wc -c)
echo "Done. ($bytes bytes, $gzipped gzipped; includes the embedded KaTeX fonts)"
