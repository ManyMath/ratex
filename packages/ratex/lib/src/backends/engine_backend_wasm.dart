import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../backend.dart';
import '../display_list.dart';
import '../exceptions.dart';
import '../options.dart';
import '../ratex_base.dart';
import 'status.dart';

/// Returns the WebAssembly backend (web).
RatexBackend? createEngineBackend() => WasmBackend();

/// Renders against `ratex_ffi.wasm`: the same C ABI as the native library,
/// compiled for wasm32-unknown-unknown and driven over JS interop.
///
/// The binary comes from [Ratex.wasmBytes] when set (e.g. a Flutter asset),
/// otherwise it is fetched from [Ratex.wasmUrl].
class WasmBackend implements RatexBackend {
  JSObject? _module;
  JSObject? _exports;
  Future<void>? _restarting;

  @override
  String get name => 'wasm';

  @override
  int get priority => 100;

  // WebAssembly is universally available in the environments this file
  // compiles for; whether the binary can be loaded is discovered in
  // [initialize] (fetching is async, and isAvailable must stay cheap).
  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {
    if (_exports != null) return;
    final bytes = Ratex.wasmBytes ?? await _fetchBytes(Ratex.wasmUrl);
    try {
      final module = await _compileModule(bytes);
      final instance = await _instantiate(module);
      _module = module;
      _exports = instance.getProperty<JSObject>('exports'.toJS);
    } on Object catch (e) {
      // A raw JS CompileError here usually means the server sent something
      // other than the binary, e.g. an SPA fallback answering unknown
      // paths with index.html and HTTP 200.
      throw NoBackendAvailableException(
        'The ratex wasm binary could not be compiled/instantiated '
        '(fetched from "${Ratex.wasmBytes != null ? '<Ratex.wasmBytes>' : Ratex.wasmUrl}"). '
        'Check that the URL serves the ratex_ffi.wasm binary: $e',
      );
    }
  }

  static Future<Uint8List> _fetchBytes(String url) async {
    try {
      final response = await globalContext
          .callMethod<JSPromise<JSObject>>('fetch'.toJS, url.toJS)
          .toDart;
      final ok = response.getProperty<JSBoolean>('ok'.toJS).toDart;
      if (!ok) {
        final status = response.getProperty<JSNumber>('status'.toJS).toDartInt;
        throw NoBackendAvailableException(
          'Fetching "$url" failed with HTTP $status. Build the wasm binary '
          'with `melos run native:build:web` and serve it next to the page, '
          'or set Ratex.wasmUrl / Ratex.wasmBytes.',
        );
      }
      final buffer = await response
          .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
          .toDart;
      return buffer.toDart.asUint8List();
    } on RatexException {
      rethrow;
    } on Object catch (e) {
      throw NoBackendAvailableException(
        'Could not fetch the ratex wasm binary from "$url": $e',
      );
    }
  }

  static JSObject _webAssembly() =>
      globalContext.getProperty<JSObject>('WebAssembly'.toJS);

  /// Compiles off the main thread: browsers may refuse the synchronous
  /// `new WebAssembly.Module(bytes)` for modules this large (Chrome long
  /// capped it at 4 KB on the main thread).
  static Future<JSObject> _compileModule(Uint8List bytes) => _webAssembly()
      .callMethod<JSPromise<JSObject>>('compile'.toJS, bytes.toJS)
      .toDart;

  static JSFunction _throwingStub(String qualifiedName) {
    void stub() {
      throw StateError('unexpected wasm import call: $qualifiedName');
    }

    return stub.toJS;
  }

  /// Instantiates with throwing stubs for every declared import.
  ///
  /// The raw cargo-built module declares a handful of `__wbindgen_*` imports
  /// (dragged in by transitive system-font-discovery crates that are inert on
  /// the web); the render paths never invoke them, system font lookups fail
  /// gracefully inside the engine, so satisfying the instantiation-time link
  /// check is all that is needed.
  static Future<JSObject> _instantiate(JSObject module) async {
    final webAssembly = _webAssembly();
    final imports = webAssembly
        .getProperty<JSObject>('Module'.toJS)
        .callMethod<JSArray<JSObject>>('imports'.toJS, module);
    final importObject = JSObject();
    for (final entry in imports.toDart) {
      final moduleName = entry.getProperty<JSString>('module'.toJS).toDart;
      final importName = entry.getProperty<JSString>('name'.toJS).toDart;
      final namespace =
          importObject.getProperty<JSObject?>(moduleName.toJS) ?? JSObject();
      namespace.setProperty(
        importName.toJS,
        _throwingStub('$moduleName.$importName'),
      );
      importObject.setProperty(moduleName.toJS, namespace);
    }
    // WebAssembly.instantiate(Module, imports) resolves to the Instance
    // directly (only the bytes overload resolves to {module, instance}).
    return webAssembly
        .callMethod<JSPromise<JSObject>>(
          'instantiate'.toJS,
          module,
          importObject,
        )
        .toDart;
  }

  JSObject get _e {
    final exports = _exports;
    if (exports != null) return exports;
    if (_module != null) {
      _restart();
      throw const RatexInternalException(
        'The wasm engine is restarting after a failed call; try again.',
      );
    }
    throw StateError(
      'Ratex.ensureInitialized() must complete before rendering on the web.',
    );
  }

  /// Replaces the instance with a fresh one of the same module. A trap (an
  /// engine panic, or running out of memory) leaves the old instance
  /// unusable: its stack pointer stays wherever the trap happened. Calls
  /// made before the new instance is ready fail via [_e].
  void _restart() {
    _exports = null;
    final module = _module;
    if (module == null || _restarting != null) return;
    _restarting = _instantiate(module)
        .then((instance) {
          // Unless dispose() or a re-initialization replaced the module.
          if (identical(_module, module)) {
            _exports = instance.getProperty<JSObject>('exports'.toJS);
          }
        })
        .catchError((Object _) {
          // Left unavailable; the next call through [_e] retries.
        })
        .whenComplete(() => _restarting = null);
  }

  int _call(String name, List<JSAny?> args) =>
      _e.callMethodVarArgs<JSNumber>(name.toJS, args).toDartInt;

  void _callVoid(String name, List<JSAny?> args) =>
      _e.callMethodVarArgs<JSAny?>(name.toJS, args);

  /// A JS `Uint8Array` view over `[ptr, ptr + len)` of the instance's linear
  /// memory. Constructed fresh on every use: memory growth detaches previous
  /// buffers, and going through the JS constructor (rather than
  /// `JSArrayBuffer.toDart`) keeps reads *and writes* correct under both
  /// dart2js and dart2wasm, where `toDart` conversions may copy.
  JSUint8Array _view(int ptr, int len) {
    final buffer = _e
        .getProperty<JSObject>('memory'.toJS)
        .getProperty<JSObject>('buffer'.toJS);
    return globalContext
        .getProperty<JSFunction>('Uint8Array'.toJS)
        .callAsConstructor<JSUint8Array>(buffer, ptr.toJS, len.toJS);
  }

  Uint8List _read(int ptr, int len) => _view(ptr, len).toDart;

  void _write(int ptr, Uint8List bytes) {
    _view(
      ptr,
      bytes.length,
    ).callMethodVarArgs<JSAny?>('set'.toJS, [bytes.toJS]);
  }

  /// Copies [bytes] into wasm memory via `ratex_alloc`; returns the pointer.
  int _stage(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    final ptr = _call('ratex_alloc', [bytes.length.toJS]);
    if (ptr == 0) {
      throw RatexInternalException(
        'ratex_alloc failed for ${bytes.length} bytes',
      );
    }
    _write(ptr, bytes);
    return ptr;
  }

  String _renderCall(String export, String latex, RatexOptions options) {
    final input = utf8.encode(latex);
    final opts = utf8.encode(jsonEncode(options.toJson()));
    final exports = _e;
    try {
      return _engineCall(export, input, opts);
    } on RatexException {
      rethrow;
    } on Object catch (e) {
      // A JS RuntimeError from a trap, which no later call can recover from
      // on this instance (frees in the finally blocks may trap again).
      if (identical(_exports, exports)) _restart();
      throw RatexInternalException('The wasm engine failed: $e');
    }
  }

  String _engineCall(String export, Uint8List input, Uint8List opts) {
    var inputPtr = 0;
    var optsPtr = 0;
    try {
      inputPtr = _stage(input);
      optsPtr = _stage(opts);
      final buffer = _call(export, [
        inputPtr.toJS,
        input.length.toJS,
        optsPtr.toJS,
        opts.length.toJS,
      ]);
      try {
        final status = _call('ratex_buffer_status', [buffer.toJS]);
        final data = _call('ratex_buffer_data', [buffer.toJS]);
        final len = _call('ratex_buffer_len', [buffer.toJS]);
        final payload = utf8.decode(_read(data, len));
        if (status != 0) {
          throwForStatus(status, payload);
        }
        return payload;
      } finally {
        _callVoid('ratex_buffer_free', [buffer.toJS]);
      }
    } finally {
      if (inputPtr != 0) {
        _callVoid('ratex_free', [inputPtr.toJS, input.length.toJS]);
      }
      if (optsPtr != 0) {
        _callVoid('ratex_free', [optsPtr.toJS, opts.length.toJS]);
      }
    }
  }

  @override
  DisplayList renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    final json = _renderCall('ratex_render_display_list', latex, options);
    return DisplayList.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  String renderSvg(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    return _renderCall('ratex_render_svg', latex, options);
  }

  @override
  String get engineVersion {
    final ptr = _call('ratex_version_ptr', const []);
    final len = _call('ratex_version_len', const []);
    return utf8.decode(_read(ptr, len));
  }

  @override
  Future<void> dispose() async {
    _module = null;
    _exports = null;
  }
}
