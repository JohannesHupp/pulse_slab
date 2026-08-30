# Pulse Slab Flutter telemetry example

This standalone Flutter application simulates 24 telemetry records at a
configurable rate of 200 to 1,000,000 updates per second. It is a focused visual
test bed for the pulse_slab_flutter adapter rather than a production dashboard.

Run it from this directory:

```sh
flutter run
```

Use **Start**, **Pause**, **Reset**, and the rate slider to control the source.
The dashboard distinguishes raw producer inputs, net committed record changes,
transaction-compacted inputs, frame deliveries, frame-coalesced changes, widget
rebuilds, journal utilization, journal overwrites or rejections, and
intentionally capped simulation batches.

The default **Merged transaction** mode processes a tick as one transaction,
so repeated writes to one sensor become one net record change. Select **Burst
transactions** to split a tick into several synchronous commits before Flutter
can flush a frame; the **Frame coalesced** metric then shows the extra commits
merged into one UI delivery.

The default **Sample and clear** journal mode records a 250 ms observation
window and clears it after the dashboard reads it. A steady percentage in that
mode is expected and does not represent a growing backlog. Select **Overwrite
pressure** or **Reject-newest pressure** to retain a small 64-entry journal and
observe its fixed-capacity policy. In reject-newest mode, state commits continue
even when new journal observations are rejected.

The simulation processes up to 32,768 updates in one timer tick. At very high
rates, excess requested updates are reported as simulation drops so the example
remains responsive enough to pause or reset.

Sensor 0 is subscribed to the temperature field only. The remaining cards
subscribe to temperature and status together. This makes it visible that a
pressure-only write does not rebuild either card type, while the core store can
continue processing every generated update.

All 24 sensor cards are shown in a two-column grid and remain mounted intentionally.
Every card contains a temperature chart backed by its own fixed `Float32List`
ring buffer. A history receives at most one latest-state sample per
frame-coalesced UI delivery, rather than one sample for every raw producer
input. This makes the screen a deliberate UI-load test without adding a chart
package or an unbounded history model.

The top-right FPS indicator is a recent rendered-frame-rate estimate derived
from Flutter engine timing records. It is sampled only while the simulation is
running and is most meaningful in profile or release mode; `FPS --` means no
current measurement is available.

The journal is a replaceable state-observation channel, not a lossless
domain-event consumer. Applications needing acknowledged events should use a
separate bounded, backpressured event protocol.
