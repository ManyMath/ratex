/// A deliberately small LaTeX *document* model on top of ratex's *math*
/// engine.
///
/// RaTeX renders formulas; an LaTeX page also has prose around
/// them. This parser understands just enough document LaTeX for that:
/// comments, `\begin{document}` bodies, `\maketitle` metadata, sections,
/// paragraphs with inline math and `\textbf`/`\textit`/`\emph`, single-level
/// `itemize`/`enumerate` lists, and display math (`$$...$$`, `\[...\]`, and
/// the math environments RaTeX lays out natively, like `align`). Everything
/// else passes through as plain text: the parser never throws.
library;

/// One block of a parsed document, in source order.
sealed class DocBlock {
  const DocBlock();
}

final class TitleBlock extends DocBlock {
  const TitleBlock({this.title, this.author, this.date});

  final String? title;
  final String? author;
  final String? date;
}

final class HeadingBlock extends DocBlock {
  const HeadingBlock(this.level, this.spans);

  /// 1 = `\section`, 2 = `\subsection`, 3 = `\subsubsection`.
  final int level;
  final List<DocInline> spans;
}

final class ParagraphBlock extends DocBlock {
  const ParagraphBlock(this.spans);

  final List<DocInline> spans;
}

final class DisplayMathBlock extends DocBlock {
  const DisplayMathBlock(this.latex);

  /// The formula source handed to RaTeX (for environments, includes the
  /// surrounding `\begin{...}...\end{...}`).
  final String latex;
}

final class ListBlock extends DocBlock {
  const ListBlock({required this.ordered, required this.items});

  final bool ordered;
  final List<List<DocInline>> items;
}

/// One run of inline content inside a paragraph, heading, or list item.
sealed class DocInline {
  const DocInline();
}

final class TextRun extends DocInline {
  const TextRun(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;
}

final class InlineMath extends DocInline {
  const InlineMath(this.latex);

  final String latex;
}

/// Math environments RaTeX lays out natively when passed whole.
const _mathEnvironments = {
  'equation',
  'equation*',
  'align',
  'align*',
  'alignat',
  'alignat*',
  'gather',
  'gather*',
};

/// Parses [source] into document blocks. Lenient by construction: malformed
/// input degrades to plain text rather than failing.
List<DocBlock> parseLatexDocument(String source) {
  // Normalize line endings first: CRLF/CR would defeat the blank-line
  // paragraph detection below.
  var text = _stripComments(
    source.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  );

  final title = _argOf(text, r'\title');
  final author = _argOf(text, r'\author');
  final date = _argOf(text, r'\date');

  // Work on the document body when a document environment is present. The
  // end marker only counts after the begin marker (a stray earlier
  // \end{document} must not produce an inverted range).
  final beginDoc = text.indexOf(r'\begin{document}');
  if (beginDoc >= 0) {
    final bodyStart = beginDoc + r'\begin{document}'.length;
    final endDoc = text.indexOf(r'\end{document}', bodyStart);
    text = text.substring(bodyStart, endDoc >= 0 ? endDoc : text.length);
  }

  final blocks = <DocBlock>[];
  final paragraph = StringBuffer();

  void flushParagraph() {
    final content = paragraph.toString().trim();
    paragraph.clear();
    if (content.isEmpty) return;
    final spans = parseInline(content);
    if (spans.isNotEmpty) blocks.add(ParagraphBlock(spans));
  }

  var i = 0;
  while (i < text.length) {
    // Blank line: paragraph boundary.
    final blank = RegExp(r'\n[ \t]*\n').matchAsPrefix(text, i);
    if (blank != null) {
      flushParagraph();
      i = blank.end;
      continue;
    }

    // Escape pairs, consumed before any delimiter matching so that the
    // second backslash of `\\[2pt]` never opens `\[` display math and an
    // escaped dollar in `\$$x$` never opens `$$`. The pairs pass through
    // verbatim; parseInline interprets them later.
    if (text.startsWith(r'\\', i) ||
        (text[i] == r'\' &&
            i + 1 < text.length &&
            r'$%&_{}#'.contains(text[i + 1]))) {
      paragraph.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }

    // Display math: $$...$$ and \[...\].
    final dollars = _delimited(text, i, r'$$', r'$$');
    if (dollars != null) {
      flushParagraph();
      blocks.add(DisplayMathBlock(dollars.$1.trim()));
      i = dollars.$2;
      continue;
    }
    // A single $ opens inline math; consume the whole span verbatim into
    // the paragraph (parseInline interprets it later). Without this, the
    // adjacent closers/openers in '$a$$b$' would read as a $$ display
    // opener and swallow the rest of the document.
    if (text.startsWith(r'$', i)) {
      final inline = _delimited(text, i, r'$', r'$');
      if (inline != null) {
        paragraph.write(text.substring(i, inline.$2));
        i = inline.$2;
        continue;
      }
    }
    final bracket = _delimited(text, i, r'\[', r'\]');
    if (bracket != null) {
      flushParagraph();
      blocks.add(DisplayMathBlock(bracket.$1.trim()));
      i = bracket.$2;
      continue;
    }

    // Environments: math ones become display blocks, lists become lists.
    final env = RegExp(r'\\begin\{([a-zA-Z*]+)\}').matchAsPrefix(text, i);
    if (env != null) {
      final name = env.group(1)!;
      final end = _matchingEnvEnd(text, name, env.end);
      if (end >= 0) {
        final body = text.substring(env.end, end);
        final next = end + '\\end{$name}'.length;
        if (_mathEnvironments.contains(name)) {
          flushParagraph();
          blocks.add(DisplayMathBlock(text.substring(i, next).trim()));
          i = next;
          continue;
        }
        if (name == 'itemize' || name == 'enumerate') {
          flushParagraph();
          // \item only, not \itemsep and friends. Nested block content
          // inside an item degrades to inline text (see parseInline), but
          // the depth-aware end search above keeps it inside the item
          // instead of leaking raw \end tokens into the page.
          final segments = body.split(RegExp(r'\\item(?![a-zA-Z])'));
          final items = [
            // segments[0] precedes the first \item (typically spacing
            // commands like \itemsep0pt) and is not a bullet.
            for (final segment in segments.skip(1))
              if (_stripItemLabel(segment).trim() case final trimmed
                  when trimmed.isNotEmpty)
                parseInline(trimmed),
          ];
          if (items.isNotEmpty) {
            blocks.add(ListBlock(ordered: name == 'enumerate', items: items));
          }
          i = next;
          continue;
        }
      }
      // Unknown or unterminated environment: fall through as text.
    }

    // Sections and \maketitle, recognized at any position.
    final section = RegExp(r'\\(sub){0,2}section\*?\{').matchAsPrefix(text, i);
    if (section != null) {
      final arg = _balancedArg(text, section.end - 1);
      if (arg != null) {
        flushParagraph();
        final level = 'sub'.allMatches(section[0]!).length + 1;
        blocks.add(HeadingBlock(level, parseInline(arg.$1)));
        i = arg.$2;
        continue;
      }
    }
    if (text.startsWith(r'\maketitle', i)) {
      flushParagraph();
      blocks.add(TitleBlock(title: title, author: author, date: date));
      i += r'\maketitle'.length;
      continue;
    }

    paragraph.write(text[i]);
    i++;
  }
  flushParagraph();
  return blocks;
}

/// Parses inline content: `$...$`, `\(...\)`, `\textbf{}`, `\textit{}`,
/// `\emph{}`, common escapes, and `\\` as a line break.
List<DocInline> parseInline(
  String source, {
  bool bold = false,
  bool italic = false,
}) {
  final spans = <DocInline>[];
  final run = StringBuffer();

  void flushRun() {
    if (run.isEmpty) return;
    final content = run.toString();
    run.clear();
    // Collapse whitespace runs (LaTeX treats newlines as spaces).
    final collapsed = content.replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isNotEmpty) {
      spans.add(TextRun(collapsed, bold: bold, italic: italic));
    }
  }

  var i = 0;
  while (i < source.length) {
    // Escapes first so \$ never opens math.
    const escapes = {
      r'\$': r'$',
      r'\%': '%',
      r'\&': '&',
      r'\_': '_',
      r'\{': '{',
      r'\}': '}',
      r'\#': '#',
    };
    final escape = escapes.entries
        .where((e) => source.startsWith(e.key, i))
        .firstOrNull;
    if (escape != null) {
      run.write(escape.value);
      i += escape.key.length;
      continue;
    }
    if (source.startsWith(r'\\', i)) {
      flushRun();
      spans.add(const TextRun('\n'));
      i += 2;
      // Swallow the optional length argument of a line break (`\\[2pt]`)
      // instead of rendering "[2pt]" as text.
      final length = RegExp(r'\[[^\]\n]*\]').matchAsPrefix(source, i);
      if (length != null) i = length.end;
      continue;
    }

    // Display math reaching inline context (e.g. inside a list item)
    // degrades to inline math rather than leaking stray dollar signs.
    final doubleDollar = _delimited(source, i, r'$$', r'$$');
    if (doubleDollar != null && doubleDollar.$1.trim().isNotEmpty) {
      flushRun();
      spans.add(InlineMath(doubleDollar.$1.trim()));
      i = doubleDollar.$2;
      continue;
    }
    final dollar = _delimited(source, i, r'$', r'$');
    if (dollar != null && dollar.$1.trim().isNotEmpty) {
      flushRun();
      spans.add(InlineMath(dollar.$1.trim()));
      i = dollar.$2;
      continue;
    }
    final paren = _delimited(source, i, r'\(', r'\)');
    if (paren != null && paren.$1.trim().isNotEmpty) {
      flushRun();
      spans.add(InlineMath(paren.$1.trim()));
      i = paren.$2;
      continue;
    }
    // \[...\] display math reaching inline context degrades to inline math
    // too, instead of leaking raw LaTeX.
    final bracket = _delimited(source, i, r'\[', r'\]');
    if (bracket != null && bracket.$1.trim().isNotEmpty) {
      flushRun();
      spans.add(InlineMath(bracket.$1.trim()));
      i = bracket.$2;
      continue;
    }

    const styles = {
      r'\textbf{': (bold: true, italic: false),
      r'\textit{': (bold: false, italic: true),
      r'\emph{': (bold: false, italic: true),
    };
    final style = styles.entries
        .where((e) => source.startsWith(e.key, i))
        .firstOrNull;
    if (style != null) {
      final arg = _balancedArg(source, i + style.key.length - 1);
      if (arg != null) {
        flushRun();
        spans.addAll(
          parseInline(
            arg.$1,
            bold: bold || style.value.bold,
            italic: italic || style.value.italic,
          ),
        );
        i = arg.$2;
        continue;
      }
    }

    run.write(source[i]);
    i++;
  }
  flushRun();
  return spans;
}

/// Index of the `\end{name}` matching the `\begin{name}` whose body starts
/// at [from], skipping over same-name nested environments; -1 when
/// unterminated.
int _matchingEnvEnd(String text, String name, int from) {
  final open = '\\begin{$name}';
  final close = '\\end{$name}';
  var depth = 1;
  var i = from;
  while (i < text.length) {
    if (text.startsWith(close, i)) {
      depth--;
      if (depth == 0) return i;
      i += close.length;
    } else if (text.startsWith(open, i)) {
      depth++;
      i += open.length;
    } else {
      i++;
    }
  }
  return -1;
}

/// Cuts each line at its first unescaped `%` (escaped means preceded by an
/// odd number of backslashes, `\\%` IS a comment, after a line break).
/// A line that was only a comment vanishes entirely, newline included, so
/// it cannot fake the blank line that separates paragraphs (TeX's `%` eats
/// the newline too).
String _stripComments(String source) {
  final out = StringBuffer();
  var first = true;
  for (final line in source.split('\n')) {
    var cut = -1;
    for (var i = 0; i < line.length; i++) {
      if (line[i] != '%') continue;
      var backslashes = 0;
      while (i - 1 - backslashes >= 0 && line[i - 1 - backslashes] == r'\') {
        backslashes++;
      }
      if (backslashes.isEven) {
        cut = i;
        break;
      }
    }
    final stripped = cut < 0 ? line : line.substring(0, cut);
    final commentOnly = cut >= 0 && stripped.trim().isEmpty;
    if (commentOnly) continue;
    if (!first) out.write('\n');
    first = false;
    out.write(stripped);
  }
  return out.toString();
}

/// When [text] starts with [open] at [at], returns the content up to the
/// matching [close] and the index just past it.
(String, int)? _delimited(String text, int at, String open, String close) {
  if (!text.startsWith(open, at)) return null;
  final start = at + open.length;
  var i = start;
  while (i < text.length) {
    // Look for the close first (it may itself start with a backslash, e.g.
    // `\]`), then skip escaped characters so `\$` never closes `$...$`.
    if (text.startsWith(close, i)) {
      return (text.substring(start, i), i + close.length);
    }
    i += text[i] == r'\' ? 2 : 1;
  }
  return null;
}

/// Reads a `{...}`-balanced argument starting at the `{` at [at]; returns the
/// content and the index just past the closing `}`.
(String, int)? _balancedArg(String text, int at) {
  if (at >= text.length || text[at] != '{') return null;
  var depth = 0;
  for (var i = at; i < text.length; i++) {
    if (text[i] == r'\') {
      i++; // skip escaped char
      continue;
    }
    if (text[i] == '{') depth++;
    if (text[i] == '}') {
      depth--;
      if (depth == 0) return (text.substring(at + 1, i), i + 1);
    }
  }
  return null;
}

/// Drops an `\item[label]` optional argument from the start of an item
/// segment.
String _stripItemLabel(String segment) {
  final trimmed = segment.trimLeft();
  if (!trimmed.startsWith('[')) return segment;
  final close = trimmed.indexOf(']');
  return close < 0 ? segment : trimmed.substring(close + 1);
}

/// First `\command{...}` argument in [text] (whitespace allowed before the
/// brace, and `\command` must not merely prefix a longer command), or null.
String? _argOf(String text, String command) {
  final match = RegExp(
    '${RegExp.escape(command)}(?![a-zA-Z])\\s*\\{',
  ).firstMatch(text);
  if (match == null) return null;
  return _balancedArg(text, match.end - 1)?.$1;
}
