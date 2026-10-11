## 0.0.1

- Initial release.
- `RatexMath` widget: async engine init (synchronous rendering, with no
  loading frame, once initialized), `DefaultTextStyle` color inheritance,
  error/loading builders.
- `RatexMath` reports its baseline, so inline formulas align with text in
  baseline-aligned `Row`s and `WidgetSpan`s, and scales with the ambient
  `TextScaler` (override with `textScaler`).
- Accessibility: `RatexMath` announces a screen-reader label derived from the
  LaTeX source (override with `semanticLabel`); loading and error states are
  announced as live regions.
- `RatexPainter`: paints RaTeX display lists (glyphs via the bundled KaTeX
  fonts, referenced as `packages/ratex_flutter/<family>` so consuming apps
  need no font setup; lines/rects/paths natively).
- cargokit integration on Android, iOS, Linux, macOS, and Windows: the
  `ratex_ffi` crate builds automatically during `flutter build`. Rust is
  currently required; precompiled binaries are planned.
- Web support through the `ratex_dart` package's WebAssembly backend;
  `RatexFlutter.ensureInitialized` can load the binary from an asset.
- Re-exports the full `package:ratex_dart` API.
- Formula-playground example app (native + web).
