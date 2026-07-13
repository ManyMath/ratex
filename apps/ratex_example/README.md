# Ratex Flutter example

This is a minimal cross-platform application that renders one expression with
`RatexMath`. It intentionally contains no product state or design-system
dependency.

From the Ratex repository root:

```sh
flutter pub get
flutter test apps/ratex_example/test
flutter run -d chrome --target apps/ratex_example/lib/main.dart
```

Run `./tool/build_wasm.sh` before starting the web target so
`apps/ratex_example/web/ratex_ffi.wasm` is available.
