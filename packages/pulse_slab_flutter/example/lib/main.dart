import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

final Float64Field _timestampField = Float64Field('timestamp');
final Float32Field _temperatureField = Float32Field('temperature');
final Float32Field _pressureField = Float32Field('pressure');
final Uint16Field _statusField = Uint16Field('status');

final RecordLayout _telemetryLayout = RecordLayout(
  name: 'TelemetryRecord',
  fields: <Field<Object?>>[
    _timestampField,
    _temperatureField,
    _pressureField,
    _statusField,
  ],
);

void main() {
  runApp(const PulseSlabTelemetryApp());
}

/// A compact telemetry simulation that makes UI coalescing observable.
class PulseSlabTelemetryApp extends StatelessWidget {
  /// Creates the example application.
  const PulseSlabTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pulse Slab Telemetry',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff006c72),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _TelemetryDashboard(),
    );
  }
}

class _TelemetryDashboard extends StatefulWidget {
  const _TelemetryDashboard();

  @override
  State<_TelemetryDashboard> createState() => _TelemetryDashboardState();
}

class _TelemetryDashboardState extends State<_TelemetryDashboard> {
  static const int _sensorCount = 24;
  static const int _minimumUpdatesPerSecond = 200;
  static const int _maximumUpdatesPerSecond = 1000000;
  static const int _maximumTickBatch = 32768;

  final math.Random _random = math.Random(7);
  final Stopwatch _clock = Stopwatch();
  final ValueNotifier<int> _metricsTick = ValueNotifier<int>(0);
  final _TelemetryHistory _history = _TelemetryHistory(capacity: 180);

  late PulseStore _store;
  late List<RecordHandle> _handles;
  late _UiDeliveryMeter _uiDeliveryMeter;
  Timer? _inputTimer;
  Timer? _metricsTimer;
  var _isRunning = false;
  var _targetUpdatesPerSecond = 6000;
  var _processedUpdates = 0;
  var _simulatedSourceDrops = 0;
  var _widgetRebuilds = 0;
  var _lastReportedProcessedUpdates = 0;
  var _lastInputTickMicroseconds = 0;
  var _lastRateReportMicroseconds = 0;
  var _rateRemainder = 0;
  var _visibleUpdateRate = 0.0;
  var _lastJournalUtilization = 0.0;

  @override
  void initState() {
    super.initState();
    _createDataPlane();
    _metricsTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refreshMetrics(),
    );
  }

  void _createDataPlane() {
    _store = PulseStore(segmentCapacity: 128, journalCapacity: 1024);
    _handles = List<RecordHandle>.generate(
      _sensorCount,
      (_) => _store.allocate(_telemetryLayout),
      growable: false,
    );
    _uiDeliveryMeter = _UiDeliveryMeter(_store, _handles);
  }

  void _start() {
    if (_isRunning) {
      return;
    }
    _clock.start();
    _lastInputTickMicroseconds = _clock.elapsedMicroseconds;
    _lastRateReportMicroseconds = _clock.elapsedMicroseconds;
    setState(() {
      _isRunning = true;
    });
    _inputTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _processSimulationTick(),
    );
  }

  void _pause() {
    if (!_isRunning) {
      return;
    }
    _inputTimer?.cancel();
    _inputTimer = null;
    _clock.stop();
    setState(() {
      _isRunning = false;
      _visibleUpdateRate = 0.0;
    });
  }

  void _reset() {
    final resumeAfterReset = _isRunning;
    _pause();
    _uiDeliveryMeter.dispose();
    _store.dispose();
    _createDataPlane();
    _history.clear();
    _processedUpdates = 0;
    _simulatedSourceDrops = 0;
    _widgetRebuilds = 0;
    _lastReportedProcessedUpdates = 0;
    _visibleUpdateRate = 0.0;
    _lastJournalUtilization = 0.0;
    _rateRemainder = 0;
    _clock.reset();
    _lastInputTickMicroseconds = 0;
    _lastRateReportMicroseconds = 0;
    setState(() {});
    if (resumeAfterReset) {
      _start();
    }
  }

  void _processSimulationTick() {
    if (!_isRunning) {
      return;
    }
    final nowMicroseconds = _clock.elapsedMicroseconds;
    final elapsedMicroseconds = nowMicroseconds - _lastInputTickMicroseconds;
    _lastInputTickMicroseconds = nowMicroseconds;
    final requestedScaled =
        _rateRemainder + (elapsedMicroseconds * _targetUpdatesPerSecond);
    final requested = requestedScaled ~/ Duration.microsecondsPerSecond;
    _rateRemainder = requestedScaled % Duration.microsecondsPerSecond;
    final int updateCount = math.min(requested, _maximumTickBatch);
    if (requested > _maximumTickBatch) {
      _simulatedSourceDrops += requested - _maximumTickBatch;
      _rateRemainder = 0;
    }
    if (updateCount == 0) {
      return;
    }

    final timestamp = nowMicroseconds / Duration.microsecondsPerSecond;
    _store.transaction((transaction) {
      for (var update = 0; update < updateCount; update++) {
        final sensorIndex = _random.nextInt(_sensorCount);
        final phase = timestamp * (0.8 + sensorIndex * 0.03) + sensorIndex;
        final temperature = 23.0 + math.sin(phase) * 7.0 + _random.nextDouble();
        final pressure = 1.0 + math.cos(phase * 0.5) * 0.12;
        final status = (temperature > 28.5 ? 0x01 : 0) |
            (pressure < 0.93 ? 0x02 : 0) |
            (_random.nextInt(80) == 0 ? 0x04 : 0);
        final writer = transaction.write(_handles[sensorIndex]);
        writer
          ..set(_timestampField, timestamp)
          ..set(_temperatureField, temperature)
          ..set(_pressureField, pressure)
          ..set(_statusField, status);
        if (sensorIndex == 0) {
          _history.add(temperature);
        }
      }
    });
    _processedUpdates += updateCount;
  }

  void _refreshMetrics() {
    if (!mounted) {
      return;
    }
    final nowMicroseconds = _clock.elapsedMicroseconds;
    final elapsedMicroseconds = nowMicroseconds - _lastRateReportMicroseconds;
    if (elapsedMicroseconds > 0) {
      _visibleUpdateRate = (_processedUpdates - _lastReportedProcessedUpdates) *
          Duration.microsecondsPerSecond /
          elapsedMicroseconds;
    }
    _lastReportedProcessedUpdates = _processedUpdates;
    _lastRateReportMicroseconds = nowMicroseconds;
    _lastJournalUtilization = _store.journal.utilization;
    // This dashboard treats the journal as a sampled state monitor. It clears
    // replaceable state changes after observing utilization; it is not a
    // lossless domain-event consumer.
    _store.journal.clear();
    _metricsTick.value++;
  }

  @override
  void dispose() {
    _inputTimer?.cancel();
    _metricsTimer?.cancel();
    _uiDeliveryMeter.dispose();
    _store.dispose();
    _metricsTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pulse Slab telemetry data plane'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 16),
            child: Center(child: _RunningBadge(isRunning: _isRunning)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Every simulated input is written to compact record memory. '
                'Flutter sees only the latest useful field changes per frame.',
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<int>(
                valueListenable: _metricsTick,
                builder: (context, _, child) => _MetricGrid(
                  processedUpdates: _processedUpdates,
                  updateRate: _visibleUpdateRate,
                  uiDeliveredUpdates: _uiDeliveryMeter.deliveredUpdates,
                  coalescedUiUpdates: _uiDeliveryMeter.coalescedUpdates,
                  widgetRebuilds: _widgetRebuilds,
                  journalUtilization: _lastJournalUtilization,
                  journalOverwrites: _store.journal.overwrittenCount,
                  sourceDrops: _simulatedSourceDrops,
                ),
              ),
              const SizedBox(height: 16),
              _ControlCard(
                isRunning: _isRunning,
                targetUpdatesPerSecond: _targetUpdatesPerSecond,
                minimumUpdatesPerSecond: _minimumUpdatesPerSecond,
                maximumUpdatesPerSecond: _maximumUpdatesPerSecond,
                maximumTickBatch: _maximumTickBatch,
                onStart: _start,
                onPause: _pause,
                onReset: _reset,
                onRateChanged: (value) {
                  setState(() {
                    _targetUpdatesPerSecond = value.round();
                  });
                },
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<int>(
                valueListenable: _metricsTick,
                builder: (context, _, child) => _ChartCard(history: _history),
              ),
              const SizedBox(height: 16),
              Text(
                'Field-filtered record views',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              _SensorCards(
                store: _store,
                handles: _handles,
                onReactiveBuild: () {
                  _widgetRebuilds++;
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunningBadge extends StatelessWidget {
  const _RunningBadge({required this.isRunning});

  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    final color = isRunning ? Colors.greenAccent : Colors.orangeAccent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.circle, color: color, size: 12),
        const SizedBox(width: 6),
        Text(isRunning ? 'Running' : 'Paused'),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({
    required this.processedUpdates,
    required this.updateRate,
    required this.uiDeliveredUpdates,
    required this.coalescedUiUpdates,
    required this.widgetRebuilds,
    required this.journalUtilization,
    required this.journalOverwrites,
    required this.sourceDrops,
  });

  final int processedUpdates;
  final double updateRate;
  final int uiDeliveredUpdates;
  final int coalescedUiUpdates;
  final int widgetRebuilds;
  final double journalUtilization;
  final int journalOverwrites;
  final int sourceDrops;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _MetricTile('Input rate', '${updateRate.toStringAsFixed(0)} / s'),
        _MetricTile('Processed updates', '$processedUpdates'),
        _MetricTile('UI deliveries', '$uiDeliveredUpdates'),
        _MetricTile('UI coalesced', '$coalescedUiUpdates'),
        _MetricTile('Widget rebuilds', '$widgetRebuilds'),
        _MetricTile(
          'Journal utilization',
          '${(journalUtilization * 100).toStringAsFixed(0)}%',
        ),
        _MetricTile('Journal overwrites', '$journalOverwrites'),
        _MetricTile('Simulation drops', '$sourceDrops'),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 152,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlCard extends StatelessWidget {
  static const List<_RatePreset> _ratePresets = <_RatePreset>[
    _RatePreset('10k / s', 10000),
    _RatePreset('25k / s', 25000),
    _RatePreset('100k / s', 100000),
    _RatePreset('500k / s', 500000),
    _RatePreset('1M / s', 1000000),
  ];

  const _ControlCard({
    required this.isRunning,
    required this.targetUpdatesPerSecond,
    required this.minimumUpdatesPerSecond,
    required this.maximumUpdatesPerSecond,
    required this.maximumTickBatch,
    required this.onStart,
    required this.onPause,
    required this.onReset,
    required this.onRateChanged,
  });

  final bool isRunning;
  final int targetUpdatesPerSecond;
  final int minimumUpdatesPerSecond;
  final int maximumUpdatesPerSecond;
  final int maximumTickBatch;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onReset;
  final ValueChanged<double> onRateChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Simulation controls',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: isRunning ? null : onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: isRunning ? onPause : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Target input rate: $targetUpdatesPerSecond updates / second'),
            const SizedBox(height: 8),
            Text(
              'Quick load levels',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final preset in _ratePresets)
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: targetUpdatesPerSecond == preset.updatesPerSecond,
                    onSelected: (_) =>
                        onRateChanged(preset.updatesPerSecond.toDouble()),
                  ),
              ],
            ),
            Slider(
              min: minimumUpdatesPerSecond.toDouble(),
              max: maximumUpdatesPerSecond.toDouble(),
              value: targetUpdatesPerSecond.toDouble(),
              label: '$targetUpdatesPerSecond',
              onChanged: onRateChanged,
            ),
            Text(
              'Range: $minimumUpdatesPerSecond to '
              '$maximumUpdatesPerSecond updates / second. '
              'Per-tick cap: $maximumTickBatch updates; excess input is '
              'reported as simulation drops.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RatePreset {
  const _RatePreset(this.label, this.updatesPerSecond);

  final String label;
  final int updatesPerSecond;
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.history});

  final _TelemetryHistory history;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Sensor 0 temperature history',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              width: double.infinity,
              child: CustomPaint(painter: _TelemetryChartPainter(history)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SensorCards extends StatelessWidget {
  const _SensorCards({
    required this.store,
    required this.handles,
    required this.onReactiveBuild,
  });

  final PulseStore store;
  final List<RecordHandle> handles;
  final VoidCallback onReactiveBuild;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _TemperatureOnlyCard(
          store: store,
          handle: handles.first,
          onReactiveBuild: onReactiveBuild,
        ),
        for (var index = 1; index < math.min(handles.length, 9); index++)
          _MultiFieldCard(
            store: store,
            handle: handles[index],
            sensorIndex: index,
            onReactiveBuild: onReactiveBuild,
          ),
      ],
    );
  }
}

class _TemperatureOnlyCard extends StatelessWidget {
  const _TemperatureOnlyCard({
    required this.store,
    required this.handle,
    required this.onReactiveBuild,
  });

  final PulseStore store;
  final RecordHandle handle;
  final VoidCallback onReactiveBuild;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ReactiveRecordBuilder(
            store: store,
            handle: handle,
            fields: _temperatureField.mask,
            builder: (context, record) {
              onReactiveBuild();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Sensor 0',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${record.get(_temperatureField).toStringAsFixed(2)} C',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text('Subscribed to temperature only'),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MultiFieldCard extends StatelessWidget {
  const _MultiFieldCard({
    required this.store,
    required this.handle,
    required this.sensorIndex,
    required this.onReactiveBuild,
  });

  final PulseStore store;
  final RecordHandle handle;
  final int sensorIndex;
  final VoidCallback onReactiveBuild;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ReactiveRecordBuilder(
            store: store,
            handle: handle,
            fields: _temperatureField.mask | _statusField.mask,
            builder: (context, record) {
              onReactiveBuild();
              final status = record.get(_statusField);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Sensor $sensorIndex',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${record.get(_temperatureField).toStringAsFixed(2)} C',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text('Status 0x${status.toRadixString(16).padLeft(2, '0')}'),
                  const SizedBox(height: 6),
                  const Text('Subscribed to temperature + status'),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

final class _UiDeliveryMeter {
  _UiDeliveryMeter(PulseStore store, List<RecordHandle> handles) {
    for (final handle in handles) {
      final listenable = ReactiveRecordListenable(store: store, handle: handle);
      _listenables.add(listenable);
      listenable.addListener(() => _onDelivery(listenable));
    }
  }

  final List<ReactiveRecordListenable> _listenables =
      <ReactiveRecordListenable>[];
  final Map<ReactiveRecordListenable, int> _observedCoalescing =
      <ReactiveRecordListenable, int>{};
  var deliveredUpdates = 0;
  var coalescedUpdates = 0;

  void _onDelivery(ReactiveRecordListenable listenable) {
    deliveredUpdates++;
    final previous = _observedCoalescing[listenable] ?? 0;
    coalescedUpdates += listenable.coalescedChanges - previous;
    _observedCoalescing[listenable] = listenable.coalescedChanges;
  }

  void dispose() {
    for (final listenable in _listenables) {
      listenable.dispose();
    }
    _listenables.clear();
    _observedCoalescing.clear();
  }
}

final class _TelemetryHistory {
  _TelemetryHistory({required this.capacity}) : _values = Float32List(capacity);

  final int capacity;
  final Float32List _values;
  var _length = 0;
  var _writeIndex = 0;

  int get length => _length;

  void add(double value) {
    _values[_writeIndex] = value;
    _writeIndex = (_writeIndex + 1) % capacity;
    if (_length < capacity) {
      _length++;
    }
  }

  double oldestAt(int index) {
    final start = _length == capacity ? _writeIndex : 0;
    return _values[(start + index) % capacity];
  }

  void clear() {
    _values.fillRange(0, _values.length, 0);
    _length = 0;
    _writeIndex = 0;
  }
}

final class _TelemetryChartPainter extends CustomPainter {
  const _TelemetryChartPainter(this.history);

  final _TelemetryHistory history;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xff17383a);
    final grid = Paint()
      ..color = const Color(0xff80b8ba)
      ..strokeWidth = 1;
    final trace = Paint()
      ..color = const Color(0xff64f0dc)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      background,
    );
    for (var row = 1; row < 4; row++) {
      final y = size.height * row / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (history.length < 2) {
      return;
    }

    var minimum = history.oldestAt(0);
    var maximum = minimum;
    for (var index = 1; index < history.length; index++) {
      final value = history.oldestAt(index);
      minimum = math.min(minimum, value);
      maximum = math.max(maximum, value);
    }
    final range = math.max(maximum - minimum, 0.1);
    final path = Path();
    for (var index = 0; index < history.length; index++) {
      final x = size.width * index / (history.length - 1);
      final normalized = (history.oldestAt(index) - minimum) / range;
      final y = size.height - normalized * size.height;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, trace);
  }

  @override
  bool shouldRepaint(covariant _TelemetryChartPainter oldDelegate) => true;
}
