import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ratex/ratex.dart';

/// A backend that returns a canned display list and records the options it
/// was called with, no native library involved.
class _FakeBackend implements RatexBackend {
  RatexOptions? lastOptions;
  String? lastLatex;
  int renderCalls = 0;
  bool initialized = false;
  Completer<void>? initializationGate;

  static const _list = DisplayList(
    items: [
      GlyphPathItem(
        x: 0,
        y: 1,
        color: RatexColor.black,
        scale: 1,
        font: 'Math-Italic',
        charCode: 0x78,
      ),
      LineItem(
        x: 0,
        y: 1.2,
        color: RatexColor.black,
        width: 2,
        thickness: 0.05,
      ),
    ],
    width: 2,
    height: 1,
    depth: 0.5,
  );

  @override
  String get name => 'fake';

  @override
  bool get isAvailable => true;

  @override
  int get priority => 10000;

  @override
  Future<void> initialize() async {
    initialized = true;
    await initializationGate?.future;
  }

  @override
  Future<void> dispose() async {}

  @override
  String get engineVersion => '0.0.0-fake';

  @override
  DisplayList renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    renderCalls++;
    lastLatex = latex;
    lastOptions = options;
    if (latex.contains(r'\bad')) {
      throw const RatexParseException(
        'Undefined control sequence: \\bad',
        start: 0,
        end: 4,
      );
    }
    return _list;
  }

  @override
  String renderSvg(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) => '<svg xmlns="http://www.w3.org/2000/svg"/>';
}

void main() {
  late _FakeBackend fake;

  setUp(() async {
    await Ratex.reset();
    fake = _FakeBackend();
    Ratex.registerBackend(fake, makeActive: true);
  });

  tearDown(Ratex.reset);

  group('RatexFlutter.ensureInitialized', () {
    test('initializes and reports the backend name', () async {
      expect(await RatexFlutter.ensureInitialized(), 'fake');
      expect(fake.initialized, isTrue);
    });
  });

  group('RatexMath', () {
    testWidgets('renders a formula as a sized CustomPaint', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: RatexMath('x', fontSize: 20))),
      );
      await tester.pumpAndSettle();

      expect(fake.lastLatex, 'x');
      final paint = find.byType(CustomPaint).last;
      expect(paint, findsOneWidget);
      final box = tester.getSize(
        find.ancestor(of: paint, matching: find.byType(SizedBox)).first,
      );
      // width 2em * 20px, height (1 + 0.5)em * 20px.
      expect(box.width, 40);
      expect(box.height, 30);
    });

    testWidgets('paints on the first frame once the engine is initialized', (
      tester,
    ) async {
      await Ratex.ensureInitialized();
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: RatexMath('x', fontSize: 20))),
      );

      // No further pump: the first frame already shows the formula.
      expect(
        find.descendant(
          of: find.byType(RatexMath),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(RatexMath)), const Size(40, 30));
    });

    testWidgets('shows errors on the first frame once initialized', (
      tester,
    ) async {
      await Ratex.ensureInitialized();
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: RatexMath(r'\bad{'))),
      );

      expect(find.textContaining('Undefined control sequence'), findsOneWidget);
    });

    testWidgets('reports its baseline for baseline alignment', (tester) async {
      const small = Key('small');
      const large = Key('large');
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                RatexMath('x', key: small, fontSize: 20),
                RatexMath('x', key: large, fontSize: 40),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Each baseline sits 1em (the list's height) below the top edge, so
      // aligned baselines put the smaller formula's top 20px lower.
      expect(
        tester.getTopLeft(find.byKey(small)).dy -
            tester.getTopLeft(find.byKey(large)).dy,
        20,
      );
    });

    testWidgets('scales with the ambient text scaler', (tester) async {
      const scaled = Key('scaled');
      const fixed = Key('fixed');
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Column(
              children: [
                RatexMath('x', key: scaled, fontSize: 20),
                RatexMath(
                  'x',
                  key: fixed,
                  fontSize: 20,
                  textScaler: TextScaler.noScaling,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byKey(scaled)), const Size(80, 60));
      expect(tester.getSize(find.byKey(fixed)), const Size(40, 30));
    });

    testWidgets('passes displayMode and inherited color to the engine', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DefaultTextStyle(
            style: TextStyle(color: Color(0xffff0000)),
            child: RatexMath('x', displayMode: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fake.lastOptions?.displayMode, isFalse);
      expect(fake.lastOptions?.color, '#ff0000ff');
    });

    testWidgets('re-renders when the formula changes', (tester) async {
      Widget app(String latex) =>
          MaterialApp(home: Center(child: RatexMath(latex)));
      await tester.pumpWidget(app('x'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app('y'));
      await tester.pumpAndSettle();
      expect(fake.lastLatex, 'y');
    });

    testWidgets('a superseded failure keeps the newer render cached', (
      tester,
    ) async {
      fake.initializationGate = Completer<void>();
      Widget app(String latex, double textSize) => MaterialApp(
        home: DefaultTextStyle(
          style: TextStyle(color: const Color(0xff000000), fontSize: textSize),
          child: RatexMath(latex),
        ),
      );
      // Both renders wait on initialization; the first then fails after the
      // second has superseded it.
      await tester.pumpWidget(app(r'\bad{', 14));
      await tester.pumpWidget(app('x', 14));
      fake.initializationGate!.complete();
      await tester.pumpAndSettle();
      expect(fake.renderCalls, 2);
      expect(find.textContaining('Undefined'), findsNothing);

      // A dependency change with unchanged render inputs reuses the result.
      await tester.pumpWidget(app('x', 16));
      await tester.pumpAndSettle();
      expect(fake.renderCalls, 2);
    });

    testWidgets('repaints when system fonts change', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: RatexMath('x'))),
      );
      await tester.pumpAndSettle();
      final paint = tester.renderObject<RenderCustomPaint>(
        find.descendant(
          of: find.byType(RatexMath),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(paint.debugNeedsPaint, isFalse);

      // Sent by the engine when, e.g., a lazily loaded fallback font arrives.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.system.name,
        SystemChannels.system.codec.encodeMessage(<String, Object?>{
          'type': 'fontsChange',
        }),
        (_) {},
      );
      expect(paint.debugNeedsPaint, isTrue);
    });

    testWidgets('derives a concise semantic label from the LaTeX source', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Center(child: RatexMath('  x^2  +\n  y^2  ')),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(find.byType(RatexMath)),
          matchesSemantics(label: 'Mathematical expression: x^2 + y^2'),
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('uses a caller-provided semantic label for the formula', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: RatexMath(
              r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}',
              semanticLabel: 'The quadratic formula',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(find.byType(RatexMath)),
          matchesSemantics(label: 'The quadratic formula'),
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('announces loading as a live region', (tester) async {
      final semantics = tester.ensureSemantics();
      fake.initializationGate = Completer<void>();
      try {
        await tester.pumpWidget(
          MaterialApp(home: RatexMath('x', semanticLabel: 'Variable x')),
        );
        await tester.pump();

        expect(
          tester.getSemantics(find.byType(RatexMath)),
          matchesSemantics(label: 'Rendering Variable x', isLiveRegion: true),
        );
      } finally {
        fake.initializationGate!.complete();
        await tester.pumpAndSettle();
        semantics.dispose();
      }
    });

    testWidgets('shows the default error presentation for parse errors', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          const MaterialApp(home: Center(child: RatexMath(r'\bad{'))),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Undefined control sequence'),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.byType(RatexMath)),
          matchesSemantics(
            label:
                r'Could not render mathematical expression: \bad{. '
                r'Undefined control sequence: \bad',
            isLiveRegion: true,
          ),
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('uses a custom errorBuilder when provided', (tester) async {
      final semantics = tester.ensureSemantics();
      var retried = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RatexMath(
              r'\bad{',
              errorBuilder: (context, error) => TextButton(
                onPressed: () => retried = true,
                child: Text('Retry: ${error.message}'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final retry = find.textContaining('Retry: Undefined');
        expect(retry, findsOneWidget);
        expect(
          tester.getSemantics(retry),
          isSemantics(
            label: r'Retry: Undefined control sequence: \bad',
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        await tester.tap(retry);
        expect(retried, isTrue);
      } finally {
        semantics.dispose();
      }
    });
  });

  group('RatexPainter', () {
    // Every non-fallback font ID RaTeX emits (ratex-font's FontId).
    const engineFontIds = [
      'AMS-Regular',
      'Caligraphic-Regular',
      'Fraktur-Bold',
      'Fraktur-Regular',
      'Main-Bold',
      'Main-BoldItalic',
      'Main-Italic',
      'Main-Regular',
      'Math-BoldItalic',
      'Math-Italic',
      'SansSerif-Bold',
      'SansSerif-Italic',
      'SansSerif-Regular',
      'Script-Regular',
      'Size1-Regular',
      'Size2-Regular',
      'Size3-Regular',
      'Size4-Regular',
      'Typewriter-Regular',
    ];

    test('maps each font ID to its own bundled family', () {
      expect(
        RatexPainter.fontFamilyFor('Math-Italic'),
        'packages/ratex/KaTeX_Math-Italic',
      );
      expect(
        RatexPainter.fontFamilyFor('Main-BoldItalic'),
        'packages/ratex/KaTeX_Main-BoldItalic',
      );
      for (final fallback in [
        'CJK-Regular',
        'CJK-Fallback',
        'Emoji-Fallback',
      ]) {
        expect(RatexPainter.fontFamilyFor(fallback), isNull);
      }
    });

    test('the pubspec declares a family for every engine font ID', () {
      // Tests run from the package or, in CI, from the repository root.
      final dir = [
        '.',
        'packages/ratex',
      ].firstWhere((d) => File('$d/lib/src/ratex_painter.dart').existsSync());
      final pubspec = File('$dir/pubspec.yaml').readAsStringSync();
      for (final id in engineFontIds) {
        expect(
          pubspec,
          contains(
            '- family: KaTeX_$id\n'
            '      fonts:\n'
            '        - asset: lib/fonts/KaTeX_$id.ttf\n',
          ),
          reason: id,
        );
        expect(
          File('$dir/lib/fonts/KaTeX_$id.ttf').existsSync(),
          isTrue,
          reason: id,
        );
      }
    });

    testWidgets('paints a display list without errors', (tester) async {
      final painter = RatexPainter(
        DisplayList.fromJson({
          'width': 3.0,
          'height': 1.0,
          'depth': 0.2,
          'items': [
            {
              'type': 'GlyphPath',
              'x': 0.0,
              'y': 1.0,
              'scale': 1.0,
              'font': 'Main-Regular',
              'char_code': 0x2211,
              'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
            },
            {
              'type': 'Line',
              'x': 0.0,
              'y': 1.1,
              'width': 3.0,
              'thickness': 0.04,
              'dashed': true,
              'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
            },
            {
              'type': 'Rect',
              'x': 1.0,
              'y': 0.0,
              'width': 0.5,
              'height': 0.5,
              'color': {'r': 1, 'g': 0, 'b': 0, 'a': 1},
            },
            {
              'type': 'Path',
              'x': 0.2,
              'y': 0.2,
              'fill': false,
              'commands': [
                {'type': 'MoveTo', 'x': 0.0, 'y': 0.0},
                {'type': 'LineTo', 'x': 1.0, 'y': 0.0},
                {'type': 'QuadTo', 'x1': 1.5, 'y1': 0.5, 'x': 1.0, 'y': 1.0},
                {
                  'type': 'CubicTo',
                  'x1': 0.6,
                  'y1': 1.2,
                  'x2': 0.3,
                  'y2': 1.2,
                  'x': 0.0,
                  'y': 1.0,
                },
                {'type': 'Close'},
              ],
              'color': {'r': 0, 'g': 0, 'b': 1, 'a': 1},
            },
          ],
        }),
        fontSize: 24,
      );

      expect(painter.widthPx, 72);
      expect(painter.totalHeightPx, closeTo(28.8, 1e-9));

      await tester.pumpWidget(
        MaterialApp(
          home: CustomPaint(
            painter: painter,
            size: Size(painter.widthPx, painter.totalHeightPx),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    test('fills each subpath separately but strokes paths whole', () {
      int drawPathCalls({required bool fill}) {
        final painter = RatexPainter(
          DisplayList.fromJson({
            'width': 1.0,
            'height': 1.0,
            'depth': 0.0,
            'items': [
              {
                'type': 'Path',
                'x': 0.0,
                'y': 0.0,
                'fill': fill,
                'commands': [
                  {'type': 'MoveTo', 'x': 0.0, 'y': 0.0},
                  {'type': 'LineTo', 'x': 1.0, 'y': 0.0},
                  {'type': 'LineTo', 'x': 1.0, 'y': 1.0},
                  {'type': 'Close'},
                  {'type': 'MoveTo', 'x': 0.0, 'y': 0.0},
                  {'type': 'LineTo', 'x': 1.0, 'y': 1.0},
                  {'type': 'LineTo', 'x': 1.0, 'y': 0.0},
                  {'type': 'Close'},
                ],
                'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
              },
            ],
          }),
          fontSize: 10,
        );
        final canvas = TestRecordingCanvas();
        painter.paint(canvas, const Size(10, 10));
        return canvas.invocations
            .where((call) => call.invocation.memberName == #drawPath)
            .length;
      }

      // Opposite windings would cancel if filled as one path.
      expect(drawPathCalls(fill: true), 2);
      expect(drawPathCalls(fill: false), 1);
    });

    test('shouldRepaint keys on list identity and font size', () {
      const list = DisplayList(items: [], width: 1, height: 1, depth: 0);
      final a = RatexPainter(list, fontSize: 20);
      expect(a.shouldRepaint(RatexPainter(list, fontSize: 20)), isFalse);
      expect(a.shouldRepaint(RatexPainter(list, fontSize: 24)), isTrue);
    });
  });
}
