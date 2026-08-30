import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

void runReactiveRecordBuilderTests() {
  group('ReactiveRecordBuilder', () {
    testWidgets('rebuilds only the widget whose selected field changed', (
      tester,
    ) async {
      final temperature = Float32Field('temperature');
      final status = Uint16Field('status');
      final pressure = Float32Field('pressure');
      final layout = RecordLayout(
        name: 'Telemetry',
        fields: <Field<Object?>>[temperature, status, pressure],
      );
      final store = PulseStore();
      final handle = store.allocate(layout);
      addTearDown(store.dispose);
      var temperatureBuilds = 0;
      var statusBuilds = 0;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: <Widget>[
              ReactiveRecordBuilder(
                store: store,
                handle: handle,
                fields: temperature.mask,
                builder: (context, record) {
                  temperatureBuilds++;
                  return Text('temperature ${record.get(temperature)}');
                },
              ),
              ReactiveRecordBuilder(
                store: store,
                handle: handle,
                fields: status.mask,
                builder: (context, record) {
                  statusBuilds++;
                  return Text('status ${record.get(status)}');
                },
              ),
            ],
          ),
        ),
      );

      expect(temperatureBuilds, 1);
      expect(statusBuilds, 1);

      store.update(handle, (writer) {
        writer.set(temperature, 21.5);
      });
      store.update(handle, (writer) {
        writer.set(temperature, 22.5);
      });
      await tester.pump();

      expect(temperatureBuilds, 2);
      expect(statusBuilds, 1);
      expect(find.text('temperature 22.5'), findsOneWidget);

      store.update(handle, (writer) {
        writer.set(status, 3);
      });
      await tester.pump();

      expect(temperatureBuilds, 2);
      expect(statusBuilds, 2);

      store.update(handle, (writer) {
        writer.set(pressure, 1.12);
      });
      await tester.pump();

      expect(temperatureBuilds, 2);
      expect(statusBuilds, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('manual record delivery remains deterministic', (tester) async {
      final temperature = Float32Field('temperature');
      final layout = RecordLayout(
        name: 'ManualTelemetry',
        fields: <Field<Object?>>[temperature],
      );
      final store = PulseStore();
      final handle = store.allocate(layout);
      final listenable = ReactiveRecordListenable(
        store: store,
        handle: handle,
        fields: temperature.mask,
        policy: FlutterDeliveryPolicy.manual,
      );
      addTearDown(() {
        listenable.dispose();
        store.dispose();
      });
      var notifications = 0;
      listenable.addListener(() {
        notifications++;
      });

      store.update(handle, (writer) {
        writer.set(temperature, 30.0);
      });
      await tester.pump();

      expect(notifications, 0);
      expect(listenable.pendingFieldMask, temperature.mask);
      expect(listenable.flush(), isTrue);
      expect(notifications, 1);
      expect(listenable.value.get(temperature), 30.0);
    });

    testWidgets('rebuilds unavailableBuilder after the record is released', (
      tester,
    ) async {
      final temperature = Float32Field('temperature');
      final layout = RecordLayout(
        name: 'ReleasedTelemetry',
        fields: <Field<Object?>>[temperature],
      );
      final store = PulseStore();
      final handle = store.allocate(layout);
      addTearDown(store.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ReactiveRecordBuilder(
            store: store,
            handle: handle,
            fields: temperature.mask,
            builder: (context, record) =>
                Text('temperature ${record.get(temperature)}'),
            unavailableBuilder: (context, error) =>
                const Text('record unavailable'),
          ),
        ),
      );

      expect(find.text('temperature 0.0'), findsOneWidget);

      store.release(handle);
      await tester.pump();

      expect(find.text('record unavailable'), findsOneWidget);
    });

    testWidgets('filters a selected field beyond the legacy mask limit', (
      tester,
    ) async {
      final fields = List<Uint8Field>.generate(
        33,
        (index) => Uint8Field('field$index'),
      );
      final layout = RecordLayout(name: 'WideTelemetry', fields: fields);
      final store = PulseStore();
      final handle = store.allocate(layout);
      addTearDown(store.dispose);
      final watched = fields[32];
      final selection = layout.selectionFor(<Field<Object?>>[watched]);
      var builds = 0;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ReactiveRecordBuilder(
            store: store,
            handle: handle,
            selection: selection,
            builder: (context, record) {
              builds++;
              return Text('watched ${record.get(watched)}');
            },
          ),
        ),
      );

      expect(builds, 1);
      store.update(handle, (writer) {
        writer.set(fields[31], 7);
      });
      await tester.pump();

      expect(builds, 1);
      store.update(handle, (writer) {
        writer.set(watched, 9);
      });
      await tester.pump();

      expect(builds, 2);
      expect(find.text('watched 9'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
