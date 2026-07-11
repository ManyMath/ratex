import 'package:flutter_test/flutter_test.dart';
import 'package:manymath/src/latex_document.dart';

void main() {
  group('parseLatexDocument', () {
    test('splits prose and display math', () {
      final blocks = parseLatexDocument(r'''
Some text before.

$$ e = mc^2 $$

Text after \[ \sqrt{2} \] and beyond.
''');
      // Display math splits the surrounding prose, so "Text after ... and
      // beyond." contributes two paragraphs around its formula.
      expect(blocks, hasLength(5));
      expect(blocks[0], isA<ParagraphBlock>());
      expect((blocks[1] as DisplayMathBlock).latex, 'e = mc^2');
      expect(blocks[2], isA<ParagraphBlock>());
      expect((blocks[3] as DisplayMathBlock).latex, r'\sqrt{2}');
      final tail = blocks[4] as ParagraphBlock;
      expect((tail.spans.single as TextRun).text, contains('and beyond.'));
    });

    test('passes math environments through whole', () {
      final blocks = parseLatexDocument(r'''
\begin{align}
  a &= b \\
  c &= d
\end{align}
''');
      final math = blocks.single as DisplayMathBlock;
      expect(math.latex, startsWith(r'\begin{align}'));
      expect(math.latex, endsWith(r'\end{align}'));
    });

    test('extracts the document body and \\maketitle metadata', () {
      final blocks = parseLatexDocument(r'''
\documentclass{article}
\title{A Title}
\author{An Author}
\begin{document}
\maketitle
Body text.
\end{document}
Ignored trailer.
''');
      final title = blocks.whereType<TitleBlock>().single;
      expect(title.title, 'A Title');
      expect(title.author, 'An Author');
      expect(title.date, isNull);
      final paragraph = blocks.whereType<ParagraphBlock>().single;
      expect((paragraph.spans.single as TextRun).text, contains('Body text.'));
      expect(
        blocks.whereType<ParagraphBlock>().length,
        1,
        reason: 'content outside the document environment is dropped',
      );
    });

    test('parses sections with levels', () {
      final blocks = parseLatexDocument(
        '\\section{One}\n\\subsection{Two}\n\\subsubsection{Three}',
      );
      final headings = blocks.whereType<HeadingBlock>().toList();
      expect(headings.map((h) => h.level), [1, 2, 3]);
      expect((headings[0].spans.single as TextRun).text, 'One');
    });

    test('parses itemize and enumerate', () {
      final blocks = parseLatexDocument(r'''
\begin{itemize}
  \item First with $x^2$ math
  \item Second
\end{itemize}
\begin{enumerate}
  \item Numbered
\end{enumerate}
''');
      final bullets = blocks[0] as ListBlock;
      expect(bullets.ordered, isFalse);
      expect(bullets.items, hasLength(2));
      expect(bullets.items[0].whereType<InlineMath>().single.latex, 'x^2');
      final numbered = blocks[1] as ListBlock;
      expect(numbered.ordered, isTrue);
    });

    test('strips comments but keeps escaped percent signs', () {
      final blocks = parseLatexDocument(
        'Visible % gone\nStill visible: 50\\% of it.',
      );
      final paragraph = blocks.single as ParagraphBlock;
      final text = paragraph.spans
          .whereType<TextRun>()
          .map((s) => s.text)
          .join();
      expect(text, isNot(contains('gone')));
      expect(text, contains('50% of it'));
    });

    test('never throws on malformed input', () {
      for (final source in [
        r'\begin{align} unterminated',
        r'$$ unterminated',
        r'\section{unclosed',
        r'\[',
        '',
        r'\end{document}',
      ]) {
        expect(
          () => parseLatexDocument(source),
          returnsNormally,
          reason: source,
        );
      }
    });
  });

  group('parseInline', () {
    test('mixes text, math, and styles', () {
      final spans = parseInline(
        r'Let $x$ be \textbf{bold and \emph{nested}} fine.',
      );
      expect(spans.whereType<InlineMath>().single.latex, 'x');
      final bold = spans.whereType<TextRun>().firstWhere(
        (s) => s.text.contains('bold'),
      );
      expect(bold.bold, isTrue);
      expect(bold.italic, isFalse);
      final nested = spans.whereType<TextRun>().firstWhere(
        (s) => s.text.contains('nested'),
      );
      expect(nested.bold, isTrue);
      expect(nested.italic, isTrue);
    });

    test(r'handles \( \) inline math and line breaks', () {
      final spans = parseInline(r'Before \(a+b\) after \\ next line');
      expect(spans.whereType<InlineMath>().single.latex, 'a+b');
      expect(spans.whereType<TextRun>().any((s) => s.text == '\n'), isTrue);
    });

    test(r'escaped \$ stays text', () {
      final spans = parseInline(r'Costs \$5 plus \$6.');
      expect(spans.whereType<InlineMath>(), isEmpty);
      expect((spans.single as TextRun).text, r'Costs $5 plus $6.');
    });
  });
}
