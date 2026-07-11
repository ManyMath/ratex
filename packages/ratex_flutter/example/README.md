# ratex_flutter_example

A formula playground for the `ratex_flutter` plugin: preset formulas, a
LaTeX editor with live rendering, a font-size slider, and a display/inline
toggle.

## Run (native)

cargokit builds the Rust crate automatically, Rust is the only extra
build-time requirement:

```sh
flutter run    # any of: -d linux, -d macos, -d windows, -d android, -d ios
```

## Run (web)

Build the wasm engine once, then run in Chrome:

```sh
melos run native:build:web   # drops ratex_ffi.wasm into web/
flutter run -d chrome
```
