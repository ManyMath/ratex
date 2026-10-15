import 'display_list.dart';
import 'options.dart';

/// A rendering engine implementation.
///
/// The package ships two: an FFI backend over the native `ratex_ffi` library
/// and a WebAssembly backend for the web, selected automatically. Register
/// your own with `Ratex.registerBackend` to override or extend (e.g. a
/// server-delegated renderer).
abstract class RatexBackend {
  /// Short identifier, e.g. `'ffi'` or `'wasm'`.
  String get name;

  /// Whether this backend can run here. Must be cheap and side-effect free;
  /// expensive setup belongs in [initialize].
  bool get isAvailable;

  /// Selection priority; the available backend with the highest value wins.
  int get priority;

  /// Performs one-time setup (loading the native library or fetching and
  /// instantiating the wasm binary). Must be idempotent.
  Future<void> initialize();

  /// Parses and lays out [latex], returning its display list.
  ///
  /// Throws [RatexParseException] for invalid LaTeX. Callers must
  /// [initialize] first; the [Ratex] statics do this automatically.
  DisplayList renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  });

  /// Parses, lays out, and renders [latex] to an SVG document.
  String renderSvg(String latex, {RatexOptions options = const RatexOptions()});

  /// Version string of the underlying engine library.
  String get engineVersion;

  /// Releases resources. The backend may be [initialize]d again afterwards.
  ///
  /// `Ratex.reset` disposes every initialized backend and forgets their
  /// initialization. Disposing a registered backend directly does not, so
  /// `Ratex` would keep treating it as ready; go through `Ratex.reset`.
  Future<void> dispose();
}
