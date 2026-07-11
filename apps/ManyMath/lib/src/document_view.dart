import 'package:flutter/material.dart';
import 'package:ratex_flutter/ratex_flutter.dart';

import 'latex_document.dart';

/// Renders parsed [DocBlock]s as a paper-like page.
class DocumentView extends StatelessWidget {
  const DocumentView({super.key, required this.blocks});

  final List<DocBlock> blocks;

  static const _bodySize = 16.0;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        children: [
          Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 720),
              padding: const EdgeInsets.all(48),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: _bodySize,
                  height: 1.5,
                  fontFamily: 'serif',
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (blocks.isEmpty)
                      const Text(
                        'Nothing to render yet, type some LaTeX and press '
                        'Render (Ctrl+Enter).',
                        textAlign: TextAlign.center,
                      ),
                    for (final block in blocks) _buildBlock(context, block),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlock(BuildContext context, DocBlock block) {
    switch (block) {
      case TitleBlock():
        // Metadata arguments are LaTeX too (escapes, inline math, styles),
        // run them through the inline parser rather than showing raw source.
        Widget metadata(String source, double fontSize, TextStyle style) =>
            Text.rich(
              TextSpan(children: _inlineSpans(parseInline(source), fontSize)),
              textAlign: TextAlign.center,
              style: style,
            );
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            children: [
              if (block.title != null)
                metadata(
                  block.title!,
                  28,
                  const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              if (block.author != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: metadata(block.author!, _bodySize, const TextStyle()),
                ),
              if (block.date != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: metadata(
                    block.date!,
                    _bodySize,
                    const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
            ],
          ),
        );
      case HeadingBlock():
        final size = switch (block.level) {
          1 => 24.0,
          2 => 20.0,
          _ => 17.0,
        };
        return Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text.rich(
            TextSpan(children: _inlineSpans(block.spans, size)),
            style: TextStyle(fontSize: size, fontWeight: FontWeight.bold),
          ),
        );
      case ParagraphBlock():
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text.rich(
            TextSpan(children: _inlineSpans(block.spans, _bodySize)),
          ),
        );
      case DisplayMathBlock():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: RatexMath(block.latex, fontSize: _bodySize * 1.25),
            ),
          ),
        );
      case ListBlock():
        return Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, item) in block.items.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          block.ordered ? '${index + 1}.' : '•',
                          textAlign: TextAlign.right,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: _inlineSpans(item, _bodySize)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
    }
  }

  List<InlineSpan> _inlineSpans(List<DocInline> spans, double fontSize) => [
    for (final span in spans)
      switch (span) {
        TextRun() => TextSpan(
          text: span.text,
          style: TextStyle(
            fontWeight: span.bold ? FontWeight.bold : null,
            fontStyle: span.italic ? FontStyle.italic : null,
          ),
        ),
        InlineMath() => WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: RatexMath(span.latex, fontSize: fontSize, displayMode: false),
        ),
      },
  ];
}
