// Browser demo: LaTeX in, self-contained SVG out, all client-side.
//
// Build and serve from the repo root:
//   melos run native:build:web                       # ratex_ffi.wasm
//   dart compile js packages/ratex/example/web/main.dart \
//     -o packages/ratex/example/web/main.dart.js
//   python3 -m http.server -d packages/ratex/example/web 8080
// then open http://localhost:8080.

import 'dart:js_interop';

import 'package:ratex/ratex.dart';
import 'package:web/web.dart';

void main() {
  final input = document.querySelector('#input') as HTMLTextAreaElement;
  final button = document.querySelector('#render') as HTMLButtonElement;
  final displayMode =
      document.querySelector('#display-mode') as HTMLInputElement;
  final output = document.querySelector('#output') as HTMLDivElement;
  final status = document.querySelector('#status') as HTMLDivElement;

  Future<void> render() async {
    try {
      final started = DateTime.now();
      final svg = await Ratex.renderSvg(
        input.value,
        options: RatexOptions(displayMode: displayMode.checked),
      );
      final elapsed = DateTime.now().difference(started);
      output.innerHTML = svg.toJS;
      status.textContent =
          'Rendered in ${elapsed.inMilliseconds} ms '
          '(engine ${Ratex.backend.engineVersion}, '
          'backend ${Ratex.backend.name})';
      status.className = '';
    } on RatexParseException catch (e) {
      status.textContent = e.hasSpan
          ? 'Parse error at ${e.start}..${e.end}: ${e.message}'
          : 'Parse error: ${e.message}';
      status.className = 'error';
    } on RatexException catch (e) {
      status.textContent = e.message;
      status.className = 'error';
    }
  }

  button.onClick.listen((_) => render());
  input.onKeyDown.listen((event) {
    if (event.key == 'Enter' && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      render();
    }
  });

  // First paint with the pre-filled formula.
  render();
}
