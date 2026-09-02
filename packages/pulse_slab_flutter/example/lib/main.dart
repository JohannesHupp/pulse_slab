import 'package:flutter/material.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

final Float32Field _temperature = Float32Field('temperature');
final RecordLayout _sensorLayout = RecordLayout(
  name: 'SensorState',
  fields: <Field<Object?>>[_temperature],
);

void main() {
  runApp(const PulseSlabExampleApp());
}

/// A minimal Flutter template using one record-specific reactive builder.
class PulseSlabExampleApp extends StatefulWidget {
  /// Creates the example application.
  const PulseSlabExampleApp({super.key});

  @override
  State<PulseSlabExampleApp> createState() => _PulseSlabExampleAppState();
}

final class _PulseSlabExampleAppState extends State<PulseSlabExampleApp> {
  late final PulseStore _store;
  late final RecordHandle _sensor;

  @override
  void initState() {
    super.initState();
    _store = PulseStore();
    _sensor = _store.allocate(_sensorLayout);
    _store.update(_sensor, (TransactionRecordWriter writer) {
      writer.set(_temperature, 20.0);
    });
  }

  void _increaseTemperature() {
    final double current = _store.read(_sensor).get(_temperature);
    _store.update(_sensor, (TransactionRecordWriter writer) {
      writer.set(_temperature, current + 0.5);
    });
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Pulse Slab')),
        body: Center(
          child: ReactiveRecordBuilder(
            store: _store,
            handle: _sensor,
            fields: _temperature.mask,
            builder: (BuildContext context, RecordReader record) {
              final double value = record.get(_temperature);
              return Text(
                '${value.toStringAsFixed(1)} °C',
                style: Theme.of(context).textTheme.headlineMedium,
              );
            },
          ),
        ),
        floatingActionButton: FloatingActionButton(
          key: const ValueKey<String>('increase-temperature'),
          onPressed: _increaseTemperature,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}
