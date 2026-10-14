/// End-to-end tests against the real `ratex_ffi` native library.
///
/// Build it first:
///   cargo build --manifest-path packages/ratex/rust/Cargo.toml
/// Tests self-skip when the library is missing, as on a fresh checkout,
/// unless RATEX_REQUIRE_NATIVE=1 (set in CI) makes that a failure. Point
/// RATEX_LIB at the library if it lives somewhere unusual.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ratex_dart/ratex_dart.dart';
import 'package:test/test.dart';

bool get _nativeAvailable {
  try {
    return Ratex.backend.isAvailable;
  } on NoBackendAvailableException {
    return false;
  }
}

void main() {
  setUp(Ratex.reset);
  tearDown(Ratex.reset);

  Future<bool> ready() async {
    if (!_nativeAvailable) {
      if (Platform.environment['RATEX_REQUIRE_NATIVE'] == '1') {
        fail('ratex_ffi library not found and RATEX_REQUIRE_NATIVE=1');
      }
      markTestSkipped('ratex_ffi library not built');
      return false;
    }
    await Ratex.ensureInitialized();
    return true;
  }

  test('selects the ffi backend and reports the engine version', () async {
    if (!await ready()) return;
    expect(Ratex.backend.name, 'ffi');
    expect(Ratex.backend.engineVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  test('renders the quadratic formula to a display list', () async {
    if (!await ready()) return;
    final list = await Ratex.renderDisplayList(
      r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}',
    );
    expect(list.version, 1);
    expect(list.width, greaterThan(0));
    expect(list.totalHeight, greaterThan(0));
    expect(list.items, isNotEmpty);
    expect(list.items.whereType<GlyphPathItem>(), isNotEmpty);
    // The fraction bar and the radical's vinculum arrive as lines.
    expect(list.items.whereType<LineItem>(), isNotEmpty);
  });

  test('display style is larger than inline style', () async {
    if (!await ready()) return;
    const formula = r'\sum_{i=0}^{n} i^2';
    final display = Ratex.renderDisplayListSync(formula);
    final inline = Ratex.renderDisplayListSync(
      formula,
      options: const RatexOptions(displayMode: false),
    );
    expect(display.totalHeight, greaterThan(inline.totalHeight));
  });

  test('renders self-contained SVG', () async {
    if (!await ready()) return;
    final svg = await Ratex.renderSvg(r'E = mc^2');
    expect(svg, startsWith('<svg'));
    expect(svg, contains('</svg>'));
    // embedGlyphs (the default) inlines outlines; no font-dependent <text>.
    expect(svg, isNot(contains('<text')));
  });

  test('honors the color option', () async {
    if (!await ready()) return;
    final list = Ratex.renderDisplayListSync(
      'x',
      options: const RatexOptions(color: '#ff0000'),
    );
    final glyph = list.items.whereType<GlyphPathItem>().first;
    expect(glyph.color.r, closeTo(1.0, 1e-6));
    expect(glyph.color.g, closeTo(0.0, 1e-6));
  });

  test('reports parse errors with source spans', () async {
    if (!await ready()) return;
    expect(
      () => Ratex.renderDisplayListSync(r'\frac{a}{'),
      throwsA(
        isA<RatexParseException>()
            .having((e) => e.message, 'message', isNotEmpty)
            .having((e) => e.start, 'start', isNotNull),
      ),
    );
  });

  test('parse error spans index the Dart string', () async {
    if (!await ready()) return;
    const input = r'αβ + \undefinedmacro';
    try {
      Ratex.renderDisplayListSync(input);
      fail('expected a parse error');
    } on RatexParseException catch (e) {
      expect(e.hasSpan, isTrue);
      expect(input.substring(e.start!, e.end!), r'\undefinedmacro');
    }
  });

  test('rejects invalid colors as invalid input', () async {
    if (!await ready()) return;
    expect(
      () => Ratex.renderDisplayListSync(
        'x',
        options: const RatexOptions(color: 'not-a-color!'),
      ),
      throwsA(isA<RatexInvalidInputException>()),
    );
  });

  test('handles unicode input through text mode', () async {
    if (!await ready()) return;
    final list = Ratex.renderDisplayListSync(r'\text{勾股定理} + x^2');
    expect(list.items, isNotEmpty);
  });

  test('supports environments (matrices)', () async {
    if (!await ready()) return;
    final list = Ratex.renderDisplayListSync(
      r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
    );
    expect(list.items.whereType<GlyphPathItem>().length, greaterThan(4));
  });

  test('renders many formulas without breaking (memory discipline)', () async {
    if (!await ready()) return;
    for (var i = 0; i < 100; i++) {
      final list = Ratex.renderDisplayListSync('\\sum_{k=$i}^{n} k^{$i}');
      expect(list.items, isNotEmpty);
    }
  });
}
