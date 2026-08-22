import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ratex_example/main.dart';

void main() {
  testWidgets('presents the Ratex integration surface', (tester) async {
    await tester.pumpWidget(
      const RatexExampleApp(formula: Text('Rendered formula')),
    );

    expect(find.text('RaTeX Flutter example'), findsOneWidget);
    expect(find.text('Rendered formula'), findsOneWidget);
  });
}
