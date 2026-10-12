// Formula playground for ratex: presets, a live LaTeX editor, a
// font-size slider, and a display/inline toggle. Runs on every native
// platform (cargokit builds the Rust engine automatically) and on the web
// (serve ratex_ffi.wasm from web/, see README).

import 'package:flutter/material.dart';
import 'package:ratex/ratex.dart';

void main() {
  runApp(const RatexExampleApp());
}

const _presets = <(String, String)>[
  ('Quadratic formula', r'x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}'),
  ('Euler identity', r'e^{i\pi} + 1 = 0'),
  ('Gaussian integral', r'\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}'),
  ('Basel problem', r'\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}'),
  (
    'Maxwell (curl E)',
    r'\nabla \times \mathbf{E} = -\frac{\partial \mathbf{B}}{\partial t}',
  ),
  (
    'Rotation matrix',
    r'R(\theta) = \begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix}',
  ),
  ('Cases', r'|x| = \begin{cases} x & x \ge 0 \\ -x & x < 0 \end{cases}'),
  ('Binomial theorem', r'(x+y)^n = \sum_{k=0}^{n} \binom{n}{k} x^{n-k} y^k'),
  ('Chemistry (mhchem)', r'\ce{H2SO4 + 2NaOH -> Na2SO4 + 2H2O}'),
  ('Colors', r'\textcolor{red}{\heartsuit} + \textcolor{blue}{\clubsuit}'),
];

class RatexExampleApp extends StatelessWidget {
  const RatexExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ratex example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const PlaygroundPage(),
    );
  }
}

class PlaygroundPage extends StatefulWidget {
  const PlaygroundPage({super.key});

  @override
  State<PlaygroundPage> createState() => _PlaygroundPageState();
}

class _PlaygroundPageState extends State<PlaygroundPage> {
  final _controller = TextEditingController(text: _presets.first.$2);
  String _backend = '...';
  double _fontSize = 28;
  bool _displayMode = true;
  String _latex = _presets.first.$2;

  @override
  void initState() {
    super.initState();
    RatexFlutter.ensureInitialized()
        .then((name) {
          if (mounted) setState(() => _backend = name);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _backend = 'unavailable');
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('ratex - backend: $_backend')),
      body: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: RatexMath(
                  _latex,
                  fontSize: _fontSize,
                  displayMode: _displayMode,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _presets.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => ActionChip(
                      label: Text(_presets[i].$1),
                      onPressed: () {
                        _controller.text = _presets[i].$2;
                        setState(() => _latex = _presets[i].$2);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'LaTeX',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _latex = value),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Display')),
                        ButtonSegment(value: false, label: Text('Inline')),
                      ],
                      selected: {_displayMode},
                      onSelectionChanged: (selection) =>
                          setState(() => _displayMode = selection.first),
                    ),
                    Expanded(
                      child: Slider(
                        min: 12,
                        max: 72,
                        value: _fontSize,
                        label: '${_fontSize.round()} px',
                        onChanged: (value) => setState(() => _fontSize = value),
                      ),
                    ),
                    Text('${_fontSize.round()} px'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
