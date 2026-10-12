import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../backend.dart';
import '../display_list.dart';
import '../exceptions.dart';
import '../options.dart';
import '../ratex_base.dart';
import 'status.dart';

/// Returns the FFI backend (native platforms).
RatexBackend? createEngineBackend() => FfiBackend();

/// Locates and opens the `ratex_ffi` dynamic library.
class NativeLibrary {
  NativeLibrary._();

  static DynamicLibrary? _opened;

  static String get _fileName {
    if (Platform.isWindows) return 'ratex_ffi.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libratex_ffi.dylib';
    return 'libratex_ffi.so';
  }

  /// Tries each candidate location. Success is cached; failure is not, so a
  /// later attempt (e.g. after setting [Ratex.nativeLibraryPath] or building
  /// the crate) can succeed.
  static DynamicLibrary? open() {
    if (_opened != null) return _opened;
    for (final path in _candidates()) {
      try {
        _opened = DynamicLibrary.open(path);
        return _opened;
      } on Object {
        // Try the next candidate.
      }
    }
    // On Apple platforms the static library may be force-loaded into the
    // process (see the ratex podspecs); probe for our symbol.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        process.lookup('ratex_version_ptr');
        _opened = process;
      } on Object {
        // Not present in the process either.
      }
    }
    return _opened;
  }

  static Iterable<String> _candidates() sync* {
    final override = Ratex.nativeLibraryPath;
    if (override != null && override.isNotEmpty) yield override;
    final env = Platform.environment['RATEX_LIB'];
    if (env != null && env.isNotEmpty) yield env;
    // Resolved by the OS loader search path / the Flutter app bundle.
    yield _fileName;
    if (Platform.isMacOS || Platform.isIOS) {
      yield 'ratex.framework/ratex';
    }
    // Developer builds: walk up from the working directory looking for the
    // crate's build output (repo root, package dir, example dir, ...).
    var dir = Directory.current.absolute;
    for (var i = 0; i < 6; i++) {
      final base =
          '${dir.path}${Platform.pathSeparator}native'
          '${Platform.pathSeparator}ratex-ffi${Platform.pathSeparator}target';
      yield '$base${Platform.pathSeparator}release'
          '${Platform.pathSeparator}$_fileName';
      yield '$base${Platform.pathSeparator}debug'
          '${Platform.pathSeparator}$_fileName';
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
}

typedef _RenderC =
    Pointer<Void> Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef _RenderDart =
    Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Uint8>, int);

class _Bindings {
  _Bindings(DynamicLibrary lib)
    : alloc = lib
          .lookupFunction<
            Pointer<Uint8> Function(Size),
            Pointer<Uint8> Function(int)
          >('ratex_alloc'),
      free = lib
          .lookupFunction<
            Void Function(Pointer<Uint8>, Size),
            void Function(Pointer<Uint8>, int)
          >('ratex_free'),
      renderDisplayList = lib.lookupFunction<_RenderC, _RenderDart>(
        'ratex_render_display_list',
      ),
      renderSvg = lib.lookupFunction<_RenderC, _RenderDart>('ratex_render_svg'),
      bufferStatus = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('ratex_buffer_status'),
      bufferData = lib
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>),
            Pointer<Uint8> Function(Pointer<Void>)
          >('ratex_buffer_data'),
      bufferLen = lib
          .lookupFunction<
            Size Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('ratex_buffer_len'),
      bufferFree = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('ratex_buffer_free'),
      versionPtr = lib
          .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
            'ratex_version_ptr',
          ),
      versionLen = lib.lookupFunction<Size Function(), int Function()>(
        'ratex_version_len',
      );

  final Pointer<Uint8> Function(int) alloc;
  final void Function(Pointer<Uint8>, int) free;
  final _RenderDart renderDisplayList;
  final _RenderDart renderSvg;
  final int Function(Pointer<Void>) bufferStatus;
  final Pointer<Uint8> Function(Pointer<Void>) bufferData;
  final int Function(Pointer<Void>) bufferLen;
  final void Function(Pointer<Void>) bufferFree;
  final Pointer<Uint8> Function() versionPtr;
  final int Function() versionLen;
}

/// Renders over `dart:ffi` against the `ratex_ffi` dynamic library.
class FfiBackend implements RatexBackend {
  _Bindings? _bindings;

  @override
  String get name => 'ffi';

  @override
  int get priority => 100;

  // Only success is cached: a failed probe may succeed later (e.g. after
  // Ratex.nativeLibraryPath is set or the crate gets built).
  @override
  bool get isAvailable {
    if (_bindings != null) return true;
    try {
      final lib = NativeLibrary.open();
      if (lib == null) return false;
      _bindings = _Bindings(lib);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> initialize() async {
    if (!isAvailable) {
      throw const NoBackendAvailableException(
        'The ratex_ffi library could not be loaded. Build it with: '
        'cargo build --release --manifest-path native/ratex-ffi/Cargo.toml '
        '(or point RATEX_LIB / Ratex.nativeLibraryPath at it).',
      );
    }
  }

  @override
  String get engineVersion {
    final b = _requireBindings();
    return utf8.decode(b.versionPtr().asTypedList(b.versionLen()));
  }

  @override
  DisplayList renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    final json = _render(_requireBindings().renderDisplayList, latex, options);
    return DisplayList.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  String renderSvg(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    return _render(_requireBindings().renderSvg, latex, options);
  }

  @override
  Future<void> dispose() async {
    // The dynamic library stays loaded; there is nothing per-backend to
    // release.
  }

  _Bindings _requireBindings() {
    if (!isAvailable) {
      throw const NoBackendAvailableException();
    }
    return _bindings!;
  }

  /// Stages UTF-8 input through `ratex_alloc`, invokes [render], decodes the
  /// result buffer, and frees everything.
  String _render(_RenderDart render, String latex, RatexOptions options) {
    final b = _requireBindings();
    final input = utf8.encode(latex);
    final opts = utf8.encode(jsonEncode(options.toJson()));
    Pointer<Uint8> inputPtr = nullptr;
    Pointer<Uint8> optsPtr = nullptr;
    try {
      inputPtr = _stage(b, input);
      optsPtr = _stage(b, opts);
      final buffer = render(inputPtr, input.length, optsPtr, opts.length);
      try {
        final status = b.bufferStatus(buffer);
        final payload = utf8.decode(
          b.bufferData(buffer).asTypedList(b.bufferLen(buffer)),
        );
        if (status != 0) {
          throwForStatus(status, payload, input);
        }
        return payload;
      } finally {
        b.bufferFree(buffer);
      }
    } finally {
      // ratex_free ignores null pointers (never-staged buffers).
      b.free(inputPtr, input.length);
      b.free(optsPtr, opts.length);
    }
  }

  static Pointer<Uint8> _stage(_Bindings b, List<int> bytes) {
    if (bytes.isEmpty) return nullptr;
    final ptr = b.alloc(bytes.length);
    if (ptr == nullptr) {
      throw RatexInternalException(
        'ratex_alloc failed for ${bytes.length} bytes',
      );
    }
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return ptr;
  }
}
