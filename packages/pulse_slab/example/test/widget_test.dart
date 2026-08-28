import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_example/main.dart';

void main() {
  testWidgets('renders the telemetry dashboard while paused', (tester) async {
    await tester.pumpWidget(const PulseSlabTelemetryApp());

    expect(find.text('Pulse Slab telemetry data plane'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Processed updates'), findsOneWidget);
    expect(find.text('Subscribed to temperature only'), findsOneWidget);

    final Slider rateSlider = tester.widget<Slider>(find.byType(Slider));
    expect(rateSlider.min, 200);
    expect(rateSlider.max, 1000000);

    await tester.tap(find.text('1M / s'));
    await tester.pump();
    expect(
      find.text('Target input rate: 1000000 updates / second'),
      findsOneWidget,
    );
  });
}
