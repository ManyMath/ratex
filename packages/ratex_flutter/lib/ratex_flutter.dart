/// KaTeX-compatible math rendering for Flutter.
///
/// Re-exports the full `package:ratex` API and adds [RatexMath] (the formula
/// widget), [RatexPainter] (paint display lists yourself), and
/// [RatexFlutter.ensureInitialized] (eager engine setup with web wasm
/// loading).
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:ratex/ratex.dart';

export 'package:ratex/ratex.dart';

export 'src/ratex_math.dart';
export 'src/ratex_painter.dart';

/// Flutter-side conveniences over the `ratex` engine registry.
abstract final class RatexFlutter {
  /// Initializes the rendering engine eagerly and returns the active
  /// backend's name (`'ffi'` on native platforms, `'wasm'` on the web).
  ///
  /// Calling this early (e.g. from `main`) surfaces load errors at startup
  /// and makes every subsequent render synchronous; otherwise the first
  /// [RatexMath] triggers the same setup lazily.
  ///
  /// On the web the engine binary loads, in order of precedence, from
  /// [Ratex.wasmBytes] if already set, then a bundle asset when [wasmAsset]
  /// is given (declare the file under `flutter: assets:` yourself), then the
  /// [Ratex.wasmUrl] fetch, which defaults to `ratex_ffi.wasm` served next
  /// to the page: drop the binary into your app's `web/` directory (the
  /// repo's `melos run native:build:web` does this for the in-repo apps).
  static Future<String> ensureInitialized({
    String? wasmAsset,
    AssetBundle? bundle,
  }) async {
    if (kIsWeb && wasmAsset != null && Ratex.wasmBytes == null) {
      // Asset loading needs the binding; the docs recommend calling this
      // from main(), which may be before runApp.
      WidgetsFlutterBinding.ensureInitialized();
      final data = await (bundle ?? rootBundle).load(wasmAsset);
      Ratex.wasmBytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    }
    final backend = await Ratex.ensureInitialized();
    return backend.name;
  }
}
