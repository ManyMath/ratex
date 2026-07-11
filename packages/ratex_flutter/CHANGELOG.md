## 0.0.1

- Initial release.
- `RatexMath` widget: async engine init, synchronous re-renders,
  `DefaultTextStyle` color inheritance, error/loading builders.
- `RatexPainter`: paints RaTeX display lists (glyphs via the bundled KaTeX
  fonts, referenced as `packages/ratex_flutter/<family>` so consuming apps
  need no font setup; lines/rects/paths natively).
- cargokit integration on Android, iOS, Linux, macOS, and Windows: the
  `ratex_ffi` crate builds automatically during `flutter build`, with
  precompiled-binary support configured.
- Web support through the `ratex` package's WebAssembly backend;
  `RatexFlutter.ensureInitialized` can load the binary from an asset.
- Re-exports the full `package:ratex` API.
- Formula-playground example app (native + web).
