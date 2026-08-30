# Delivery policy design

## Decision

Issue #15 makes the existing bounded state-delivery behavior explicit and
observable. It does not add a `DeliveryPolicy` value or a per-subscription FIFO
queue. A future ordered intermediate-state policy requires a measured use case
and a separate public-API decision.

All policies deliver observations of replaceable record state, never a lossless
event stream. A committed transaction is independent from journal admission and
from listener delivery: a full rejecting journal never rolls back a committed
record or suppresses its matching subscriptions.

## Shared dispatch rules

- A subscription belongs to one record handle. Matching is decided before the
  policy accepts a delivery, using its field mask or `FieldSelection`.
- Direct dispatch for one record follows registration order. A listener removed
  during a traversal is skipped if its turn has not yet arrived.
- Listener failures do not roll back state or stop the remaining eligible
  callbacks in that traversal. The first failure is rethrown with its original
  stack trace after the traversal finishes.
- Releasing a record or disposing its store deactivates its subscriptions and
  cancels their pending delivery work. Cancellation is lifecycle cleanup, not a
  policy drop.

## Policy semantics

| Policy | Retention and ordering | Fixed bound and overflow | Flush and reentrancy |
| --- | --- | --- | --- |
| `immediate` | A matching listener runs synchronously after its commit. Reentrant commits enqueue matching immediate calls in FIFO order after the active traversal. | Normal dispatch has no queue. Reentrant calls use the store-wide `maxReentrantImmediateDeliveries` ring. A full ring replaces its oldest pending call; the evicted subscription records one drop. | `flush()` does not deliver normal immediate calls. A reentrant `latest` or `batched` subscription is accepted by its own policy immediately instead of waiting for the immediate ring to drain. |
| `latest` | Each subscription retains one pending merged change. Later matching commits replace its version and union its changed fields; first-pending subscription order determines flush order. | One pending change per subscription. Replaced intermediate state increments that subscription's coalesced counter, never its dropped counter. | `flush()` takes the pending subscriptions present when it starts. Work created by a delivery callback waits for the next flush. Calling `flush()` from a latest or batched callback throws. |
| `batched` | Each matching commit becomes one queued delivery. The store-wide queue retains calls in arrival order across subscriptions and record handles. | The `maxBatchedDeliveries` ring bounds total retained deliveries. A full ring replaces its oldest queued call; the evicted subscription records one drop. | `flush()` drains the batch that existed when it started, after latest deliveries. Work enqueued by a delivery callback waits for the next flush, and a nested `flush()` from a latest or batched callback throws. |

The two store-wide rings bound retained listener work, not commits or record
state. Replacing an entry never rejects a transaction. Their retained order is
deterministic: only the oldest pending entry is displaced, and all retained
entries are delivered FIFO.

## Per-subscription metrics

`StoreSubscription` exposes direct scalar getters so callers can inspect one
subscription in constant time without a store-wide listener scan, snapshot
allocation, or metrics stream on the commit path.

| Getter | Meaning |
| --- | --- |
| `pendingDeliveries` | Current number of accepted deliveries waiting for this subscription. It is zero for normal immediate dispatch, at most one for latest delivery, and may be greater for batched or reentrant immediate delivery. It resets to zero when the subscription is deactivated. |
| `deliveredCount` | Monotonically increasing number of listener invocation attempts. An invocation that throws is still counted. |
| `coalescedCount` | Monotonically increasing number of matching commits merged into an already-pending latest delivery. |
| `droppedCount` | Monotonically increasing number of this subscription's pending calls evicted by an explicit full `maxBatchedDeliveries` or `maxReentrantImmediateDeliveries` ring. It excludes latest coalescing, field filtering, journal overwrite or rejection, and release/disposal cleanup. |

Journal metrics remain separate. `ChangeJournal.overwrittenCount`,
`ChangeJournal.rejectedCount`, and `PulseStore.rejectedJournalChangeCount`
describe journal admission only; they do not change any subscription delivery
metric.

## Performance boundary

Metric state is stored as primitive counters on each subscription and is updated
only while routing, evicting, dequeuing, or invoking that subscription. This
adds no global listener scan and creates no metric object in the hot path. The
existing fixed-size rings and latest slot remain the only delivery retention
storage.
