# RaTeX Flutter example

This is a minimal cross-platform application that renders one expression with
`RatexMath`. It contains no product state or design-system
dependency.

From the Ratex repository root:

```sh
flutter pub get
flutter test apps/ratex_example/test

# The web target needs the engine as apps/ratex_example/web/ratex_ffi.wasm.
dart run melos run native:build:web
cd apps/ratex_example && flutter run -d chrome
```

Run `flutter run` from `apps/ratex_example`, not with `--target` from the
repository root. The root isn't this app's project, so Flutter would serve a
default `index.html` without the app's `web/` files, and the request for
`ratex_ffi.wasm` would fail.
