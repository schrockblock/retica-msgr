# Message forgery fixes: design

Date: 2026-10-28. Source: the Fable security review of 2026-10-26, Findings 1 and 2, both High.

## Why

The review found two ways for a remote party to make a message appear to come from someone it didn't:

1. **A forged sender looks genuine.** An LXMF message whose signature can't be verified, either because it is bad or because the sender's key is unknown, is still delivered. The app files it in the claimed sender's chat, looking exactly like a real message. The only sign is "Not validated" on the Info sheet. Anyone who can get a packet to the user can impersonate a contact this way: a hub peer, the hub operator, a relay, or a BLE or Meshtastic neighbour.
2. **A message signed for someone else is accepted.** On the link (`.direct`) and propagation (`.propagated`) paths, nothing checks that the message's `destinationHash` is ours. So Bob's genuine signed message to Carol, handed to Alice by Carol or anyone holding it, verifies as Bob, is accepted as *validated*, and its fields apply: the expiry timer, name and photo.

## Behaviour (decided with the user)

**A known sender with a bad signature:** drop the message. The router knows the claimed sender's identity, and the signature doesn't verify, so nothing reaches the app. It is not marked seen, so a forged copy can't block the genuine message later. Where ReTiCA's structure allows it, the packet is not proved either. See the builder's calls below.

**A message not addressed to us:** drop it. After unpacking, a `.direct` or `.propagated` message whose `destinationHash` is not our lxmf.delivery hash goes nowhere. The opportunistic path already takes the destination from our own packet header, so it is unaffected.

**An unknown sender, so the signature can't be checked:** show the message, marked. The user chose this over holding it back or putting it in a separate list. Details:
- It appears in the claimed sender's chat as today, with an unmistakable **"Unverified sender"** marker on the bubble.
- Its row in the chat list shows the marker too, when it's the latest message.
- It is excluded from the unread badge and the per-row unread count.
- As today, its fields don't apply: name, photo, expiry, group control and reactions all require `validated`.
- **It turns verified automatically.** When that sender's identity becomes known (an announce, or a path response), the app re-checks each stored unverified message from them:
  - a good signature sets `validated = true` and the marker goes;
  - a bad one deletes the message, because it was a forgery.
  - Either way, withheld fields are **not** applied after the fact. Later messages carry them again.
- Rows stored before this change (`validated = false`, with no stored bytes) show the marker and can't be re-checked. That's acceptable.

## Shape (builder's call within these lines)

### ReTiCA (`LXMFRouter`/`LXMFNode`)

- **`.received` gets the real local destination.**
  - `.direct`: the link's local destination (`linkDestinations[linkID]` or equivalent).
  - `.propagated`: `deliveryDestinationHash`.
  - The `Data()` placeholders go.
- **The order of checks in `.received`:**
  1. unpack;
  2. the destination check (direct and propagated only);
  3. the signature check against `knownIdentities`. When the identity is known and the signature fails, drop it and send a new delegate, e.g. `.forgeryDropped(hash:)`, so the app can log it;
  4. only then `seen.insert`.

  Valid, and unknown-sender, messages are delivered as today.
- **The opportunistic proof:** if the proof is sent before the router decides (`LXMFNode.swift` ~817-830), and moving it after validation is a small, contained change, do it. Otherwise leave it and note it, since a proof reveals only that the packet arrived.
- **For the app's re-check**, the delivered `LXMessage` must expose what re-validation needs. Its `packed` bytes and `validateSignature(source:)` already exist, so the app can store `packed` and later call `LXMessage.unpack(packed)?.validateSignature(source:)`.
- **Tests** go in ReTiCA's suite, mutation-verified:
  - a known identity with a bad signature is dropped, not seen, and the delegate fires;
  - a direct or propagated message to someone else's destination is dropped;
  - a direct or propagated message to us still works;
  - an unknown sender is delivered unvalidated.

### App (`ReTiCAMsgrCore`)

- **Migration `addUnverifiedPacked`:** a nullable BLOB column on `messages` holding the packed bytes. It is set only for incoming rows stored with `validated = false`.
- **Re-check:** on `.pathLearned` (or the existing learned-peer update) for a hash with stored unverified rows, look up the identity in `endpoint.learned`. For each row, unpack and validate:
  - valid: set `validated = true` and clear the stored bytes;
  - invalid: delete the row (reuse the deletion helper so attachments go too).

  Then reload the thread and list, and recompute the badge.
- **Badge and per-row unread counts:** add `m.validated = 1` for incoming rows in `UnreadCount.count` and `perConversation`.
- **Views:** in `ChatView`, incoming bubbles with `validated == false` get an "Unverified sender" label (an exclamation shield and caption text, in an orange or red tone; the builder picks). In `ConversationListView`, when the latest message is unverified, the preview line shows the same marker. The Info sheet's existing "Not validated" stays.
- **Tests:**
  - a TestStore test: an unknown sender is stored unverified with its packed bytes, and is excluded from the count;
  - a later identity arrival with a good signature makes it validated and counted;
  - a later identity arrival with a bad signature deletes the row;
  - the count excludes unverified rows.

  All of them are mutation-verified.

## Settled details (my calls, from the builder check)

1. **"Our destination" is `deliveryDestinationHash` on both paths.** For `.direct` and `.propagated`, `message.destinationHash` must equal the node's lxmf.delivery hash. If that is nil (not registered yet), drop the message.
   - It does not compare against `linkDestinations[linkID]`, which holds the remote hash on our own outbound links.
   - A message addressed to us is accepted on whatever link it arrives on, delivery link or not, so legitimate replies over our outbound links still work.
2. **An unknown-sender message is still marked seen,** as today. A junk-signature copy could block the genuine message only if the attacker already has the plaintext of a message addressed to this user, before the user does. Group copies are addressed per member, so in practice only the real sender could do this. That's out of scope, and noted here.
3. **The unverified store is bounded by size.** The packed bytes are stored only when they are ≤ 256 KB. A larger unverified message is kept but can never be re-checked, so its marker stays.
   - The number of unverified rows isn't capped. That matches today: anyone can already put rows in the list, and this change makes them visibly unverified and keeps them out of the badge.
4. **When the re-check runs:**
   - when the app learns a path (`.pathLearned`) for a sender with stored unverified rows;
   - once at launch, for any rows with stored bytes;
   - at storage time, if the claimed sender's identity is already in `endpoint.learned`. This covers the router lacking the identity while the transport has it.
5. **A propagated message dropped by either check is still marked downloaded,** so it isn't fetched again on every sync.

## Non-goals

- Retroactively applying withheld fields (name, photo, expiry, reactions) after verification.
- Replay of the *same* message to the *same* recipient beyond the existing seen-hash ring.
- Group-message semantics beyond the per-member check above. Group copies are addressed to each member, so the destination check covers them.

## Constraints

- ReTiCA work goes in a worktree at `/Users/ell/development/ios/pods/ReTiCA-worktrees/forgery` (branch `fix/forgery`), never in the shared checkout. Another agent works there. The worktree needs the `FCB` symlink, per the existing convention.
- App work goes in a worktree `ReTiCAMsgr-forgery` off main. For app-side verification against the unmerged ReTiCA branch, point `ReTiCAMsgrCore/Package.swift` at a `/tmp/ReTiCAMsgr/ReTiCA` symlink temporarily, and restore it byte-identical before committing (the existing convention).
- **Merge order:** ReTiCA first, then the app. Breaking API changes need the matching app commit.
- iOS and macOS behaviour outside these changes is unchanged.
- The user's three-step mutation rule applies to every new test.
