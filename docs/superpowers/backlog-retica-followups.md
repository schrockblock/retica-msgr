# Backlog: ReTiCA-side follow-ups

**Started:** 2026-09-26. These are items deliberately left out of app-only features so they could
ship without a second repo. Each one needs a ReTiCA change (worktree + merge-order: ReTiCA first,
app immediately after, because the app depends on `../../../pods/ReTiCA` by path).

## Surface more per-message metadata to the app (deferred from the message Info feature)

The Info sheet (2026-09-26 spec) shows everything the app can already see. These three would make
it a better mesh-debugging tool but are dropped inside ReTiCA before the app hears about a message:

- **Hop count.** How many relays the inbound packet crossed. Transport knows `packet.hops` when it
  delivers; `Transport.Delegate.received` / `TransportEndpoint.messageReceived` /
  `LXMFNode.Delegate.messageReceived` would each need to carry it. (Propagated downloads have no
  meaningful hop count — report nil.)
- **Arrival interface.** Which interface the message came in on (TCP, BLE peer, listener).
  `TransportEndpoint.messageReceived` already carries `interfaceID` since the proofs work;
  `LXMFNode.Delegate.messageReceived` doesn't pass it up. Consider mapping `InterfaceID` to a
  human-readable label (e.g. "TCP 127.0.0.1:4242", "BLE ab12…").
- **Retry count for outgoing messages.** How many attempts a copy took before it was confirmed or
  failed. `LXMFRouter.pendingDeliveries[key].attempts` has it, but the entry is removed on
  success/failure; `deliveryConfirmed` / `propagationAccepted` / `deliveryFailed` would need an
  `attempts:` value (per copy).

## Delivery-status correctness (left from the single-packet proofs work)

See ReTiCA spec `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`, "Amendments at
planning time", item 3.

- **False "failed" with a propagation node configured.** While the propagated copy sits in
  LXMFNode's propagation-node stamp search, `LXMFRouter.isOutstanding` doesn't count it, so if the
  delivery copy runs out first, `deliveryFailed` fires (and can fire again if the propagated copy
  later fails). The app then shows "failed" until "stored" overwrites it. Fix: a "propagated copy
  pending" marker registered when the search starts, honoured by `isOutstanding`, cleared when the
  copy is armed (or via `fail` on `cancelPropagationStamps`).
- **Delivery-stamp search gaps.** `.cancelDeliveryStamps` emits `deliveryFailed` directly
  (bypassing `fail`), and a delivery copy still in its stamp search isn't counted as outstanding.
  Affects peers with a delivery stamp cost.
- **Late proof after the last retry.** A proof arriving after the final `retryDue` already failed
  the delivery copy is dropped (`succeed` guard). Reference would still mark it delivered. Consider
  letting a late `opportunisticDelivered` for a recently failed hash emit `deliveryConfirmed`.
- **Unreceipted direct link sends.** Small messages sent over an established link (`sendOverLink`)
  get no receipt, so they resend and end in a false `deliveryFailed`. (Pre-existing.)
- **Relay proof routing.** A ReTiCA node in relay mode doesn't route proofs for third parties (no
  reverse table). (Reference gap-analysis §1.6, relay half.)
