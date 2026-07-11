// manymath: a minimal LaTeX LaTeX editor on the ratex stack.
//
// Plaintext LaTeX on the left, rendered document on the right, rendering on
// demand (button or Ctrl/Cmd+Enter). No accounts, no persistence, no cloud -
// that plumbing comes later; this is the rendering core working end to end.
//
// Web: `melos run native:build:web` once, then `flutter run -d chrome`.
// Native: `flutter run -d linux` (or any desktop) - cargokit builds the
// engine automatically.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ratex_flutter/ratex_flutter.dart';

import 'src/document_view.dart';
import 'src/latex_document.dart';

void main() {
  runApp(const ManyMathApp());
}

const _sampleDocument = r'''
\title{The Basel Problem}
\author{Leonhard Euler (retold in ManyMath)}
\date{1735}

\begin{document}
\maketitle

\section{The problem}

Find the exact sum of the reciprocals of the squares of the natural
numbers, that is, evaluate
\[
  \sum_{n=1}^{\infty} \frac{1}{n^2}
  = 1 + \frac{1}{4} + \frac{1}{9} + \frac{1}{16} + \cdots
\]

The series clearly converges --- compare it with the telescoping series
$\sum \frac{1}{n(n+1)} = 1$ --- but its exact value resisted the
\textit{Bernoullis} for decades.

\section{Euler's insight}

Euler considered the Taylor series of $\frac{\sin x}{x}$ and treated it as an
\emph{infinite polynomial} with roots at $x = \pm\pi, \pm 2\pi, \ldots$:

\begin{align}
  \frac{\sin x}{x} &= \prod_{n=1}^{\infty}
    \left(1 - \frac{x^2}{n^2\pi^2}\right) \\
  &= 1 - \frac{x^2}{6} + \frac{x^4}{120} - \cdots
\end{align}

Comparing the $x^2$ coefficients of both sides gives the celebrated result:

\begin{equation}
  \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
\end{equation}

\section{Why it matters}

\begin{itemize}
  \item It launched the study of $\zeta(s) = \sum n^{-s}$, the
        \textbf{Riemann zeta function}.
  \item The same technique yields $\zeta(4) = \frac{\pi^4}{90}$ and beyond.
  \item It connects analysis and number theory: $\zeta(2) = \frac{\pi^2}{6}$
        equals $\prod_p \frac{1}{1 - p^{-2}}$ over the primes.
\end{itemize}

% Comments never reach the output.
Try editing this document and pressing Ctrl+Enter (or the Render button).
\end{document}
''';

class ManyMathApp extends StatelessWidget {
  const ManyMathApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'manymath',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2e7d32), // ManyMath green
        ),
        useMaterial3: true,
      ),
      home: const EditorPage(),
    );
  }
}

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final _controller = TextEditingController(text: _sampleDocument);
  List<DocBlock> _blocks = const [];
  bool _engineReady = false;
  String? _engineError;
  double _split = 0.5;

  @override
  void initState() {
    super.initState();
    RatexFlutter.ensureInitialized()
        .then((_) {
          if (!mounted) return;
          setState(() => _engineReady = true);
          _render();
        })
        .catchError((Object e) {
          if (mounted) setState(() => _engineError = '$e');
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _render() {
    setState(() => _blocks = parseLatexDocument(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        title: const Text('manymath'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: FilledButton.tonalIcon(
              onPressed: _engineReady ? _render : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Render'),
            ),
          ),
        ],
      ),
      body: _engineError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'The rendering engine failed to load.\n\n$_engineError',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final editorWidth = constraints.maxWidth * _split;
                return Row(
                  children: [
                    SizedBox(
                      width: editorWidth,
                      child: _Editor(
                        controller: _controller,
                        onRender: _render,
                      ),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: (details) => setState(() {
                          _split =
                              ((editorWidth + details.delta.dx) /
                                      constraints.maxWidth)
                                  .clamp(0.2, 0.8);
                        }),
                        child: Container(
                          width: 8,
                          color: scheme.surfaceContainerHighest,
                          child: const Center(
                            child: Icon(Icons.drag_indicator, size: 12),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: const Color(0xffe8e4dd),
                        child: _engineReady
                            ? DocumentView(blocks: _blocks)
                            : const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor({required this.controller, required this.onRender});

  final TextEditingController controller;
  final VoidCallback onRender;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            onRender,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): onRender,
      },
      child: Container(
        color: const Color(0xff282c34),
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: controller,
          maxLines: null,
          expands: true,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 14,
            height: 1.5,
            color: Color(0xffabb2bf),
          ),
          cursorColor: Colors.white,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: r'\begin{document} ... \end{document}',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
      ),
    );
  }
}
