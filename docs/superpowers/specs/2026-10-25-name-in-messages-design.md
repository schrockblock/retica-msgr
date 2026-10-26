# Display name carried in messages — design

Date: 2026-10-25. Approved by the user in chat ("include the name the way photos do").

## Why

Today a display name reaches peers only in the delivery announce. Two things follow:
- A peer that isn't connected when the announce goes out never sees a name change. Backgrounded iPhones close their sockets.
- Re-hearing the announce needs the sender to reconnect.

The user confirmed this in practice: the name showed up only after waiting for an announce. Profile photos already solve the same problem by riding on outgoing messages until the peer confirms one. Names do the same.

## Behaviour

**Sending.** My current display name rides on every outgoing message to a peer until that peer confirms delivery of a message carrying it. Confirmed means delivered, or stored at a propagation node, using the same outcomes that settle `ProfilePhotoDelivery`. After that, nothing rides until the name changes.
- A cleared name (empty) rides as "no name", but only if a non-empty name was ever confirmed to that peer.
- Group posts go out as one message per member, so each member's copy follows the same rule. Apply the name plan everywhere `ProfilePhotoOutbox.plan` is applied today: direct sends, group fan-out, and resend paths.

**Wire.**
- Field `0xA1`: our own key, next to the photo's `0xA0`.
- Value: `bin(UTF-8 name)`, trimmed. An empty bin means "no name".
- Names longer than 128 bytes are not sent: truncate at a character boundary before sending.
- On receipt:
  - a field longer than 128 bytes, or not valid UTF-8, is ignored;
  - the field is honoured only on signature-validated messages, as with the photo.

**Receiving.**
- The name is stored on the peer's `PeerProfile` (new columns `name`, `nameSetAt`).
- `setAt` is the message's sender timestamp, capped at arrival, the photo rule.
- Newer wins: an older message arriving late never overwrites a newer name.
- A cleared name stores as an empty name with its `setAt`.

**Which name is shown** (`peerDisplayName`):
1. A linked contact's name, unchanged.
2. Otherwise the newer of:
   - the message-carried name (by `nameSetAt`);
   - the announce name (by `learnedPeers[...].learnedAt`).
3. An empty winner means no name, so the existing "Them" / hex fallbacks apply.

**Interop.** Other LXMF clients ignore unknown fields and keep using the announce. The announce is still sent exactly as today.

## Shape (builder's call within these lines)

- **Codec:** `ProfileWire` gains `fieldDisplayName = 0xA1`, an encoder and a decoder. Or use a sibling `NameWire`, whichever reads better next to the photo codec.
- **Planning:** a pure `ProfileNameOutbox.plan(myName:delivery:) -> (fields, pendingName?)`, like `ProfilePhotoOutbox.plan`.
- **Delivery tracking:** either a new `profileNameDeliveries(peerHex, deliveredName, pendingName, pendingHash)` table mirroring `ProfilePhotoDelivery`, or name columns on that table. Either way it is settled at exactly the call sites that settle photos: delivered, stored, failed, cancelled, and the resend helpers. At launch, pending entries are cleared the same way (`clearAllPending`).
- **Migration:** new columns and a new table only; no backfill.

## Non-goals

- Changing the announce or its timing.
- Names in group control or roster messages beyond what posts already carry.
- Any UI change: the name simply appears where peer names already appear.

## Tests

- TestStore and unit tests:
  - the plan: rides until confirmed, stops after, rides again after a change, a clear after a delivered name, and no clear when nothing was delivered;
  - decode limits;
  - newer-wins on receipt;
  - display precedence: contact, then the newer of message and announce.
- Every new test is mutation-verified, per the user's three-step rule.
