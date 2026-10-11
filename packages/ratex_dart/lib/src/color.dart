/// An RGBA color with components in `0.0..=1.0`, as used by RaTeX display
/// lists (serialized as `{"r": .., "g": .., "b": .., "a": ..}`).
class RatexColor {
  const RatexColor(this.r, this.g, this.b, [this.a = 1.0]);

  /// Black, the default foreground color.
  static const RatexColor black = RatexColor(0, 0, 0);

  /// White.
  static const RatexColor white = RatexColor(1, 1, 1);

  final double r;
  final double g;
  final double b;
  final double a;

  factory RatexColor.fromJson(Map<String, dynamic> json) => RatexColor(
    (json['r'] as num?)?.toDouble() ?? 0,
    (json['g'] as num?)?.toDouble() ?? 0,
    (json['b'] as num?)?.toDouble() ?? 0,
    (json['a'] as num?)?.toDouble() ?? 1,
  );

  Map<String, dynamic> toJson() => {'r': r, 'g': g, 'b': b, 'a': a};

  static int _channel(double v) => (v.clamp(0.0, 1.0) * 255).round();

  /// The color as a 32-bit ARGB integer (the layout used by Flutter's
  /// `Color` constructor).
  int toArgb() =>
      (_channel(a) << 24) |
      (_channel(r) << 16) |
      (_channel(g) << 8) |
      _channel(b);

  /// The color as a `#rrggbbaa` hex spec, accepted by [RatexOptions.color]
  /// and by CSS.
  String toCssHex() {
    String hex(double v) => _channel(v).toRadixString(16).padLeft(2, '0');
    return '#${hex(r)}${hex(g)}${hex(b)}${hex(a)}';
  }

  @override
  bool operator ==(Object other) =>
      other is RatexColor &&
      other.r == r &&
      other.g == g &&
      other.b == b &&
      other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() => 'RatexColor(${toCssHex()})';
}
