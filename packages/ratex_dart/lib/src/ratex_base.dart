import 'dart:typed_data';

import 'backend.dart';
import 'backends/engine_backend.dart';
import 'display_list.dart';
import 'exceptions.dart';
import 'options.dart';

/// Entry point: a registry of [RatexBackend]s and convenience render calls.
///
/// ```dart
/// final list = await Ratex.renderDisplayList(r'\frac{a}{b}');
/// final svg = await Ratex.renderSvg(r'E = mc^2');
/// ```
///
/// The default backend is FFI on native platforms and WebAssembly on the
/// web. After awaiting [ensureInitialized] once, the synchronous
/// [renderDisplayListSync]/[renderSvgSync] variants can be used (handy in
/// paint code).
abstract final class Ratex {
  static final List<RatexBackend> _backends = [];
  static final Map<RatexBackend, Future<void>> _initFutures = Map.identity();
  static final Set<RatexBackend> _initialized = Set.identity();
  static RatexBackend? _active;
  static bool _defaultsRegistered = false;

  /// On the web: URL the wasm backend fetches when [wasmBytes] is null.
  /// Relative URLs resolve against the page. Ignored on native platforms.
  static String wasmUrl = 'ratex_ffi.wasm';

  /// On the web: preloaded `ratex_ffi.wasm` bytes, taking precedence over
  /// [wasmUrl] (e.g. loaded from a Flutter asset bundle). Ignored on native
  /// platforms.
  static Uint8List? wasmBytes;

  /// On native platforms: explicit path to the `ratex_ffi` dynamic library,
  /// tried before every other candidate (the `RATEX_LIB` environment
  /// variable, the OS loader path, development build directories). Ignored
  /// on the web.
  static String? nativeLibraryPath;

  static void _ensureDefaults() {
    if (_defaultsRegistered) return;
    _defaultsRegistered = true;
    final backend = createEngineBackend();
    if (backend != null) {
      _backends.add(backend);
    }
  }

  /// Registered backends, in registration order.
  static List<RatexBackend> get backends {
    _ensureDefaults();
    return List.unmodifiable(_backends);
  }

  /// Registers [backend]; [makeActive] pins it immediately, otherwise
  /// selection re-runs on next use.
  static void registerBackend(RatexBackend backend, {bool makeActive = false}) {
    _ensureDefaults();
    _backends.add(backend);
    _active = makeActive ? backend : null;
  }

  /// The selected backend: the available one with the highest [priority].
  ///
  /// Throws [NoBackendAvailableException] when none applies.
  static RatexBackend get backend {
    _ensureDefaults();
    final active = _active;
    if (active != null) return active;
    final candidates = _backends.where((b) => b.isAvailable).toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
    if (candidates.isEmpty) {
      throw const NoBackendAvailableException();
    }
    return _active = candidates.first;
  }

  /// Pins the backend with [name]; throws [NoBackendAvailableException] when
  /// unknown.
  static void useBackend(String name) {
    _ensureDefaults();
    for (final b in _backends) {
      if (b.name == name) {
        _active = b;
        return;
      }
    }
    throw NoBackendAvailableException('No backend named "$name" registered.');
  }

  /// Whether the selected backend has finished [ensureInitialized], so the
  /// synchronous [renderDisplayListSync]/[renderSvgSync] variants can be
  /// used. False when no backend is available.
  static bool get isInitialized {
    try {
      return _initialized.contains(backend);
    } on NoBackendAvailableException {
      return false;
    }
  }

  /// Selects and initializes the backend (loads the native library, or
  /// fetches and instantiates the wasm binary). Idempotent and safe to call
  /// concurrently: overlapping callers share one initialization and none
  /// proceeds until it completes. Returns the ready backend.
  static Future<RatexBackend> ensureInitialized() async {
    final b = backend;
    var initialization = _initFutures[b];
    if (initialization == null) {
      late final Future<void> pending;
      pending = () async {
        try {
          // Future.sync turns a synchronous throw into a failed future, so
          // the catch below always runs after `pending` is registered.
          await Future<void>.sync(b.initialize);
          _initialized.add(b);
        } catch (_) {
          // Let a later call retry (e.g. after fixing Ratex.wasmUrl), unless
          // a reset() or newer attempt already replaced this entry.
          if (identical(_initFutures[b], pending)) _initFutures.remove(b);
          rethrow;
        }
      }();
      _initFutures[b] = initialization = pending;
    }
    await initialization;
    return b;
  }

  /// Renders [latex] to a [DisplayList], initializing the backend on first
  /// use.
  static Future<DisplayList> renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) async {
    final b = await ensureInitialized();
    return b.renderDisplayList(latex, options: options);
  }

  /// Renders [latex] to an SVG document, initializing the backend on first
  /// use.
  static Future<String> renderSvg(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) async {
    final b = await ensureInitialized();
    return b.renderSvg(latex, options: options);
  }

  /// Synchronous [renderDisplayList]; requires a prior [ensureInitialized].
  static DisplayList renderDisplayListSync(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    return _readyBackend().renderDisplayList(latex, options: options);
  }

  /// Synchronous [renderSvg]; requires a prior [ensureInitialized].
  static String renderSvgSync(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    return _readyBackend().renderSvg(latex, options: options);
  }

  static RatexBackend _readyBackend() {
    final b = backend;
    if (!_initialized.contains(b)) {
      throw StateError(
        'Ratex.ensureInitialized() must complete before synchronous '
        'rendering.',
      );
    }
    return b;
  }

  /// Disposes initialized backends and clears the registry and selection
  /// (used by tests).
  static Future<void> reset() async {
    // Snapshot first: an in-flight ensureInitialized may add to the set
    // while we await the disposals.
    final toDispose = List.of(_initialized);
    _initialized.clear();
    _initFutures.clear();
    _backends.clear();
    _active = null;
    _defaultsRegistered = false;
    for (final b in toDispose) {
      await b.dispose();
    }
  }
}
