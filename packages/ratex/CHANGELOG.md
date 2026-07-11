## 0.0.1

- Initial release.
- Core API: `Ratex` (backend registry + render calls), `RatexOptions`,
  `DisplayList`/`DisplayItem`/`PathCommand` models mirroring RaTeX's
  DisplayList JSON protocol v1 (unknown fields/variants tolerated),
  `RatexColor`, `KatexFontId`, exception hierarchy with parse-error source
  spans.
- FFI backend over the `ratex_ffi` Rust crate on native platforms
  (`RATEX_LIB` and `NativeLibrary.overridePath` overrides, dev-build path
  discovery, Apple `DynamicLibrary.process()` fallback).
- WebAssembly backend on the web: the same C ABI compiled to
  wasm32-unknown-unknown, loaded from `Ratex.wasmUrl`/`Ratex.wasmBytes` over
  `dart:js_interop` with no wasm-bindgen glue.
- Display-list and self-contained SVG rendering (glyph outlines embedded).
- CLI and browser examples.
