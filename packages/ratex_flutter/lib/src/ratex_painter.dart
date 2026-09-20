import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:ratex/ratex.dart';

/// Paints a RaTeX [DisplayList] onto a canvas.
///
/// Display-list coordinates are in em units; every coordinate is multiplied
/// by [fontSize] (logical pixels per em). Glyphs are drawn as single-character
/// paragraphs using the KaTeX fonts bundled with this package (referenced as
/// `packages/ratex_flutter/<family>`, so consuming apps need no font setup);
/// the CJK/emoji fallback IDs use the platform's default font. Lines and
/// rects are filled directly, and `Path` items carry their own outline
/// geometry (radicals, stretchy delimiters).
class RatexPainter extends CustomPainter {
  RatexPainter(this.displayList, {required this.fontSize});

  final DisplayList displayList;

  /// Logical pixels per em.
  final double fontSize;

  /// Painted width in logical pixels.
  double get widthPx => displayList.width * fontSize;

  /// Painted height above the baseline in logical pixels.
  double get heightPx => displayList.height * fontSize;

  /// Painted depth below the baseline in logical pixels.
  double get depthPx => displayList.depth * fontSize;

  /// Total painted height in logical pixels.
  double get totalHeightPx => displayList.totalHeight * fontSize;

  double _px(double em) => em * fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in displayList.items) {
      switch (item) {
        case GlyphPathItem glyph:
          _paintGlyph(canvas, glyph);
        case LineItem line:
          _paintLine(canvas, line);
        case RectItem rect:
          _paintRect(canvas, rect);
        case PathItem path:
          _paintPath(canvas, path);
      }
    }
  }

  void _paintGlyph(Canvas canvas, GlyphPathItem glyph) {
    final fontId = KatexFontId.parse(glyph.font);
    final family = fontId.family == null
        ? null
        : 'packages/ratex_flutter/${fontId.family}';
    final sizePx = glyph.scale * fontSize;
    final style = ui.TextStyle(
      color: Color(glyph.color.toArgb()),
      fontSize: sizePx,
      fontFamily: family,
      fontWeight: fontId.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: fontId.italic ? FontStyle.italic : FontStyle.normal,
    );
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontSize: sizePx, fontFamily: family),
          )
          ..pushStyle(style)
          ..addText(glyph.character);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    // The item's y is the glyph's alphabetic baseline (matching the web
    // canvas convention `textBaseline: 'alphabetic'`).
    canvas.drawParagraph(
      paragraph,
      Offset(_px(glyph.x), _px(glyph.y) - paragraph.alphabeticBaseline),
    );
  }

  void _paintLine(Canvas canvas, LineItem line) {
    final paint = Paint()..color = Color(line.color.toArgb());
    // Keep hairlines visible at small sizes.
    final thickness = (_px(line.thickness)).clamp(0.5, double.infinity);
    final y = _px(line.y) - thickness / 2;
    final x = _px(line.x);
    final width = _px(line.width);
    if (!line.dashed) {
      canvas.drawRect(Rect.fromLTWH(x, y, width, thickness), paint);
      return;
    }
    final dash = thickness * 3;
    for (var start = 0.0; start < width; start += dash * 2) {
      final end = (start + dash).clamp(0.0, width);
      canvas.drawRect(
        Rect.fromLTWH(x + start, y, end - start, thickness),
        paint,
      );
    }
  }

  void _paintRect(Canvas canvas, RectItem rect) {
    canvas.drawRect(
      Rect.fromLTWH(
        _px(rect.x),
        _px(rect.y),
        _px(rect.width),
        _px(rect.height),
      ),
      Paint()..color = Color(rect.color.toArgb()),
    );
  }

  void _paintPath(Canvas canvas, PathItem item) {
    final paths = [Path()];
    for (final (i, command) in item.commands.indexed) {
      // Fills draw each subpath on its own, as ratex-svg does: in one path,
      // overlapping subpaths of opposite winding cancel out and leave holes
      // (e.g. in \xmapsto).
      if (item.fill && i > 0 && command is MoveToCommand) paths.add(Path());
      final path = paths.last;
      switch (command) {
        case MoveToCommand(:final x, :final y):
          path.moveTo(_px(x), _px(y));
        case LineToCommand(:final x, :final y):
          path.lineTo(_px(x), _px(y));
        case CubicToCommand(
          :final x1,
          :final y1,
          :final x2,
          :final y2,
          :final x,
          :final y,
        ):
          path.cubicTo(_px(x1), _px(y1), _px(x2), _px(y2), _px(x), _px(y));
        case QuadToCommand(:final x1, :final y1, :final x, :final y):
          path.quadraticBezierTo(_px(x1), _px(y1), _px(x), _px(y));
        case CloseCommand():
          path.close();
      }
    }
    final paint = Paint()
      ..color = Color(item.color.toArgb())
      ..style = item.fill ? PaintingStyle.fill : PaintingStyle.stroke
      // Stroke width scales with the em size like every other display-list
      // dimension (1.5 user units at the engine's reference 40px/em, the
      // same ratio ratex-svg uses), clamped so hairlines stay visible.
      ..strokeWidth = (fontSize * 1.5 / 40).clamp(0.5, double.infinity);
    final offset = Offset(_px(item.x), _px(item.y));
    for (final path in paths) {
      canvas.drawPath(path.shift(offset), paint);
    }
  }

  @override
  bool shouldRepaint(RatexPainter oldDelegate) =>
      oldDelegate.displayList != displayList ||
      oldDelegate.fontSize != fontSize;
}
