import 'dart:async';

import 'dart:convert';

import 'package:ratex_dart/ratex_dart.dart';
import 'package:ratex_dart/src/backends/status.dart';
import 'package:test/test.dart';

/// A stand-in backend for exercising the registry without native code.
class _FakeBackend implements RatexBackend {
  _FakeBackend(this.name, {this.priority = 0, this.isAvailable = true});

  @override
  final String name;

  @override
  final int priority;

  @override
  final bool isAvailable;

  bool initialized = false;
  bool disposed = false;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<void> dispose() async => disposed = true;

  @override
  String get engineVersion => '0.0.0-fake';

  @override
  DisplayList renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) => const DisplayList(items: [], width: 1, height: 1, depth: 0);

  @override
  String renderSvg(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) => '<svg xmlns="http://www.w3.org/2000/svg"/>';
}

/// A backend whose [initialize] blocks until released, recording renders
/// that arrive too early.
class _SlowBackend extends _FakeBackend {
  _SlowBackend(this._initialize) : super('slow', priority: 5000);

  final Future<void> Function() _initialize;
  bool _ready = false;
  int rendersBeforeReady = 0;

  @override
  Future<void> initialize() async {
    await _initialize();
    _ready = true;
  }

  @override
  DisplayList renderDisplayList(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    if (!_ready) rendersBeforeReady++;
    return super.renderDisplayList(latex, options: options);
  }

  @override
  String renderSvg(
    String latex, {
    RatexOptions options = const RatexOptions(),
  }) {
    if (!_ready) rendersBeforeReady++;
    return super.renderSvg(latex, options: options);
  }
}

/// A backend whose non-async [initialize] throws synchronously until
/// [fail] is cleared.
class _FlakyBackend extends _FakeBackend {
  _FlakyBackend() : super('flaky', priority: 5000);

  bool fail = true;
  int initCalls = 0;

  @override
  Future<void> initialize() {
    initCalls++;
    if (fail) throw StateError('not yet');
    return super.initialize();
  }
}

void main() {
  group('DisplayList JSON', () {
    // The protocol documentation's own example payload.
    final json = <String, dynamic>{
      'version': 1,
      'width': 5.02,
      'height': 1.84,
      'depth': 0.21,
      'items': [
        {
          'type': 'GlyphPath',
          'x': 0.0,
          'y': 0.0,
          'scale': 1.0,
          'font': 'Main-Regular',
          'char_code': 120,
          'color': {'r': 0.0, 'g': 0.0, 'b': 0.0, 'a': 1.0},
        },
        {
          'type': 'Line',
          'x': 0.1,
          'y': 0.9,
          'width': 4.8,
          'thickness': 0.04,
          'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
          'dashed': false,
        },
        {
          'type': 'Rect',
          'x': 0.5,
          'y': 1.0,
          'width': 2.0,
          'height': 0.5,
          'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
        },
        {
          'type': 'Path',
          'x': 0.0,
          'y': 0.0,
          'fill': true,
          'commands': [
            {'type': 'MoveTo', 'x': 0.1, 'y': 0.7},
            {'type': 'LineTo', 'x': 0.2, 'y': 0.8},
            {
              'type': 'CubicTo',
              'x1': 0.2,
              'y1': 0.5,
              'x2': 0.4,
              'y2': 0.3,
              'x': 0.6,
              'y': 0.1,
            },
            {'type': 'QuadTo', 'x1': 0.2, 'y1': 0.5, 'x': 0.6, 'y': 0.1},
            {'type': 'Close'},
          ],
          'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
        },
      ],
    };

    test('parses the protocol example', () {
      final list = DisplayList.fromJson(json);
      expect(list.version, 1);
      expect(list.width, closeTo(5.02, 1e-9));
      expect(list.totalHeight, closeTo(2.05, 1e-9));
      expect(list.items, hasLength(4));

      final glyph = list.items[0] as GlyphPathItem;
      expect(glyph.font, 'Main-Regular');
      expect(glyph.charCode, 120);
      expect(glyph.character, 'x');
      expect(glyph.color, RatexColor.black);

      final line = list.items[1] as LineItem;
      expect(line.thickness, closeTo(0.04, 1e-9));
      expect(line.dashed, isFalse);

      final rect = list.items[2] as RectItem;
      expect(rect.height, closeTo(0.5, 1e-9));

      final path = list.items[3] as PathItem;
      expect(path.fill, isTrue);
      expect(path.commands, hasLength(5));
      expect(path.commands.last, isA<CloseCommand>());
    });

    test('summarizes itself with two-decimal em sizes', () {
      const list = DisplayList(
        items: [],
        width: 7.015258888888889,
        height: 1.5,
        depth: 0.776389,
      );
      expect(list.toString(), 'DisplayList(0 items, 7.02em x 2.28em)');
    });

    test('round-trips through toJson', () {
      final list = DisplayList.fromJson(json);
      final again = DisplayList.fromJson(list.toJson());
      expect(again.toJson(), list.toJson());
    });

    test('skips unknown item and command types (forward compatibility)', () {
      final list = DisplayList.fromJson({
        'version': 1,
        'width': 1.0,
        'height': 1.0,
        'depth': 0.0,
        'items': [
          {'type': 'Hologram', 'x': 0, 'y': 0},
          {
            'type': 'Path',
            'x': 0,
            'y': 0,
            'fill': false,
            'commands': [
              {'type': 'MoveTo', 'x': 0, 'y': 0},
              {'type': 'TeleportTo', 'x': 9, 'y': 9},
            ],
            'color': {'r': 0, 'g': 0, 'b': 0, 'a': 1},
          },
        ],
      });
      expect(list.items, hasLength(1));
      expect((list.items.single as PathItem).commands, hasLength(1));
    });

    test('tolerates missing optional fields', () {
      final list = DisplayList.fromJson({
        'items': [
          {'type': 'GlyphPath'},
          {'type': 'Line', 'x': 1, 'y': 2},
        ],
      });
      expect(list.width, 0);
      final glyph = list.items[0] as GlyphPathItem;
      expect(glyph.scale, 1);
      expect(glyph.color, RatexColor.black);
      final line = list.items[1] as LineItem;
      expect(line.dashed, isFalse);
    });
  });

  group('RatexColor', () {
    test('converts to ARGB and CSS hex', () {
      const red = RatexColor(1, 0, 0);
      expect(red.toArgb(), 0xffff0000);
      expect(red.toCssHex(), '#ff0000ff');
      const translucent = RatexColor(0, 0.5, 1, 0.5);
      expect(translucent.toCssHex(), '#0080ff80');
    });

    test('clamps out-of-range channels', () {
      const wild = RatexColor(2, -1, 0.5);
      expect(wild.toArgb(), 0xffff0080);
    });
  });

  group('KatexFontId', () {
    test('maps IDs to family, weight and style', () {
      final mainBold = KatexFontId.parse('Main-Bold');
      expect(mainBold.family, 'KaTeX_Main');
      expect(mainBold.bold, isTrue);
      expect(mainBold.italic, isFalse);

      final mathItalic = KatexFontId.parse('Math-Italic');
      expect(mathItalic.family, 'KaTeX_Math');
      expect(mathItalic.italic, isTrue);

      final boldItalic = KatexFontId.parse('Main-BoldItalic');
      expect(boldItalic.bold, isTrue);
      expect(boldItalic.italic, isTrue);

      final size2 = KatexFontId.parse('Size2-Regular');
      expect(size2.family, 'KaTeX_Size2');
      expect(size2.bold, isFalse);
    });

    test('CJK and emoji fall back to the system font', () {
      for (final id in ['CJK-Regular', 'CJK-Fallback', 'Emoji-Fallback']) {
        expect(KatexFontId.parse(id).family, isNull, reason: id);
      }
    });
  });

  group('RatexOptions', () {
    test('serializes camelCase JSON with defaults', () {
      expect(const RatexOptions().toJson(), {
        'displayMode': true,
        'fontSize': 40,
        'padding': 10,
        'strokeWidth': 1.5,
        'embedGlyphs': true,
      });
      expect(
        const RatexOptions(displayMode: false, color: 'red').toJson(),
        containsPair('color', 'red'),
      );
    });

    test('rejects non-finite numbers as invalid input', () {
      for (final options in [
        const RatexOptions(fontSize: double.nan),
        const RatexOptions(padding: double.infinity),
        const RatexOptions(strokeWidth: double.negativeInfinity),
      ]) {
        expect(options.toJson, throwsA(isA<RatexInvalidInputException>()));
      }
    });

    test('copyWith replaces only the given fields', () {
      const base = RatexOptions();
      final inline = base.copyWith(displayMode: false);
      expect(inline.displayMode, isFalse);
      expect(inline.fontSize, base.fontSize);
    });
  });

  group('Ratex registry', () {
    setUp(Ratex.reset);
    tearDown(Ratex.reset);

    test('selects the available backend with the highest priority', () {
      // Priorities above the default backends' 100 so this test is
      // independent of whether the real native library is present.
      final low = _FakeBackend('low', priority: 1000);
      final high = _FakeBackend('high', priority: 2000);
      final unavailable = _FakeBackend(
        'ghost',
        priority: 9999,
        isAvailable: false,
      );
      Ratex.registerBackend(low);
      Ratex.registerBackend(high);
      Ratex.registerBackend(unavailable);
      expect(Ratex.backend.name, 'high');
    });

    test('useBackend pins by name and throws for unknown names', () {
      Ratex.registerBackend(_FakeBackend('a', priority: 10));
      Ratex.registerBackend(_FakeBackend('b', priority: 1));
      Ratex.useBackend('b');
      expect(Ratex.backend.name, 'b');
      expect(
        () => Ratex.useBackend('nope'),
        throwsA(isA<NoBackendAvailableException>()),
      );
    });

    test('concurrent callers all wait for one slow initialization', () async {
      // Regression test: on the web, initialize() fetches the wasm binary,
      // so a widget rendering while another caller is still initializing
      // must wait rather than hit an uninitialized backend.
      final gate = Completer<void>();
      var initCount = 0;
      final slow = _SlowBackend(() async {
        initCount++;
        await gate.future;
      });
      Ratex.registerBackend(slow, makeActive: true);
      final renders = Future.wait([
        Ratex.renderDisplayList('a'),
        Ratex.renderDisplayList('b'),
        Ratex.renderSvg('c').then((_) {}),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(slow.rendersBeforeReady, 0);
      gate.complete();
      await renders;
      expect(initCount, 1);
      expect(slow.rendersBeforeReady, 0);
    });

    test('ensureInitialized initializes once', () async {
      final fake = _FakeBackend('fake', priority: 1000);
      Ratex.registerBackend(fake, makeActive: true);
      await Ratex.ensureInitialized();
      fake.initialized = false;
      await Ratex.ensureInitialized();
      expect(
        fake.initialized,
        isFalse,
        reason: 'second call must not re-initialize',
      );
    });

    test(
      'a failed initialization is retried, even a synchronous throw',
      () async {
        final flaky = _FlakyBackend();
        Ratex.registerBackend(flaky, makeActive: true);
        await expectLater(Ratex.ensureInitialized(), throwsStateError);
        flaky.fail = false;
        await Ratex.ensureInitialized();
        expect(flaky.initCalls, 2);
        expect(flaky.initialized, isTrue);
      },
    );

    test('isInitialized tracks the selected backend', () async {
      Ratex.registerBackend(
        _FakeBackend('fake', priority: 1000),
        makeActive: true,
      );
      expect(Ratex.isInitialized, isFalse);
      await Ratex.ensureInitialized();
      expect(Ratex.isInitialized, isTrue);
      Ratex.registerBackend(
        _FakeBackend('other', priority: 2000),
        makeActive: true,
      );
      expect(Ratex.isInitialized, isFalse);
    });

    test('sync render requires prior initialization', () {
      Ratex.registerBackend(
        _FakeBackend('fake', priority: 1000),
        makeActive: true,
      );
      expect(() => Ratex.renderDisplayListSync('x'), throwsStateError);
    });

    test('async render initializes and delegates', () async {
      Ratex.registerBackend(
        _FakeBackend('fake', priority: 1000),
        makeActive: true,
      );
      final list = await Ratex.renderDisplayList('x');
      expect(list.width, 1);
      expect(Ratex.renderSvgSync('x'), startsWith('<svg'));
    });

    test('reset disposes initialized backends', () async {
      final fake = _FakeBackend('fake', priority: 1000);
      Ratex.registerBackend(fake, makeActive: true);
      await Ratex.ensureInitialized();
      await Ratex.reset();
      expect(fake.disposed, isTrue);
    });
  });

  group('throwForStatus', () {
    RatexParseException parseError(String input, int? start, int? end) {
      try {
        throwForStatus(
          1,
          jsonEncode({'message': 'boom', 'start': start, 'end': end}),
          utf8.encode(input),
        );
      } on RatexParseException catch (e) {
        return e;
      }
    }

    test('converts UTF-8 byte spans to string indices', () {
      const input = r'éé\foo';
      final e = parseError(input, 4, 8);
      expect(input.substring(e.start!, e.end!), r'\foo');
    });

    test('drops spans that are out of range or split a character', () {
      expect(parseError('ab', 1, 3).end, isNull);
      expect(parseError('é', 0, 1).end, isNull);
      expect(parseError('ab', null, null).hasSpan, isFalse);
    });

    test('maps status codes to exception types', () {
      final none = utf8.encode('');
      expect(
        () => throwForStatus(2, '{"message":"bad"}', none),
        throwsA(isA<RatexInvalidInputException>()),
      );
      expect(
        () => throwForStatus(3, 'not json', none),
        throwsA(
          isA<RatexInternalException>().having(
            (e) => e.message,
            'message',
            'not json',
          ),
        ),
      );
    });
  });

  group('exceptions', () {
    test('parse exception formats its span', () {
      const e = RatexParseException('boom', start: 3, end: 7);
      expect(e.hasSpan, isTrue);
      expect(e.toString(), contains('3..7'));
      const noSpan = RatexParseException('boom');
      expect(noSpan.hasSpan, isFalse);
    });
  });
}
