# ratex

KaTeX-compatible mathematics rendering for Dart and Flutter. The Rust
[RaTeX](https://github.com/erweixin/RaTeX) engine handles mathematics, mhchem
chemistry, and proof trees. It runs through FFI on native platforms and
WebAssembly in browsers, using the same display-list format.

Native builds require Rust in addition to Dart or Flutter. Precompiled
binary releases are planned.

This is a [melos](https://melos.invertase.dev) monorepo:

| Package | What it is |
|---|---|
| [`packages/ratex_dart`](packages/ratex_dart) | Pure Dart (no Flutter); works in CLI tools and browsers. Renders LaTeX to display lists and self-contained SVG over `dart:ffi` natively and WebAssembly on the web, with a pluggable backend registry. |
| [`packages/ratex`](packages/ratex) | Flutter plugin. Builds the native library automatically (via cargokit), bundles the KaTeX fonts, provides the `RatexMath` widget and `RatexPainter`, and re-exports the `ratex_dart` API. |
| [`native/ratex-ffi`](native/ratex-ffi) | Rust crate (the portable C ABI behind both backends). One `(pointer, length)`-based ABI compiled as cdylib/staticlib for FFI and as wasm32-unknown-unknown for the web, no wasm-bindgen glue. |
| [`apps/ratex_example`](apps/ratex_example) | Minimal cross-platform Flutter application demonstrating one `RatexMath` expression without product state or external design-system dependencies. |

## Quick start (Dart CLI)

```dart
import 'package:ratex_dart/ratex_dart.dart';

final list = await Ratex.renderDisplayList(r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}');
print(list); // DisplayList(14 items, 7.02em x 2.28em)
final svg = await Ratex.renderSvg(r'E = mc^2'); // self-contained, fonts embedded
```

Build the native library first: `cargo build --release --manifest-path native/ratex-ffi/Cargo.toml`.

## Quick start (Flutter)

```dart
import 'package:ratex/ratex.dart';

RatexMath(r'\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}', fontSize: 28)
```

cargokit compiles the native library and bundles its fonts during
`flutter build` on Android/iOS/Linux/macOS/Windows. For Flutter web, build
`ratex_ffi.wasm` once (`melos run native:build:web`) and serve it from your
app's `web/` directory.

### Runnable demos

```sh
# CLI: display-list summaries + a self-contained SVG file.
dart run packages/ratex_dart/example/ratex_dart_example.dart

# Browser (no Flutter): LaTeX -> SVG, all client-side.
melos run native:build:web
dart compile js packages/ratex_dart/example/web/main.dart -o packages/ratex_dart/example/web/main.dart.js
python3 -m http.server -d packages/ratex_dart/example/web 8080

# Flutter: formula playground with presets and live editing.
cd packages/ratex/example && flutter run          # native
cd packages/ratex/example && flutter run -d chrome # web

# Minimal application integration.
cd apps/ratex_example && flutter run -d chrome
```

## Status

| Host | Status |
|---|---|
| Linux | Working (native FFI, verified end to end) |
| Web | Working (WebAssembly, verified end to end, dart2js and Flutter web) |
| macOS | Expected to work (pure-Rust engine; cargokit configured) |
| Windows | Expected to work (pure-Rust engine; cargokit configured) |
| Android | Expected to work (pure-Rust engine; cargokit configured) |
| iOS | Expected to work (pure-Rust engine; cargokit configured) |

Planned work includes rendering in an isolate, PNG/PDF export, precompiled
binaries, and upstream engine integration.

## Development

Driven by [melos](https://melos.invertase.dev) (config lives in the root
`pubspec.yaml`). The workspace includes the Flutter plugin and apps, so
working in this repository requires the Flutter SDK (which bundles Dart); a
standalone Dart SDK can't resolve it. The `ratex_dart` package itself has no
Flutter dependency, so projects that depend on it need only Dart.

After `flutter pub get`:

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
`packages/ratex/lib/fonts/`). RaTeX itself is MIT.
