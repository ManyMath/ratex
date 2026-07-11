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

    // Regression tests for review findings (each was a reproduced bug).

    test(r'\end{document} before \begin{document} does not crash', () {
      final blocks = parseLatexDocument(r'\end{document}\begin{document}hello');
      final paragraph = blocks.whereType<ParagraphBlock>().single;
      expect((paragraph.spans.single as TextRun).text, 'hello');
    });

    test(r'\\[2pt] line breaks do not open display math', () {
      final blocks = parseLatexDocument(
        'Line one \\\\[2pt]\nLine two\n\n\\[ x^2 \\]',
      );
      expect(blocks.whereType<DisplayMathBlock>().single.latex, 'x^2');
      final text = blocks
          .whereType<ParagraphBlock>()
          .expand((p) => p.spans)
          .whereType<TextRun>()
          .map((s) => s.text)
          .join();
      expect(text, contains('Line two'));
      expect(text, isNot(contains('2pt')));
    });

    test(r'escaped \$ does not open $$ display math', () {
      final blocks = parseLatexDocument(
        'It costs \\\$\$x\$ dollars.\n\n\$\$ y = 2 \$\$',
      );
      expect(blocks.whereType<DisplayMathBlock>().single.latex, 'y = 2');
      final first = blocks.first as ParagraphBlock;
      expect(first.spans.whereType<InlineMath>().single.latex, 'x');
      final text = first.spans.whereType<TextRun>().map((s) => s.text).join();
      expect(text, contains(r'$'));
      expect(text, contains('dollars.'));
    });

    test('a comment-only line does not split the paragraph', () {
      final blocks = parseLatexDocument(
        'first half of sentence\n% a comment line\nsecond half',
      );
      expect(blocks.whereType<ParagraphBlock>(), hasLength(1));
    });

    test(r'\\% is a comment, not an escaped percent', () {
      final blocks = parseLatexDocument('break \\\\% gone\nnext');
      final text = blocks
          .whereType<ParagraphBlock>()
          .expand((p) => p.spans)
          .whereType<TextRun>()
          .map((s) => s.text)
          .join();
      expect(text, isNot(contains('gone')));
      expect(text, contains('next'));
    });

    test('nested itemize stays inside the outer list', () {
      // Nested lists are out of scope (their source degrades to item text),
      // but they must not truncate the outer environment: outer2 stays a
      // bullet and no raw tokens leak out of the list into paragraphs.
      final blocks = parseLatexDocument(
        r'\begin{itemize}\item outer'
        r'\begin{itemize}\item inner\end{itemize}'
        r'\item outer2\end{itemize}',
      );
      final list = blocks.whereType<ListBlock>().single;
      final allText = list.items
          .expand((item) => item)
          .whereType<TextRun>()
          .map((s) => s.text)
          .join(' ');
      expect(allText, contains('outer2'));
      expect(
        blocks.whereType<ParagraphBlock>(),
        isEmpty,
        reason: 'nothing may leak out of the list',
      );
    });

    test(r'\itemsep is not an item boundary', () {
      final blocks = parseLatexDocument(
        '\\begin{itemize}\\itemsep0pt\n\\item only one\\end{itemize}',
      );
      final list = blocks.whereType<ListBlock>().single;
      // The \itemsep prefix survives as (degraded) text, but must not
      // create a bogus extra bullet beyond it.
      final bulletsWithContent = list.items
          .where(
            (item) => item.whereType<TextRun>().any(
              (s) => s.text.contains('only one'),
            ),
          )
          .toList();
      expect(bulletsWithContent, hasLength(1));
    });

    test('display math inside a list item degrades to inline math', () {
      final blocks = parseLatexDocument(
        r'\begin{itemize}\item The identity $$e^{i\pi} = -1$$ holds'
        r'\end{itemize}',
      );
      final item = blocks.whereType<ListBlock>().single.items.single;
      expect(item.whereType<InlineMath>().single.latex, r'e^{i\pi} = -1');
      final text = item.whereType<TextRun>().map((s) => s.text).join();
      expect(text, isNot(contains(r'$')));
    });

    test(r'adjacent inline maths $a$$b$ are not display math', () {
      final blocks = parseLatexDocument(
        'sum of \$a\$\$b\$ terms\n\n\$\$ x \$\$',
      );
      expect(blocks.whereType<DisplayMathBlock>().single.latex, 'x');
      final first = blocks.first as ParagraphBlock;
      expect(first.spans.whereType<InlineMath>().map((m) => m.latex), [
        'a',
        'b',
      ]);
    });

    test('content before the first \\item is not a bullet', () {
      final blocks = parseLatexDocument(
        '\\begin{itemize}\\itemsep0pt\n\\item real\\end{itemize}',
      );
      final list = blocks.whereType<ListBlock>().single;
      expect(list.items, hasLength(1));
      expect((list.items.single.single as TextRun).text, 'real');
    });

    test(r'\item[label] optional arguments are stripped', () {
      final blocks = parseLatexDocument(
        r'\begin{itemize}\item[(a)] first\item second\end{itemize}',
      );
      final list = blocks.whereType<ListBlock>().single;
      expect((list.items[0].single as TextRun).text, 'first');
      expect((list.items[1].single as TextRun).text, 'second');
    });

    test(r'\[..\] inside a list item degrades to inline math', () {
      final blocks = parseLatexDocument(
        r'\begin{itemize}\item yields \[ \zeta(2) \] here\end{itemize}',
      );
      final item = blocks.whereType<ListBlock>().single.items.single;
      expect(item.whereType<InlineMath>().single.latex, r'\zeta(2)');
    });

    test(r'\title {X} with whitespace before the brace still parses', () {
      final blocks = parseLatexDocument(
        '\\title {Spaced}\n\\begin{document}\\maketitle\\end{document}',
      );
      expect(blocks.whereType<TitleBlock>().single.title, 'Spaced');
    });

    test('CRLF documents still get paragraph breaks', () {
      final blocks = parseLatexDocument(
        'para one\r\n\r\npara two\r\n\r\npara three',
      );
      expect(blocks.whereType<ParagraphBlock>(), hasLength(3));
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
