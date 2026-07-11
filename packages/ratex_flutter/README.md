# ratex_flutter

KaTeX-compatible math rendering for Flutter, on every platform, including
the web. Wraps the pure-Dart [`ratex`](../ratex) package (which drives the
Rust [RaTeX](https://github.com/erweixin/RaTeX) engine) and adds:

- **`RatexMath`**: a widget that lays out a LaTeX formula and paints it with
  the bundled KaTeX fonts. Inherits the ambient text color; reports parse
  errors (with source spans) through `errorBuilder`.
- **`RatexPainter`**: the underlying `CustomPainter`, for painting display
  lists onto your own canvas.
- **Automatic native builds**: the `ratex_ffi` Rust crate is compiled by
  [cargokit](https://github.com/ManyMath/cargokit) during `flutter build` on
  Android, iOS, Linux, macOS, and Windows. Rust is the only extra build-time
  requirement, and precompiled binaries can remove even that.
- **Bundled fonts**: the KaTeX fonts ship with the package and are
  referenced as `packages/ratex_flutter/<family>`, so apps need **no** font
  configuration. (Fonts are SIL OFL 1.1; see `lib/fonts/`.)

```dart
import 'package:ratex_flutter/ratex_flutter.dart';

// Optional but recommended: eager init in main() so load errors surface
// early and all later renders are synchronous.
await RatexFlutter.ensureInitialized();

// Anywhere in your tree:
RatexMath(r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}', fontSize: 28)
```

The full `package:ratex` API is re-exported: `Ratex.renderDisplayList`,
`Ratex.renderSvg`, custom backends, options, and models.

## Web

Flutter web has no `dart:ffi`, so the same engine runs as WebAssembly:

1. Build the binary: `melos run native:build:web` (in this repo), or
   `cargo build --release --target wasm32-unknown-unknown` in
   `native/ratex-ffi`.
2. Serve `ratex_ffi.wasm` from your app's `web/` directory (files there ship
   verbatim with a web build), matching the default `Ratex.wasmUrl`. Or
   bundle it as an asset and pass `wasmAsset:` to
   `RatexFlutter.ensureInitialized`, or set `Ratex.wasmBytes` yourself.

## Example

[`example/`](example) is a formula playground: presets, live LaTeX editing,
font-size slider, display/inline toggle. `flutter run` on any platform
(see its README for the one-step web setup).
