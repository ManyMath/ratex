import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** The module under test: $RATEX_WASM, else the copy tool/build_wasm.sh makes. */
export const wasmPath =
  process.env.RATEX_WASM ?? fileURLToPath(new URL("../ratex_ffi.wasm", import.meta.url));

/**
 * Skip reason when the module has not been built, unless
 * RATEX_REQUIRE_WASM=1 (as in CI), where missing it fails the tests.
 */
export const skipUnlessBuilt =
  existsSync(wasmPath) || process.env.RATEX_REQUIRE_WASM === "1"
    ? false
    : `${wasmPath} not found; run tool/build_wasm.sh`;

/** Just enough of an Element for renderInto. */
export function fakeElement() {
  return { innerHTML: "" };
}
