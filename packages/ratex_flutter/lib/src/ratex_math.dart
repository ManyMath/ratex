import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
///
/// The rendered formula reports its alphabetic baseline, so it lines up with
/// surrounding text in a baseline-aligned [Row] or in a [WidgetSpan] with
/// [PlaceholderAlignment.baseline].
class RatexMath extends StatefulWidget {
  const RatexMath(
    this.latex, {
    super.key,
    this.fontSize = 24,
    this.displayMode = true,
    this.color,
    this.errorBuilder,
    this.loadingBuilder,
    this.semanticLabel,
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

  /// Shown while the engine initializes. Once [Ratex.ensureInitialized] has
  /// completed, formulas render synchronously and never show it.
  final WidgetBuilder? loadingBuilder;

  /// A screen-reader-friendly description of the formula.
  ///
  /// When omitted, the label is derived from [latex], for example
  /// `Mathematical expression: x^2 + y^2`. Loading and error states use the
  /// same description while announcing their current status.
  final String? semanticLabel;

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

  String get _normalizedLatex =>
      widget.latex.trim().replaceAll(RegExp(r'\s+'), ' ');

  String get _semanticLabel {
    final label = widget.semanticLabel;
    if (label != null) return label;

    final source = _normalizedLatex;
    return source.isEmpty
        ? 'Empty mathematical expression'
        : 'Mathematical expression: $source';
  }

  String get _statusSemanticSubject {
    final label = widget.semanticLabel;
    if (label != null) return label;

    final source = _normalizedLatex;
    return source.isEmpty
        ? 'empty mathematical expression'
        : 'mathematical expression: $source';
  }

  Widget _semantics({
    required String label,
    required Widget child,
    bool liveRegion = false,
    bool excludeChildSemantics = false,
  }) {
    return Semantics(
      container: true,
      label: label,
      liveRegion: liveRegion,
      excludeSemantics: excludeChildSemantics,
      child: child,
    );
  }

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

  /// Renders the formula unless the result for these inputs is current.
  ///
  /// Only called from [didChangeDependencies] and [didUpdateWidget], which a
  /// build always follows, so once the engine is initialized the result is
  /// applied directly and the formula appears without a loading frame.
  void _render(Color color) {
    final key = (widget.latex, widget.displayMode, color);
    if (_rendered == key) return;
    // Set before rendering so overlapping triggers collapse to one render;
    // the generation counter drops stale async results.
    _rendered = key;
    final generation = ++_generation;
    final latex = widget.latex;
    final options = RatexOptions(
      displayMode: widget.displayMode,
      color: _hex(color),
    );
    if (!Ratex.isInitialized) {
      _renderAsync(latex, options, generation);
      return;
    }
    try {
      _settle(Ratex.renderDisplayListSync(latex, options: options), null);
    } on Object catch (e) {
      _settle(null, _asRatexException(e));
    }
  }

  Future<void> _renderAsync(
    String latex,
    RatexOptions options,
    int generation,
  ) async {
    DisplayList? list;
    RatexException? error;
    try {
      list = await Ratex.renderDisplayList(latex, options: options);
    } on Object catch (e) {
      error = _asRatexException(e);
    }
    // A superseded render must not touch the state, `_rendered` included:
    // it now belongs to the newer render.
    if (mounted && generation == _generation) {
      setState(() => _settle(list, error));
    }
  }

  void _settle(DisplayList? list, RatexException? error) {
    _displayList = list;
    _error = error;
    // Do not cache failures: the next trigger (dependency change or widget
    // update) retries, e.g. once the wasm binary loads.
    if (error != null) _rendered = null;
  }

  /// Any failure, engine, loading, or unexpected, must surface through the
  /// error presentation, never as an unhandled async error leaving the
  /// widget permanently blank.
  static RatexException _asRatexException(Object error) =>
      error is RatexException
      ? error
      : RatexInternalException('rendering failed: $error');

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      final builder = widget.errorBuilder;
      final presentation = builder != null
          ? builder(context, error)
          : Text(
              error.message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: widget.fontSize * 0.6,
                fontFamily: 'monospace',
              ),
            );
      return _semantics(
        label: 'Could not render $_statusSemanticSubject. ${error.message}',
        liveRegion: true,
        excludeChildSemantics: builder == null,
        child: presentation,
      );
    }
    final list = _displayList;
    if (list == null) {
      final builder = widget.loadingBuilder;
      return _semantics(
        label: 'Rendering $_statusSemanticSubject',
        liveRegion: true,
        excludeChildSemantics: builder == null,
        child: builder != null
            ? builder(context)
            : SizedBox(height: widget.fontSize),
      );
    }
    final painter = RatexPainter(
      list,
      fontSize: widget.fontSize,
      repaint: PaintingBinding.instance.systemFonts,
    );
    return _semantics(
      label: _semanticLabel,
      child: _FormulaBaseline(
        baseline: painter.heightPx,
        child: SizedBox(
          width: painter.widthPx,
          height: painter.totalHeightPx,
          child: CustomPaint(painter: painter),
        ),
      ),
    );
  }
}

/// Reports [baseline] (distance from the top edge to the formula's baseline)
/// as the child's baseline, which a plain [SizedBox] does not have.
class _FormulaBaseline extends SingleChildRenderObjectWidget {
  const _FormulaBaseline({required this.baseline, super.child});

  final double baseline;

  @override
  _RenderFormulaBaseline createRenderObject(BuildContext context) =>
      _RenderFormulaBaseline(baseline);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFormulaBaseline renderObject,
  ) {
    renderObject.baseline = baseline;
  }
}

class _RenderFormulaBaseline extends RenderProxyBox {
  _RenderFormulaBaseline(this._baseline);

  double _baseline;
  set baseline(double value) {
    if (value == _baseline) return;
    _baseline = value;
    markNeedsLayout();
  }

  // Math has a single baseline; ideographic requests get the same one.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => _baseline;
}
