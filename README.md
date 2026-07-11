# ratex

KaTeX-compatible math rendering for Dart and Flutter with the goal of no
additional system dependencies for users or devs to install. The only build-
time requirement beyond Dart/Flutter is Rust, and precompiled binaries are
configured to obviate even that for Flutter consumers.

It wraps the Rust [RaTeX](https://github.com/erweixin/RaTeX) engine, a
KaTeX-compatible math typesetter in pure Rust (math, mhchem chemistry, proof
trees) with no system dependencies, so the same core cross-compiles to every
native target **and to WebAssembly**, giving the whole stack first-class web
support: one engine, one display-list protocol, every platform.

This is a [melos](https://melos.invertase.dev) monorepo:

| Package | What it is |
|---|---|
| [`packages/ratex`](packages/ratex) | Pure Dart (no Flutter); works in CLI tools and browsers. Renders LaTeX to display lists and self-contained SVG over `dart:ffi` natively and WebAssembly on the web, with a pluggable backend registry. |
| [`packages/ratex_flutter`](packages/ratex_flutter) | Flutter plugin. Builds the native library automatically (via cargokit), bundles the KaTeX fonts, provides the `RatexMath` widget and `RatexPainter`, and re-exports the `ratex` API. |
| [`native/ratex-ffi`](native/ratex-ffi) | Rust crate (the portable C ABI behind both backends). One `(pointer, length)`-based ABI compiled as cdylib/staticlib for FFI and as wasm32-unknown-unknown for the web, no wasm-bindgen glue. |
| [`apps/ManyMath`](apps/ManyMath) | A minimal LaTeX editor: plaintext LaTeX in, rendered document out, on demand. No accounts or persistence, the rendering core of ManyMath.com working end to end. |

## Quick start (Dart CLI)

```dart
import 'package:ratex/ratex.dart';

final list = await Ratex.renderDisplayList(r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}');
print(list); // DisplayList(14 items, 7.02em x 2.06em)
final svg = await Ratex.renderSvg(r'E = mc^2'); // self-contained, fonts embedded
```

Build the native library first: `cargo build --release --manifest-path native/ratex-ffi/Cargo.toml`.

## Quick start (Flutter)

```dart
import 'package:ratex_flutter/ratex_flutter.dart';

RatexMath(r'\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}', fontSize: 28)
```

No font setup, no manual native builds, cargokit compiles the crate during
`flutter build` on Android/iOS/Linux/macOS/Windows. For Flutter web, build
`ratex_ffi.wasm` once (`melos run native:build:web`) and serve it from your
app's `web/` directory.

### Runnable demos

```sh
# CLI: display-list summaries + a self-contained SVG file.
dart run packages/ratex/example/ratex_example.dart

# Browser (no Flutter): LaTeX -> SVG, all client-side.
melos run native:build:web
dart compile js packages/ratex/example/web/main.dart -o packages/ratex/example/web/main.dart.js
python3 -m http.server -d packages/ratex/example/web 8080

# Flutter: formula playground with presets and live editing.
cd packages/ratex_flutter/example && flutter run          # native
cd packages/ratex_flutter/example && flutter run -d chrome # web

# The LaTeX editor.
cd apps/ManyMath && flutter run -d chrome
```

## Status

| Host | Status |
|---|---|
| Linux | Working (native FFI, verified end to end) |
| Web | Working (WebAssembly, verified end to end, dart2js and Flutter web) |
| macOS | Expected to work (pure-Rust engine; cargokit wiring in place) |
| Windows | Expected to work (pure-Rust engine; cargokit wiring in place) |
| Android | Expected to work (pure-Rust engine; cargokit wiring in place) |
| iOS | Expected to work (pure-Rust engine; cargokit wiring in place) |

See [ROADMAP.md](ROADMAP.md) for what's next (isolate offload, PNG/PDF
export, precompiled binary releases, ManyMath.com integration).

## Development

Driven by [melos](https://melos.invertase.dev) (config lives in the root
`pubspec.yaml`). After `dart pub get`:

```sh
dart run melos run native:build       # build the Rust dylib (release)
dart run melos run native:build:web   # build ratex_ffi.wasm + copy to web examples
dart run melos run native:test        # Rust crate tests
dart run melos run analyze            # analyze all packages
dart run melos run format             # check Dart formatting (format:fix to apply)
dart run melos run test               # Dart + Flutter tests
```

Building the Rust crate requires a stable Rust toolchain with the
`wasm32-unknown-unknown` target for web builds (`rustup target add
wasm32-unknown-unknown`).

## Licenses

MIT (see [LICENSE](LICENSE)). The bundled KaTeX fonts are SIL OFL 1.1 (see
`packages/ratex_flutter/lib/fonts/`). RaTeX itself is MIT.
