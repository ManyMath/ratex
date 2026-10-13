import 'package:flutter_test/flutter_test.dart';
import 'package:ratex_playground/main.dart';

void main() {
  testWidgets('playground shows its controls', (tester) async {
    await tester.pumpWidget(const RatexExampleApp());
    await tester.pump();
    expect(find.text('Display'), findsOneWidget);
    expect(find.text('Inline'), findsOneWidget);
    expect(find.text('Euler identity'), findsOneWidget);
    // Don't settle: without the native library the init future keeps the
    // backend label at a placeholder, which is fine for this smoke test.
  });
}
