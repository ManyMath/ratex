/// Base class for all errors thrown by this package.
class RatexException implements Exception {
  const RatexException(this.message);

  final String message;

  @override
  String toString() => 'RatexException: $message';
}

/// The LaTeX input failed to parse.
class RatexParseException extends RatexException {
  const RatexParseException(super.message, {this.start, this.end});

  /// Index into the input string where the error begins, when known, in
  /// UTF-16 code units like `String.substring`.
  final int? start;

  /// Index into the input string where the error ends (exclusive), when
  /// known.
  final int? end;

  /// Whether the engine reported a source span for this error.
  bool get hasSpan => start != null && end != null;

  @override
  String toString() => hasSpan
      ? 'RatexParseException: $message (at $start..$end)'
      : 'RatexParseException: $message';
}

/// The arguments handed to the engine were invalid (bad options, bad color).
class RatexInvalidInputException extends RatexException {
  const RatexInvalidInputException(super.message);

  @override
  String toString() => 'RatexInvalidInputException: $message';
}

/// The engine failed internally; likely a bug worth reporting.
class RatexInternalException extends RatexException {
  const RatexInternalException(super.message);

  @override
  String toString() => 'RatexInternalException: $message';
}

/// No rendering backend can run in this environment.
class NoBackendAvailableException extends RatexException {
  const NoBackendAvailableException([
    super.message =
        'No ratex backend is available in this environment. On native '
        'platforms build the ratex_ffi library (cargo build --manifest-path '
        'native/ratex-ffi/Cargo.toml); on the web provide the ratex_ffi.wasm '
        'binary (see Ratex.wasmUrl / Ratex.wasmBytes).',
  ]);

  @override
  String toString() => 'NoBackendAvailableException: $message';
}
