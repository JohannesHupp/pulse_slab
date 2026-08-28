import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_example/main.dart';

void main() {
  testWidgets('renders the telemetry dashboard while paused', (tester) async {
    await tester.pumpWidget(const PulseSlabTelemetryApp());

    expect(find.text('Pulse Slab telemetry data plane'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Processed updates'), findsOneWidget);
    expect(find.text('Subscribed to temperature only'), findsOneWidget);
  });
}
