# Next feature: group chats vs disappearing messages (decision, 2026-10-02)

This records the brainstorming that followed the push wake-ups release (app main 1e9a288,
2026-10-02). The question was which of two features to build next, group chats or disappearing
messages. **Decision: disappearing messages first.** Group chats stay on the roadmap with the
design direction below, so a later brainstorm can start from it rather than from scratch.

## What was asked

The user (ReTiCAMsgr's developer) asked which is the better next step. The first recommendation
was disappearing messages, on the grounds that LXMF offers nothing for groups beyond a reserved
field number, while disappearing messages are self-contained. The user found that reasonable but
asked for web research first, having seen that NomadNet has "channels" and that Retichat has
groups and channels, public and private. A four-researcher deep-research run produced the report
at `reports/Reticulum group chat and channel designs.md` (notes in
`research_notes/Reticulum group chat and channel designs/`). Both folders are untracked at the
repo root.

## What the research found

- **Retichat is open source**, not closed as first believed. iOS, Android and browser clients,
  the Rust Reticulum and LXMF stacks and the RFed channel server are all public under `jrl290`,
  mostly MIT. Its groups are the only shipping serverless design: each member fans out ordinary
  LXMF messages to every accepted member, with metadata in a private LXMF field (top-level fields
  0xA0–0xA8 today, moving to one msgpack field 0xD1 around 2026-10-26). Invites carry member public
  keys; stalled deliveries fall back to propagation; members can relay for each other. No admin
  roles, no history for late joiners. Its "channels" are RFed, a separate pub/sub server protocol
  with keys derived from the channel name, invisible to standard LXMF clients and impossible to
  revoke.
- **NomadNet's "Channels" tab is Reticulum Relay Chat (RRC)**, an IRC-style hub protocol over
  Links added in 1.1.0 (2026-05-17). The hub reads plaintext, stores nothing and delivers nothing
  to offline members by design. It is not LXMF.
- **Sideband, upstream MeshChat and Columba have no groups.** The only other implementations are
  LXMF distribution bots (LXMF-Tools, fwdsvc, comms-engineer/lxmf-group-hub) that act as a contact
  and re-emit messages to members: they work with every client but the operator reads plaintext
  and is a single point of failure, and the three use incompatible attribution conventions.
- **LXMF offers reserved numbers and nothing else.** `FIELD_GROUP` (0x0B) is a bare constant with
  no format or code; `FIELD_THREAD` (0x08) is typed as a 32-byte hash with no semantics. RNS GROUP
  destinations are single-hop, cannot be announced, have no ratchets, yield one anonymous proof at
  best, and crash the LXMF packer. Mark Qvist called native groups "really hard to make bandwidth
  efficient while still preserving privacy" (2023), liked a field-based distribution-list idea
  (2024), has committed to nothing since and has withdrawn from public interaction. Treat native
  LXMF groups as unscheduled.
- **Bandwidth sets the product boundary for fan-out.** A 100-byte post plus a 20-byte group field
  is roughly 0.5 s at SF7, 0.9 s at SF8 and 2.8 s at SF10 per recipient on LoRa, plus a proof
  frame each. Ten members at SF8 is about 9 s of data plus 3.5 s of proofs per post. Group fields
  must stay tiny (a 16-byte id, roster only in invites) to keep posts single-packet.

## Design direction if groups come back

Fan-out of ordinary LXMF messages, one per member, is the only design that keeps everything
ReTiCAMsgr already has: per-recipient single-packet proofs, pairwise forward secrecy,
propagation-node offline delivery, and no servers. Its costs are N−1 frames per post and no shared
history for late joiners. The one decision with network effects is the field layout:

- adopt Retichat's layout (field 0xD1 msgpack map) and get cross-app groups with the only other
  iOS LXMF messenger, at the cost of inheriting a mid-migration layout nobody upstream coordinated;
- or define a `FIELD_THREAD` id plus a small msgpack dict in `FIELD_GROUP`, in the style of the
  2026 reply/reaction fields, which aligns with upstream conventions but nobody else reads yet.

Either way unknown fields render as ordinary messages in other clients, which is a graceful
failure, and the UI should surface a group-size ceiling. Hub or relay designs (RRC, RFed, bots)
were rejected for this app because each makes an operator a plaintext reader or a single point of
failure, which is the opposite of the push design's "the hub never sees content" stance.

## Why disappearing messages first

- Self-contained: a custom LXMF field honoured by ReTiCAMsgr peers plus a local timer and purge.
  LXMF has no expiry or TTL field (checked in the reference `LXMF.py`: the only expiries are
  router-side, 30 days for propagation stores and 21 days for tickets), so this is app-to-app
  behaviour by nature and nothing upstream is being pre-empted.
- Groups need a protocol decision with no upstream guidance and a bandwidth model, and the
  2026-10-02 push debugging showed that even one-to-one delivery to a suspended iOS client already
  depends on sender behaviour (link-based senders need a propagation node). Adding fan-out on top
  of that before the delivery story is settled would multiply the failure modes.

## Open questions for the disappearing-messages brainstorm

1. When does the timer start: on send, on delivery proof, or on first read? (Signal: on read for
   the recipient, on send for the sender; the sender cannot know when the recipient read it
   without a read receipt, which LXMF does not have.)
2. Per-conversation setting or per-message? Who may change it, and is the change itself announced
   as a message?
3. Wire format: a custom field in the 0xFB–0xFD application range carrying the duration in
   seconds, versus misusing a standard field. Check the reference `LXMF.py` for any new standard
   field before choosing.
4. What happens to attachments on disk (`AttachmentStore`), the `messages` row, the Info sheet
   metadata and the conversation preview when a message expires, and whether expiry runs while the
   app is suspended (it cannot; purge on launch and foreground).
5. Behaviour with peers that do not honour the field (Sideband, NomadNet, Retichat): the message
   simply persists there. Show that caveat in the UI.

## Related state

- Push wake-ups shipped 2026-10-02; the same-day debugging and its fixes are recorded in
  `docs/superpowers/backlog-retica-followups.md` under "Push wake-ups".
- Roadmap status and shipped features are in the memory note "Roadmap status".
