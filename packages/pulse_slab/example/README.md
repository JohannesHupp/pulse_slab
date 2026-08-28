# Pulse Slab telemetry example

This standalone Flutter application simulates 24 telemetry records at a
configurable rate of 200 to 1,000,000 updates per second. It is a focused visual
test bed for the package rather than a production dashboard.

Run it from this directory:

```sh
flutter run
```

Use **Start**, **Pause**, **Reset**, and the rate slider to control the source.
The dashboard reports processed input updates, frame-delivered UI updates,
coalesced UI updates, widget rebuilds, journal utilization, bounded-journal
overwrites, and intentionally capped simulation batches.

The simulation processes up to 32,768 updates in one timer tick. At very high
rates, excess requested updates are reported as simulation drops so the example
remains responsive enough to pause or reset.

Sensor 0 is subscribed to the temperature field only. The remaining cards
subscribe to temperature and status together. This makes it visible that a
pressure-only write does not rebuild either card type, while the core store can
continue processing every generated update.

The temperature line is drawn with `CustomPainter` and a fixed `Float32List`
ring buffer, so the example does not add a chart package or a high-allocation
history model.

The dashboard samples then clears the replaceable state journal for display.
It is not a lossless domain-event consumer; applications needing acknowledged
events should use a separate bounded, backpressured event protocol.
