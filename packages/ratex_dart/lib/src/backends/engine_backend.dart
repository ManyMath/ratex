import '../backend.dart';

// Selects the FFI implementation on native platforms and the WebAssembly
// implementation on the web, so importing `ratex_dart` never pulls in `dart:ffi`
// where it does not exist (nor `dart:js_interop` on the VM).
import 'engine_backend_ffi.dart'
    if (dart.library.js_interop) 'engine_backend_wasm.dart'
    as impl;

/// Returns the default engine backend for this platform, or `null` when none
/// applies.
RatexBackend? createEngineBackend() => impl.createEngineBackend();
