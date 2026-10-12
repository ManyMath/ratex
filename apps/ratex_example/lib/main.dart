import 'package:flutter/material.dart';
import 'package:ratex/ratex.dart';

void main() {
  runApp(const RatexExampleApp());
}

class RatexExampleApp extends StatelessWidget {
  const RatexExampleApp({super.key, this.formula});

  final Widget? formula;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ratex example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: RatexExamplePage(formula: formula),
    );
  }
}

class RatexExamplePage extends StatelessWidget {
  const RatexExamplePage({super.key, this.formula});

  final Widget? formula;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RaTeX Flutter example')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child:
              formula ??
              const RatexMath(
                r'\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}',
                fontSize: 30,
                semanticLabel: 'The Gaussian integral',
              ),
        ),
      ),
    );
  }
}
