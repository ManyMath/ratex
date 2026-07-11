/// Options accepted by every render call, serialized as JSON across the
/// engine boundary (unknown fields are ignored by older engines).
class RatexOptions {
  const RatexOptions({
    this.displayMode = true,
    this.color,
    this.fontSize = 40,
    this.padding = 10,
    this.strokeWidth = 1.5,
    this.embedGlyphs = true,
  });

  /// `true` renders in display style (`$$...$$`); `false` in inline style
  /// (`$...$`).
  final bool displayMode;

  /// Foreground color spec: a named color, `#rgb`, `#rgba`, `#rrggbb`,
  /// `#rrggbbaa`, or `[MODEL]value`: the notations KaTeX's `\color`
  /// accepts. Null renders black. Explicit `\color` commands in the input
  /// override this per subtree.
  final String? color;

  /// SVG only: user units per em.
  final double fontSize;

  /// SVG only: padding on all sides, in user units.
  final double padding;

  /// SVG only: stroke width for unfilled paths, in user units.
  final double strokeWidth;

  /// SVG only: `true` (default) inlines glyph outlines from the engine's
  /// embedded KaTeX fonts so the SVG is fully self-contained; `false` emits
  /// `<text>` elements that require the KaTeX webfonts wherever the SVG is
  /// displayed.
  final bool embedGlyphs;

  RatexOptions copyWith({
    bool? displayMode,
    String? color,
    double? fontSize,
    double? padding,
    double? strokeWidth,
    bool? embedGlyphs,
  }) => RatexOptions(
    displayMode: displayMode ?? this.displayMode,
    color: color ?? this.color,
    fontSize: fontSize ?? this.fontSize,
    padding: padding ?? this.padding,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    embedGlyphs: embedGlyphs ?? this.embedGlyphs,
  );

  Map<String, dynamic> toJson() => {
    'displayMode': displayMode,
    if (color != null) 'color': color,
    'fontSize': fontSize,
    'padding': padding,
    'strokeWidth': strokeWidth,
    'embedGlyphs': embedGlyphs,
  };
}
