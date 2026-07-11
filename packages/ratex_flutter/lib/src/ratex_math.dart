import 'package:flutter/material.dart';
import 'package:ratex/ratex.dart';

import 'ratex_painter.dart';

/// Renders a LaTeX math formula.
///
/// ```dart
/// RatexMath(r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}', fontSize: 28)
/// ```
///
/// The widget initializes the engine on first use (a no-op afterwards),
/// lays the formula out, and paints it with the bundled KaTeX fonts. The
/// foreground color defaults to the ambient [DefaultTextStyle] color. Parse
/// errors render through [errorBuilder] (a small red message by default),
/// see [RatexParseException.start]/[RatexParseException.end] for source
/// spans.
class RatexMath extends StatefulWidget {
  const RatexMath(
    this.latex, {
    super.key,
    this.fontSize = 24,
    this.displayMode = true,
    this.color,
    this.errorBuilder,
    this.loadingBuilder,
  });

  /// The LaTeX source of one formula (math mode; environments like
  /// `\begin{align}...\end{align}` are themselves valid input).
  final String latex;

  /// Logical pixels per em.
  final double fontSize;

  /// Display style (`$$...$$`) when true, inline style (`$...$`) when false.
  final bool displayMode;

  /// Foreground color; defaults to the surrounding [DefaultTextStyle] color.
  /// Explicit `\color` commands in the formula override it per subtree.
  final Color? color;

  /// Builds the error presentation for invalid input.
  final Widget Function(BuildContext context, RatexException error)?
  errorBuilder;

  /// Shown while the engine initializes (only relevant for the very first
  /// formula on screen; afterwards rendering is synchronous).
  final WidgetBuilder? loadingBuilder;

  @override
  State<RatexMath> createState() => _RatexMathState();
}

class _RatexMathState extends State<RatexMath> {
  DisplayList? _displayList;
  RatexException? _error;
  (String, bool, Color)? _rendered;
  int _generation = 0;

  Color _effectiveColor(BuildContext context) =>
      widget.color ??
      DefaultTextStyle.of(context).style.color ??
      const Color(0xFF000000);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _render(_effectiveColor(context));
  }

  @override
  void didUpdateWidget(RatexMath oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latex != widget.latex ||
        oldWidget.displayMode != widget.displayMode ||
        oldWidget.color != widget.color) {
      _render(_effectiveColor(context));
    }
  }

  /// `#rrggbbaa` spec for the engine from a Flutter [Color].
  static String _hex(Color color) {
    final argb = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${argb.substring(2)}${argb.substring(0, 2)}';
  }

  Future<void> _render(Color color) async {
    final key = (widget.latex, widget.displayMode, color);
    if (_rendered == key) return;
    // Set before awaiting so overlapping triggers collapse to one render;
    // the generation counter drops stale results.
    _rendered = key;
    final generation = ++_generation;
    try {
      final list = await Ratex.renderDisplayList(
        widget.latex,
        options: RatexOptions(
          displayMode: widget.displayMode,
          color: _hex(color),
        ),
      );
      if (mounted && generation == _generation) {
        setState(() {
          _displayList = list;
          _error = null;
        });
      }
    } on Object catch (e) {
      // Any failure, engine, loading, or unexpected, must surface through
      // the error presentation, never as an unhandled async error leaving
      // the widget permanently blank.
      final error = e is RatexException
          ? e
          : RatexInternalException('rendering failed: $e');
      if (mounted && generation == _generation) {
        setState(() {
          _displayList = null;
          _error = error;
          // Do not cache failures: the next trigger (dependency change or
          // widget update) retries, e.g. once the wasm binary loads.
          _rendered = null;
        });
      } else {
        _rendered = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      final builder = widget.errorBuilder;
      if (builder != null) return builder(context, error);
      return Text(
        error.message,
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: widget.fontSize * 0.6,
          fontFamily: 'monospace',
        ),
      );
    }
    final list = _displayList;
    if (list == null) {
      final builder = widget.loadingBuilder;
      if (builder != null) return builder(context);
      return SizedBox(height: widget.fontSize);
    }
    final painter = RatexPainter(list, fontSize: widget.fontSize);
    return SizedBox(
      width: painter.widthPx,
      height: painter.totalHeightPx,
      child: CustomPaint(painter: painter),
    );
  }
}
