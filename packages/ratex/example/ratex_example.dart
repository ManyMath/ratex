// Renders classic formulas to display lists and a self-contained SVG file.
//
// Build the native library first:
//   cargo build --release --manifest-path native/ratex-ffi/Cargo.toml
// then, from the repo root:
//   dart run packages/ratex/example/ratex_example.dart              # summary + quadratic.svg
//   dart run packages/ratex/example/ratex_example.dart '\sqrt{2}'  # render your own formula
//
// If the library is elsewhere, point to it with RATEX_LIB=/path/to/lib.

import 'dart:io';

import 'package:ratex/ratex.dart';

const _formulas = <String, String>{
  'Quadratic formula': r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}',
  'Euler identity': r'e^{i\pi} + 1 = 0',
  'Gaussian integral': r'\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}',
  'Basel problem': r'\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}',
  'Rotation matrix':
      r'\begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix}',
  'Chemistry (mhchem)': r'\ce{H2SO4 + 2NaOH -> Na2SO4 + 2H2O}',
};

Future<void> main(List<String> args) async {
  try {
    final backend = await Ratex.ensureInitialized();
    stdout.writeln(
      'Active backend: ${backend.name} (engine ${backend.engineVersion})\n',
    );
  } on NoBackendAvailableException catch (e) {
    stderr.writeln(e.message);
    exitCode = 2;
    return;
  }

  final custom = args.isNotEmpty ? args.join(' ') : null;
  final formulas = custom != null ? {'Your formula': custom} : _formulas;

  for (final MapEntry(key: name, value: latex) in formulas.entries) {
    try {
      final list = Ratex.renderDisplayListSync(latex);
      final glyphs = list.items.whereType<GlyphPathItem>().length;
      stdout.writeln('$name\n  $latex');
      stdout.writeln(
        '  ${list.width.toStringAsFixed(2)}em x '
        '${list.totalHeight.toStringAsFixed(2)}em, '
        '${list.items.length} items ($glyphs glyphs)\n',
      );
    } on RatexParseException catch (e) {
      stdout.writeln(
        '$name\n  $latex\n  parse error: ${e.message}'
        '${e.hasSpan ? ' (bytes ${e.start}..${e.end})' : ''}\n',
      );
    }
  }

  // Write one formula as a self-contained SVG (glyph outlines embedded, so
  // it renders correctly anywhere with no fonts installed).
  final svgFormula = custom ?? _formulas['Quadratic formula']!;
  final svg = Ratex.renderSvgSync(svgFormula);
  final out = File('quadratic.svg')..writeAsStringSync(svg);
  stdout.writeln(
    'Wrote ${out.path} (${svg.length} bytes), open it in any '
    'browser or image viewer.',
  );
}
