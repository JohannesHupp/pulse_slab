import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_flutter_example/main.dart';

void main() {
  testWidgets('renders the telemetry dashboard while paused', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PulseSlabTelemetryApp());

    expect(find.text('Pulse Slab telemetry data plane'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('FPS --'), findsOneWidget);
    expect(find.text('Raw inputs'), findsOneWidget);
    expect(find.text('Committed records'), findsOneWidget);
    expect(find.text('Transaction-compacted inputs'), findsOneWidget);
    expect(find.text('Frame coalesced'), findsOneWidget);
    expect(find.text('Sample and clear'), findsOneWidget);
    expect(find.text('Burst transactions'), findsOneWidget);
    expect(find.text('Subscribed to temperature only'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sensor-card-0')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('sensor-card-23')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sensor-chart-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sensor-chart-23')),
      findsOneWidget,
    );
    expect(find.text('Sensor 24'), findsNothing);

    final sensorZeroPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('sensor-card-0')),
    );
    final sensorOnePosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('sensor-card-1')),
    );
    final sensorTwoPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('sensor-card-2')),
    );
    expect(sensorOnePosition.dx, greaterThan(sensorZeroPosition.dx));
    expect(sensorOnePosition.dy, closeTo(sensorZeroPosition.dy, 0.1));
    expect(sensorTwoPosition.dx, closeTo(sensorZeroPosition.dx, 0.1));
    expect(sensorTwoPosition.dy, greaterThan(sensorZeroPosition.dy));

    final Slider rateSlider = tester.widget<Slider>(find.byType(Slider));
    expect(rateSlider.min, 200);
    expect(rateSlider.max, 1000000);

    final highRatePreset = find.text('1M / s');
    await tester.scrollUntilVisible(highRatePreset, 200);
    await tester.tap(highRatePreset);
    await tester.pump();
    expect(
      find.text('Target input rate: 1000000 updates / second'),
      findsOneWidget,
    );
  });
}
