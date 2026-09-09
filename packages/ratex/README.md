# ratex

KaTeX-compatible math rendering for Dart. Pure Dart (no Flutter dependency);
parses and lays out LaTeX with the Rust [RaTeX](https://github.com/erweixin/RaTeX)
engine, over `dart:ffi` on native platforms and **WebAssembly on the web**,
selected automatically by conditional imports.

Two outputs from one API:

- **Display lists**: the engine's flat list of drawing commands (glyphs,
  lines, rects, paths) in em units, for painting onto any canvas. This is what
  [`ratex_flutter`](../ratex_flutter) draws.
- **Self-contained SVG**: glyph outlines embedded from the compiled-in KaTeX
  fonts, so the output renders anywhere with no fonts installed or served.

```dart
import 'dart:io';

import 'package:ratex/ratex.dart';

final list = await Ratex.renderDisplayList(r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}');
print(list); // DisplayList(14 items, 7.02em x 2.28em)

final svg = await Ratex.renderSvg(r'E = mc^2');
File('einstein.svg').writeAsStringSync(svg);
```

After `await Ratex.ensureInitialized()`, the synchronous variants
(`Ratex.renderDisplayListSync`, `Ratex.renderSvgSync`) are available, handy
inside paint code.

## Native setup

Build the Rust library once (only build-time requirement is
[Rust](https://rustup.rs)):

```sh
cargo build --release --manifest-path native/ratex-ffi/Cargo.toml
```

The loader finds it via `Ratex.nativeLibraryPath`, the `RATEX_LIB`
environment variable, the OS loader path / Flutter bundle, or the crate's
`target/` directory during development. (Flutter apps get all of this
automatically through `ratex_flutter` + cargokit.) These paths refer to this
monorepo; when using the package elsewhere, build the crate wherever you
vendor it and point `RATEX_LIB` or `Ratex.nativeLibraryPath` at the built
library.

## Web setup

Serve `ratex_ffi.wasm` (built with `melos run native:build:web`) next to your
page, or point `Ratex.wasmUrl` at it, or hand the bytes to `Ratex.wasmBytes`.
The same C ABI is compiled for `wasm32-unknown-unknown` and driven over JS
interop; there is no wasm-bindgen glue and no JavaScript math library.

## Errors

Parse failures throw `RatexParseException` with the engine's message and, when
known, the span of the offending input as string indices (`start`/`end`, ready
for `substring`), enough to build editor diagnostics.

## Examples

```sh
# CLI: display-list summaries + a self-contained SVG file.
dart run packages/ratex/example/ratex_example.dart

# Browser: LaTeX in, SVG out, all client-side.
melos run native:build:web
dart compile js packages/ratex/example/web/main.dart -o packages/ratex/example/web/main.dart.js
python3 -m http.server -d packages/ratex/example/web 8080
```
