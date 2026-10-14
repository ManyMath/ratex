# ratex_dart

KaTeX-compatible math rendering for Dart. Pure Dart (no Flutter dependency);
parses and lays out LaTeX with the Rust [RaTeX](https://github.com/erweixin/RaTeX)
engine, over `dart:ffi` on native platforms and **WebAssembly on the web**,
selected automatically by conditional imports.

Two outputs from one API:

- **Display lists**: the engine's flat list of drawing commands (glyphs,
  lines, rects, paths) in em units, for painting onto any canvas. This is what
  [`ratex`][ratex] draws.
- **Self-contained SVG**: glyph outlines embedded from the compiled-in KaTeX
  fonts, so math renders anywhere with no fonts installed or served.
  (Characters the KaTeX fonts lack, such as CJK or emoji in `\text{}`,
  still depend on system fonts.)

```dart
import 'dart:io';

import 'package:ratex_dart/ratex_dart.dart';

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
cargo build --release --manifest-path packages/ratex/rust/Cargo.toml
```

The loader finds it via `Ratex.nativeLibraryPath`, the `RATEX_LIB`
environment variable, the OS loader path / Flutter bundle, or the crate's
`target/` directory during development. (Flutter apps get all of this
automatically through `ratex` + cargokit.) These paths refer to this
monorepo; when using the package elsewhere, build the crate wherever you
vendor it and point `RATEX_LIB` or `Ratex.nativeLibraryPath` at the built
library.

## Web setup

Serve `ratex_ffi.wasm` (built with `dart run melos run native:build:web`) next
to your page, or point `Ratex.wasmUrl` at it, or hand the bytes to
`Ratex.wasmBytes`.
The same C ABI is compiled for `wasm32-unknown-unknown` and driven over JS
interop; there is no wasm-bindgen glue and no JavaScript math library.

## Errors

Parse failures throw `RatexParseException` with the engine's message and, when
known, the span of the offending input as string indices (`start`/`end`, ready
for `substring`), enough to build editor diagnostics.

## Examples

```sh
# CLI: display-list summaries + a self-contained SVG file.
dart run packages/ratex_dart/example/ratex_dart_example.dart

# Browser: LaTeX in, SVG out, all client-side.
dart run melos run native:build:web
dart compile js packages/ratex_dart/example/web/main.dart -o packages/ratex_dart/example/web/main.dart.js
python3 -m http.server -d packages/ratex_dart/example/web 8080
```

[ratex]: https://github.com/ManyMath/ratex/tree/main/packages/ratex
