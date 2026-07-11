import 'color.dart';

/// A laid-out formula: a flat list of absolute-coordinate drawing commands.
///
/// This mirrors RaTeX's DisplayList JSON protocol (`version: 1`). All
/// coordinates and sizes are in em units with the origin at the top-left of
/// the bounding box, x growing right and y growing down; the baseline sits at
/// `y == height`. Multiply by a font size in logical pixels to get screen
/// units.
///
/// Following the protocol's decoder rules, unknown JSON fields are ignored
/// and items with an unrecognized `type` are skipped, so newer engines can
/// add item kinds without breaking older consumers.
class DisplayList {
  const DisplayList({
    required this.items,
    required this.width,
    required this.height,
    required this.depth,
    this.version = 1,
  });

  /// Drawing commands in paint order.
  final List<DisplayItem> items;

  /// Width of the bounding box, in em.
  final double width;

  /// Height above the baseline, in em.
  final double height;

  /// Depth below the baseline, in em.
  final double depth;

  /// DisplayList JSON protocol version.
  final int version;

  /// Total height (ascent plus descent), in em.
  double get totalHeight => height + depth;

  factory DisplayList.fromJson(Map<String, dynamic> json) => DisplayList(
    items: [
      for (final item in (json['items'] as List<dynamic>? ?? const []))
        if (DisplayItem.fromJson(item as Map<String, dynamic>)
            case final DisplayItem parsed)
          parsed,
    ],
    width: (json['width'] as num?)?.toDouble() ?? 0,
    height: (json['height'] as num?)?.toDouble() ?? 0,
    depth: (json['depth'] as num?)?.toDouble() ?? 0,
    version: (json['version'] as num?)?.toInt() ?? 1,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'width': width,
    'height': height,
    'depth': depth,
    'items': [for (final item in items) item.toJson()],
  };

  @override
  String toString() =>
      'DisplayList(${items.length} items, ${width}em x ${totalHeight}em)';
}

/// One drawing command of a [DisplayList].
sealed class DisplayItem {
  const DisplayItem({required this.x, required this.y, required this.color});

  /// Horizontal position, in em.
  final double x;

  /// Vertical position, in em.
  final double y;

  /// Fill color.
  final RatexColor color;

  /// Parses one item, or returns null for an unrecognized `type` (the
  /// protocol requires tolerating unknown variants).
  static DisplayItem? fromJson(Map<String, dynamic> json) {
    final x = (json['x'] as num?)?.toDouble() ?? 0;
    final y = (json['y'] as num?)?.toDouble() ?? 0;
    final color = switch (json['color']) {
      final Map<String, dynamic> c => RatexColor.fromJson(c),
      _ => RatexColor.black,
    };
    return switch (json['type']) {
      'GlyphPath' => GlyphPathItem(
        x: x,
        y: y,
        color: color,
        scale: (json['scale'] as num?)?.toDouble() ?? 1,
        font: json['font'] as String? ?? 'Main-Regular',
        charCode: (json['char_code'] as num?)?.toInt() ?? 0,
      ),
      'Line' => LineItem(
        x: x,
        y: y,
        color: color,
        width: (json['width'] as num?)?.toDouble() ?? 0,
        thickness: (json['thickness'] as num?)?.toDouble() ?? 0,
        dashed: json['dashed'] as bool? ?? false,
      ),
      'Rect' => RectItem(
        x: x,
        y: y,
        color: color,
        width: (json['width'] as num?)?.toDouble() ?? 0,
        height: (json['height'] as num?)?.toDouble() ?? 0,
      ),
      'Path' => PathItem(
        x: x,
        y: y,
        color: color,
        fill: json['fill'] as bool? ?? true,
        commands: [
          for (final cmd in (json['commands'] as List<dynamic>? ?? const []))
            if (PathCommand.fromJson(cmd as Map<String, dynamic>)
                case final PathCommand parsed)
              parsed,
        ],
      ),
      _ => null,
    };
  }

  Map<String, dynamic> toJson();
}

/// A single glyph, identified by font ID and code point, not by outline.
///
/// Renderers draw the character [charCode] as text at `(x, y)` where `y` is
/// the alphabetic baseline, using the KaTeX font named by [font] at
/// `scale * fontSize`. See [KatexFontId] for mapping [font] to a family and
/// style.
final class GlyphPathItem extends DisplayItem {
  const GlyphPathItem({
    required super.x,
    required super.y,
    required super.color,
    required this.scale,
    required this.font,
    required this.charCode,
  });

  /// Size multiplier relative to the base font size.
  final double scale;

  /// RaTeX font ID, e.g. `Main-Regular`, `Math-Italic`, `Size2-Regular`.
  final String font;

  /// Unicode code point to draw.
  final int charCode;

  /// The glyph as a string (handles code points beyond the BMP).
  String get character => String.fromCharCode(charCode);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'GlyphPath',
    'x': x,
    'y': y,
    'scale': scale,
    'font': font,
    'char_code': charCode,
    'color': color.toJson(),
  };
}

/// A horizontal rule (fraction bars, radical vinculums, \hline, ...), drawn
/// as a filled rectangle of [width] by [thickness] centered vertically on
/// `y`.
final class LineItem extends DisplayItem {
  const LineItem({
    required super.x,
    required super.y,
    required super.color,
    required this.width,
    required this.thickness,
    this.dashed = false,
  });

  /// Length of the rule, in em.
  final double width;

  /// Stroke thickness, in em.
  final double thickness;

  /// Whether to draw a dashed rule (e.g. `\dashedLine` in proof trees).
  final bool dashed;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'Line',
    'x': x,
    'y': y,
    'width': width,
    'thickness': thickness,
    'color': color.toJson(),
    'dashed': dashed,
  };
}

/// A filled rectangle (`\colorbox`, `\rule`, ...).
final class RectItem extends DisplayItem {
  const RectItem({
    required super.x,
    required super.y,
    required super.color,
    required this.width,
    required this.height,
  });

  /// Width, in em.
  final double width;

  /// Height, in em.
  final double height;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'Rect',
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'color': color.toJson(),
  };
}

/// Vector geometry (radical signs, stretchy delimiters, ...). The only item
/// kind that carries real outline data. Command coordinates are relative to
/// the item's `(x, y)` offset.
final class PathItem extends DisplayItem {
  const PathItem({
    required super.x,
    required super.y,
    required super.color,
    required this.commands,
    this.fill = true,
  });

  final List<PathCommand> commands;

  /// `true` fills the path; `false` strokes it.
  final bool fill;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'Path',
    'x': x,
    'y': y,
    'commands': [for (final cmd in commands) cmd.toJson()],
    'fill': fill,
    'color': color.toJson(),
  };
}

/// One segment of a [PathItem], mirroring SVG path semantics.
sealed class PathCommand {
  const PathCommand();

  /// Parses one command, or returns null for an unrecognized `type`.
  static PathCommand? fromJson(Map<String, dynamic> json) {
    double d(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return switch (json['type']) {
      'MoveTo' => MoveToCommand(d('x'), d('y')),
      'LineTo' => LineToCommand(d('x'), d('y')),
      'CubicTo' => CubicToCommand(
        d('x1'),
        d('y1'),
        d('x2'),
        d('y2'),
        d('x'),
        d('y'),
      ),
      'QuadTo' => QuadToCommand(d('x1'), d('y1'), d('x'), d('y')),
      'Close' => const CloseCommand(),
      _ => null,
    };
  }

  Map<String, dynamic> toJson();
}

final class MoveToCommand extends PathCommand {
  const MoveToCommand(this.x, this.y);
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() => {'type': 'MoveTo', 'x': x, 'y': y};
}

final class LineToCommand extends PathCommand {
  const LineToCommand(this.x, this.y);
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() => {'type': 'LineTo', 'x': x, 'y': y};
}

final class CubicToCommand extends PathCommand {
  const CubicToCommand(this.x1, this.y1, this.x2, this.y2, this.x, this.y);
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'CubicTo',
    'x1': x1,
    'y1': y1,
    'x2': x2,
    'y2': y2,
    'x': x,
    'y': y,
  };
}

final class QuadToCommand extends PathCommand {
  const QuadToCommand(this.x1, this.y1, this.x, this.y);
  final double x1;
  final double y1;
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'QuadTo',
    'x1': x1,
    'y1': y1,
    'x': x,
    'y': y,
  };
}

final class CloseCommand extends PathCommand {
  const CloseCommand();

  @override
  Map<String, dynamic> toJson() => {'type': 'Close'};
}

/// Parses a RaTeX font ID (e.g. `Main-Bold`, `Math-Italic`, `CJK-Regular`)
/// into the pieces a text renderer needs.
class KatexFontId {
  const KatexFontId._({
    required this.id,
    required this.family,
    required this.bold,
    required this.italic,
  });

  /// The raw font ID from the display list.
  final String id;

  /// KaTeX font family (e.g. `KaTeX_Main`), or null for the CJK/emoji
  /// fallback IDs, which should use the platform's default font.
  final String? family;

  final bool bold;
  final bool italic;

  static const Set<String> _systemFallbackIds = {
    'CJK-Regular',
    'CJK-Fallback',
    'Emoji-Fallback',
  };

  factory KatexFontId.parse(String id) {
    if (_systemFallbackIds.contains(id)) {
      return KatexFontId._(id: id, family: null, bold: false, italic: false);
    }
    final dash = id.indexOf('-');
    final prefix = dash < 0 ? id : id.substring(0, dash);
    final suffix = dash < 0 ? '' : id.substring(dash + 1);
    return KatexFontId._(
      id: id,
      family: 'KaTeX_$prefix',
      bold: suffix.contains('Bold'),
      italic: suffix.contains('Italic'),
    );
  }
}
