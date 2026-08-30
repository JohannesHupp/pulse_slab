import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

import 'src/frame_rate_monitor.dart';
import 'src/telemetry_simulation.dart';

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

  final Stopwatch _clock = Stopwatch();
  final ValueNotifier<int> _metricsTick = ValueNotifier<int>(0);

  late TelemetrySimulation _simulation;
  late TelemetryJournalSample _lastJournalSample;
  late _UiDeliveryMeter _uiDeliveryMeter;
  late final FrameRateMonitor _frameRateMonitor;
  Timer? _inputTimer;
  Timer? _metricsTimer;
  var _isRunning = false;
  var _targetUpdatesPerSecond = 6000;
  var _simulatedSourceDrops = 0;
  var _widgetRebuilds = 0;
  var _lastReportedProcessedUpdates = 0;
  var _lastInputTickMicroseconds = 0;
  var _lastRateReportMicroseconds = 0;
  var _rateRemainder = 0;
  var _visibleUpdateRate = 0.0;
  var _transactionMode = TelemetryTransactionMode.merged;
  var _journalMode = TelemetryJournalMode.sampled;

  @override
  void initState() {
    super.initState();
    _frameRateMonitor = FrameRateMonitor();
    _createDataPlane();
    _metricsTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refreshMetrics(),
    );
  }

  void _createDataPlane() {
    _simulation = TelemetrySimulation(
      configuration: TelemetrySimulationConfiguration(
        sensorCount: _sensorCount,
        transactionMode: _transactionMode,
        journalMode: _journalMode,
      ),
    );
    _lastJournalSample = _simulation.sampleJournal();
    _uiDeliveryMeter = _UiDeliveryMeter();
  }

  void _start() {
    if (_isRunning) {
      return;
    }
    _frameRateMonitor.start();
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
    _frameRateMonitor.stop();
    _clock.stop();
    setState(() {
      _isRunning = false;
      _visibleUpdateRate = 0.0;
    });
  }

  void _reset({
    TelemetryTransactionMode? transactionMode,
    TelemetryJournalMode? journalMode,
  }) {
    final resumeAfterReset = _isRunning;
    _pause();
    if (transactionMode != null) {
      _transactionMode = transactionMode;
    }
    if (journalMode != null) {
      _journalMode = journalMode;
    }
    _simulation.dispose();
    _createDataPlane();
    _simulatedSourceDrops = 0;
    _widgetRebuilds = 0;
    _lastReportedProcessedUpdates = 0;
    _visibleUpdateRate = 0.0;
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
    _simulation.processBatch(
      rawInputCount: updateCount,
      timestamp: timestamp,
    );
  }

  void _refreshMetrics() {
    if (!mounted) {
      return;
    }
    final nowMicroseconds = _clock.elapsedMicroseconds;
    final elapsedMicroseconds = nowMicroseconds - _lastRateReportMicroseconds;
    if (elapsedMicroseconds > 0) {
      _visibleUpdateRate =
          (_simulation.rawInputUpdateCount - _lastReportedProcessedUpdates) *
              Duration.microsecondsPerSecond /
              elapsedMicroseconds;
    }
    _lastReportedProcessedUpdates = _simulation.rawInputUpdateCount;
    _lastRateReportMicroseconds = nowMicroseconds;
    _lastJournalSample = _simulation.sampleJournal();
    _metricsTick.value++;
  }

  @override
  void dispose() {
    _inputTimer?.cancel();
    _metricsTimer?.cancel();
    _frameRateMonitor.dispose();
    _simulation.dispose();
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
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _FrameRateBadge(
                    framesPerSecond: _frameRateMonitor.framesPerSecond,
                  ),
                  const SizedBox(width: 12),
                  _RunningBadge(isRunning: _isRunning),
                ],
              ),
            ),
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
                  rawInputUpdates: _simulation.rawInputUpdateCount,
                  committedRecordChanges:
                      _simulation.committedRecordChangeCount,
                  transactionCompactedInputs:
                      _simulation.transactionCompactedInputCount,
                  lastTickDistinctRecords: _simulation.lastTickDistinctRecords,
                  updateRate: _visibleUpdateRate,
                  frameDeliveredUpdates: _uiDeliveryMeter.deliveredUpdates,
                  frameCoalescedUpdates: _uiDeliveryMeter.coalescedUpdates,
                  widgetRebuilds: _widgetRebuilds,
                  journalSample: _lastJournalSample,
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
                transactionMode: _transactionMode,
                journalMode: _journalMode,
                onStart: _start,
                onPause: _pause,
                onReset: _reset,
                onTransactionModeChanged: (mode) {
                  _reset(transactionMode: mode);
                },
                onJournalModeChanged: (mode) {
                  _reset(journalMode: mode);
                },
                onRateChanged: (value) {
                  setState(() {
                    _targetUpdatesPerSecond = value.round();
                  });
                },
              ),
              const SizedBox(height: 16),
              _MetricExplanationCard(
                transactionMode: _transactionMode,
                journalMode: _journalMode,
              ),
              const SizedBox(height: 16),
              Text(
                'All 24 field-filtered sensor views',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text(
                'This two-column, non-virtualized grid intentionally keeps '
                'all 24 charts and subscriptions mounted to create visible '
                'UI load.',
              ),
              const SizedBox(height: 8),
              _SensorTelemetryGrid(
                store: _simulation.store,
                handles: _simulation.handles,
                deliveryMeter: _uiDeliveryMeter,
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

class _FrameRateBadge extends StatelessWidget {
  const _FrameRateBadge({required this.framesPerSecond});

  final ValueListenable<int?> framesPerSecond;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: framesPerSecond,
      builder: (context, framesPerSecond, child) {
        final label =
            framesPerSecond == null ? 'FPS --' : 'FPS $framesPerSecond';
        return Semantics(
          label: framesPerSecond == null
              ? 'Rendered frame rate is not currently sampled.'
              : 'Rendered frame rate: $framesPerSecond frames per second.',
          child: Tooltip(
            message:
                'Rendered frame-rate estimate from completed Flutter frames.',
            child: Text(label),
          ),
        );
      },
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({
    required this.rawInputUpdates,
    required this.committedRecordChanges,
    required this.transactionCompactedInputs,
    required this.lastTickDistinctRecords,
    required this.updateRate,
    required this.frameDeliveredUpdates,
    required this.frameCoalescedUpdates,
    required this.widgetRebuilds,
    required this.journalSample,
    required this.sourceDrops,
  });

  final int rawInputUpdates;
  final int committedRecordChanges;
  final int transactionCompactedInputs;
  final int lastTickDistinctRecords;
  final double updateRate;
  final int frameDeliveredUpdates;
  final int frameCoalescedUpdates;
  final int widgetRebuilds;
  final TelemetryJournalSample journalSample;
  final int sourceDrops;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _MetricTile('Input rate', '${updateRate.toStringAsFixed(0)} / s'),
        _MetricTile('Raw inputs', '$rawInputUpdates'),
        _MetricTile('Committed records', '$committedRecordChanges'),
        _MetricTile(
          'Transaction-compacted inputs',
          '$transactionCompactedInputs',
        ),
        _MetricTile('Distinct records / tick', '$lastTickDistinctRecords'),
        _MetricTile('Frame deliveries', '$frameDeliveredUpdates'),
        _MetricTile('Frame coalesced', '$frameCoalescedUpdates'),
        _MetricTile('Widget rebuilds', '$widgetRebuilds'),
        _MetricTile(
          'Journal utilization',
          '${(journalSample.utilization * 100).toStringAsFixed(0)}%',
        ),
        _MetricTile(
          'Journal retained',
          '${journalSample.length} / ${journalSample.capacity}',
        ),
        _MetricTile('Journal overwrites', '${journalSample.overwrittenCount}'),
        _MetricTile('Journal rejected', '${journalSample.rejectedCount}'),
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
    required this.transactionMode,
    required this.journalMode,
    required this.onStart,
    required this.onPause,
    required this.onReset,
    required this.onTransactionModeChanged,
    required this.onJournalModeChanged,
    required this.onRateChanged,
  });

  final bool isRunning;
  final int targetUpdatesPerSecond;
  final int minimumUpdatesPerSecond;
  final int maximumUpdatesPerSecond;
  final int maximumTickBatch;
  final TelemetryTransactionMode transactionMode;
  final TelemetryJournalMode journalMode;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onReset;
  final ValueChanged<TelemetryTransactionMode> onTransactionModeChanged;
  final ValueChanged<TelemetryJournalMode> onJournalModeChanged;
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
            const SizedBox(height: 16),
            Text(
              'Transaction mode',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final mode in TelemetryTransactionMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: transactionMode == mode,
                    onSelected: (_) => onTransactionModeChanged(mode),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              transactionMode.description,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Journal observation mode',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final mode in TelemetryJournalMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: journalMode == mode,
                    onSelected: (_) => onJournalModeChanged(mode),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${journalMode.description} Capacity: ${journalMode.capacity}; '
              'policy: ${journalMode.overflowPolicy.name}.',
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

class _MetricExplanationCard extends StatelessWidget {
  const _MetricExplanationCard({
    required this.transactionMode,
    required this.journalMode,
  });

  final TelemetryTransactionMode transactionMode;
  final TelemetryJournalMode journalMode;

  @override
  Widget build(BuildContext context) {
    final journalExplanation = journalMode.clearsAfterSampling
        ? 'Journal utilization is sampled every 250 ms and then cleared. It '
            'is a recent observation window, not a growing backlog.'
        : journalMode.overflowPolicy == JournalOverflowPolicy.overwriteOldest
            ? 'Journal observations are retained until the fixed capacity is '
                'reached. Older state observations are overwritten.'
            : 'Journal observations are retained until the fixed capacity is '
                'reached. Newer state observations are rejected from the journal; '
                'record commits still continue.';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'How to read the metrics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Raw inputs are producer samples. Committed records are net '
              'record changes. Transaction-compacted inputs did not become '
              'independent record commits; they are not lost data.',
            ),
            const SizedBox(height: 6),
            Text(
              'Frame coalesced counts committed changes merged before a '
              'Flutter delivery. Select Burst transactions to generate '
              'several synchronous commits before Flutter can flush a frame.',
            ),
            const SizedBox(height: 6),
            Text(
              journalExplanation,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Current transaction mode: ${transactionMode.label}.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SensorTelemetryGrid extends StatelessWidget {
  const _SensorTelemetryGrid({
    required this.store,
    required this.handles,
    required this.deliveryMeter,
    required this.onReactiveBuild,
  });

  final PulseStore store;
  final List<RecordHandle> handles;
  final _UiDeliveryMeter deliveryMeter;
  final VoidCallback onReactiveBuild;

  static const _columnCount = 2;
  static const _columnSpacing = 12.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (var firstSensorIndex = 0;
            firstSensorIndex < handles.length;
            firstSensorIndex += _columnCount) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _buildCard(firstSensorIndex)),
              const SizedBox(width: _columnSpacing),
              Expanded(
                child: firstSensorIndex + 1 < handles.length
                    ? _buildCard(firstSensorIndex + 1)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          if (firstSensorIndex + _columnCount < handles.length)
            const SizedBox(height: _columnSpacing),
        ],
      ],
    );
  }

  Widget _buildCard(int sensorIndex) {
    return _SensorTelemetryCard(
      key: ValueKey<String>('sensor-card-$sensorIndex'),
      store: store,
      handle: handles[sensorIndex],
      sensorIndex: sensorIndex,
      deliveryMeter: deliveryMeter,
      onReactiveBuild: onReactiveBuild,
    );
  }
}

class _SensorTelemetryCard extends StatefulWidget {
  const _SensorTelemetryCard({
    required this.store,
    required this.handle,
    required this.sensorIndex,
    required this.deliveryMeter,
    required this.onReactiveBuild,
    super.key,
  });

  final PulseStore store;
  final RecordHandle handle;
  final int sensorIndex;
  final _UiDeliveryMeter deliveryMeter;
  final VoidCallback onReactiveBuild;

  @override
  State<_SensorTelemetryCard> createState() => _SensorTelemetryCardState();
}

class _SensorTelemetryCardState extends State<_SensorTelemetryCard> {
  static const _historyCapacity = 180;

  late final _TelemetryHistory _history;
  late ReactiveRecordListenable _listenable;
  var _temperature = 0.0;
  var _status = 0;
  var _observedCoalescedChanges = 0;

  int get _fields => widget.sensorIndex == 0
      ? TelemetrySchema.temperature.mask
      : TelemetrySchema.temperature.mask | TelemetrySchema.status.mask;

  bool get _isTemperatureOnly => widget.sensorIndex == 0;

  @override
  void initState() {
    super.initState();
    _history = _TelemetryHistory(capacity: _historyCapacity);
    _bind();
  }

  @override
  void didUpdateWidget(covariant _SensorTelemetryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store || oldWidget.handle != widget.handle) {
      _unbind();
      _history.clear();
      _bind();
    }
  }

  void _bind() {
    _observedCoalescedChanges = 0;
    _listenable = ReactiveRecordListenable(
      store: widget.store,
      handle: widget.handle,
      fields: _fields,
    );
    _readLatestRecord();
    _listenable.addListener(_onDelivery);
  }

  void _unbind() {
    _listenable.removeListener(_onDelivery);
    _listenable.dispose();
  }

  void _readLatestRecord() {
    final record = _listenable.value;
    _temperature = record.get(TelemetrySchema.temperature);
    if (!_isTemperatureOnly) {
      _status = record.get(TelemetrySchema.status);
    }
  }

  void _onDelivery() {
    if (!mounted || !_listenable.isRecordAvailable) {
      return;
    }
    final previousTemperature = _temperature;
    _readLatestRecord();
    if (_temperature != previousTemperature) {
      _history.add(_temperature);
    }
    final coalescedChangeDelta =
        _listenable.coalescedChanges - _observedCoalescedChanges;
    _observedCoalescedChanges = _listenable.coalescedChanges;
    widget.deliveryMeter.recordDelivery(
      coalescedChanges: coalescedChangeDelta,
    );
    widget.onReactiveBuild();
    setState(() {});
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subscriptionLabel = _isTemperatureOnly
        ? 'Subscribed to temperature only'
        : 'Subscribed to temperature + status';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Sensor ${widget.sensorIndex}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  subscriptionLabel,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_temperature.toStringAsFixed(2)} C',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (!_isTemperatureOnly) ...<Widget>[
              const SizedBox(height: 4),
              Text('Status 0x${_status.toRadixString(16).padLeft(2, '0')}'),
            ],
            const SizedBox(height: 10),
            Text(
              'Temperature history (latest $_historyCapacity UI samples)',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            RepaintBoundary(
              child: SizedBox(
                height: 120,
                width: double.infinity,
                child: CustomPaint(
                  key: ValueKey<String>('sensor-chart-${widget.sensorIndex}'),
                  painter: _TelemetryChartPainter(
                    _history,
                    revision: _history.revision,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _UiDeliveryMeter {
  var deliveredUpdates = 0;
  var coalescedUpdates = 0;

  void recordDelivery({required int coalescedChanges}) {
    deliveredUpdates++;
    coalescedUpdates += coalescedChanges;
  }
}

final class _TelemetryHistory {
  _TelemetryHistory({required this.capacity}) : _values = Float32List(capacity);

  final int capacity;
  final Float32List _values;
  var _length = 0;
  var _writeIndex = 0;
  var _revision = 0;

  int get length => _length;

  int get revision => _revision;

  void add(double value) {
    _values[_writeIndex] = value;
    _writeIndex = (_writeIndex + 1) % capacity;
    if (_length < capacity) {
      _length++;
    }
    _revision++;
  }

  double oldestAt(int index) {
    final start = _length == capacity ? _writeIndex : 0;
    return _values[(start + index) % capacity];
  }

  void clear() {
    _values.fillRange(0, _values.length, 0);
    _length = 0;
    _writeIndex = 0;
    _revision++;
  }
}

final class _TelemetryChartPainter extends CustomPainter {
  const _TelemetryChartPainter(this.history, {required this.revision});

  final _TelemetryHistory history;
  final int revision;

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
  bool shouldRepaint(covariant _TelemetryChartPainter oldDelegate) {
    return !identical(oldDelegate.history, history) ||
        oldDelegate.revision != revision;
  }
}
