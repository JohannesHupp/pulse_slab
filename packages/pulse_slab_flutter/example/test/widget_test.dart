import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';

// The template deliberately lives outside the package's public `lib/` API.
// ignore: avoid_relative_lib_imports
import '../lib/main.dart';

void main() {
  testWidgets('displays the latest committed temperature', (tester) async {
    await tester.pumpWidget(const PulseSlabExampleApp());

    expect(find.text('20.0 °C'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('increase-temperature')));
    await tester.pump();

    expect(find.text('20.5 °C'), findsOneWidget);
  });
}
