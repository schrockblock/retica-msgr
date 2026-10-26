# Delete conversations and unread badge — design

Date: 2026-10-25. Two small, independent features that ship together.

## Why

- **Deleting:** conversations pile up, and there's no way to remove one.
- **Badge:** the app gives no at-a-glance sign that something is waiting. The user wants the standard app-icon badge.

Both have to work on iOS and on the new macOS build.

## Part 1 — Delete a conversation

### Behaviour (decided with the user)

**Entry points:**
- iOS: swipe left on a chat-list row to reveal a red **Delete**.
- macOS: right-click a row and choose **Delete Conversation** (a context menu).
- Both ask for confirmation first ("Delete this conversation? Its messages are removed from this device. This can't be undone.").

**Scope:** this device only. Nothing is sent to the peer, and their copy is untouched.

**What's removed** for the conversation's key (a peer's hex, or a group's id):
- every message row in that thread: for a peer, `peerHex == key && groupHex == nil`; for a group, `groupHex == key`;
- their attachment rows and files, including export copies;
- their reactions;
- the thread's unsent draft;
- its per-conversation settings, such as the disappearing-message timer;
- its unread marker (Part 2).

**What's kept:**
- the peer's profile (photo, icon, announce name);
- any contact link;
- block state;
- seen-hash rows, so a late propagation copy of a deleted message is not stored again (same rule as `MessagePurge`);
- for a group: the `ChatGroup` record and its members. Deleting a group conversation clears its history only. The user stays a member, new group messages keep arriving, and the row reappears with them. Leaving a group is a separate, later feature.

**Messages still sending** in that thread are cancelled through the router (`cancelOutbound`, as `cancelSendTapped` does), so a deleted thread doesn't reappear with a late status update.

**After deletion:**
- The row disappears from the list, because the list is derived from messages.
- If the deleted thread is somehow the open one, the open chat closes. Today the list and a chat are never on screen together, but a future Mac split view would allow it.
- The badge (Part 2) is recomputed.

A later message from that peer or group starts the row again, with only the new message.

### Shape (builder's call within these lines)

- **Deletion:** one core action, e.g. `deleteConversation(key)`. It reuses `MessagePurge`'s per-row file and reaction clean-up; extract a shared helper rather than duplicate it, because `MessagePurge`'s doc says it "owns every on-disk consequence" of deleting a message.
- **The image cache:** it is told which attachment ids went, as purge does (`attachmentCacheEvictor`).
- **macOS:** the context menu goes on the row itself, which has `.contentShape(Rectangle())` across its full width, so a right-click anywhere on the row works.
- **iOS:** the swipe action uses `role: .destructive` and still shows the confirmation. That is a deliberate departure from iOS Mail's no-confirm swipe, because nothing can bring the history back.

## Part 2 — Unread badge on the app icon

### Behaviour (decided with the user)

**What it shows:** a standard red badge on the app icon (iOS Home Screen; macOS Dock), counting **unread incoming messages**. Messages, not conversations: the user accepted either, and messages are what a push can count. Nothing new is shown inside the app.

**What counts as unread:** an incoming message that isn't a timer change or a group event, arriving after its conversation was last read.

**When a conversation is read:** whenever its chat is on screen and the app is frontmost. That is the same condition the disappearing-message "first view" uses today (`isForeground && chatVisible` with that thread open):
- opening the thread;
- returning to the foreground with it open;
- a message arriving while you're watching it.

**While the app runs** (foreground, or a background wake from a push): the app computes the real count and sets the badge.

**While the app isn't running** (iOS): the notification service extension adds 1 per push and sets the badge from that counter. The counter is stored in the shared app group (`ReTiCaMsgrPush.storage()`'s settings, or a sibling key). Pushes that carry no message don't increment:
- silent link-request wakes;
- pushes the extension suppresses for blocked senders.

**Correcting drift:** every time the app recomputes, it writes the true count back to that counter. That fixes overcounts from duplicate or retried pushes.

**Permission:** the authorization request adds `.badge` to today's `[.alert, .sound]` (`PushPlatform+UIKit.swift`, `PushPlatform+AppKit.swift`). Users who already granted permission are not re-prompted by iOS; they can turn badges on in Settings. Setting the badge when it isn't allowed is a no-op, so no extra handling is needed.

**Setting the badge:** `UNUserNotificationCenter.setBadgeCount(_:)`. It works on both platforms, so no Dock-tile code is needed.

### Shape (builder's call within these lines)

**Read marker:**
- A per-conversation read marker in a new table (e.g. `conversationReads(key TEXT PRIMARY KEY, readAt DATETIME)`).
- Unread = incoming rows for that key with `timestamp > readAt`. For incoming rows, `timestamp` is arrival time.
- No row for a key means everything in it is unread.

**Migration:** when the table is created, insert `readAt = now` for every existing conversation. Otherwise the first launch after the update badges the user's entire history.

**When the count is recomputed** (a cheap `COUNT` query):
- launch;
- foreground;
- after a thread is marked read;
- after any incoming message is stored;
- after a conversation is deleted;
- after the push inbox drains.

**Badge client:** a TCA dependency (`BadgeClient`, with a `set(Int)` method). The app installs the live value; tests assert calls on it. The shared counter is written by the same path.

## Settled details (my calls, from the builder check; the user hasn't weighed in)

1. **Extension counter.**
   - **Where it lives:** the logic sits in `ReTiCAPush`'s `PushServiceHandler`, so it is testable there with no TCA. The handler's result gains a badge number alongside `PushVerdict`, and `NotificationService.content(for:)` copies it onto `content.badge` for a delivered push.
   - **How much to add:** one per stashed packet that isn't from a blocked sender, with a minimum of 1 for a delivered alert push whose packets couldn't be attributed. Suppressed and silent link-request pushes add 0.
   - **Storage:** the counter is a key in the same app-group settings `PushStorage` already reads and writes.
   - **App in the foreground:** the extension still runs and may briefly over-count. That's accepted, because the app's foreground drain (`willPresent` → `drainPushInbox`) is followed by a recompute that writes the true count back.
2. **Blocked peers** are excluded from the count, joined against the blocked-peers table, so blocking someone with unread messages drops them from the badge. The recompute triggers also include **after an expiry purge** and **after a block or unblock**.
3. **Conversation key:** `groupHex ?? peerHex`, lowercased, used the same way for the read marker, the open-thread check and deletion. Group event rows (`isGroupEvent`) and timer-change rows (`isTimerChange`) never count. Group posts from other members are incoming rows, so they count under the group's key.
4. **Delete then a new message:** the conversation's read marker is deleted with it. With no marker, everything in the conversation counts as unread, so the new message is unread, as intended. The builder enumerates every per-conversation store from the code: drafts, conversation settings, anything else keyed by peer or group. Each one is either deleted or explicitly listed as kept.
5. **macOS:**
   - **No extension:** the notification extension is iOS-only, and the Mac relies on the running app's recompute.
   - **After quitting:** the Dock badge keeps the last true count until the next launch recomputes it. That is correct at quit time and acceptable.

## Amendments

**A1 (planning, 2026-10-25):** this replaces the counter logic in settled detail 1.
- **Why:** the logic would have lived in `ReTiCAPush` (a separate pod repository). That would need a cross-repo change and a new handler result type.
- **Instead:** it lives in this repo's `ReTiCaMsgrPushService` target.
  - When the extension's verdict is `.deliverOriginal`, it adds **1 per delivered push** to the app-group counter and puts the result on `content.badge`.
  - A `.suppress` verdict adds nothing.
- **Silent pushes:** silent (content-available, non-mutable) pushes never run the extension, so they never count.
- **Cost:** a push carrying several messages counts once until the app recomputes. The user accepted approximate counts while the app is closed.

**A2 (planning, 2026-10-25):** deleting a conversation **keeps** its `ConversationSetting` row, the disappearing-message timer.
- **Why:** that timer is state shared with the peer (both ends agreed on it), not local history. Removing it on one side would silently turn expiry off here while the peer still runs it.
- **What's still removed:** the draft (its entry in the on-disk drafts file), messages, attachments, reactions and the read marker.
- **Cost if wrong:** a deleted chat that restarts keeps its old timer. The user can change it in the chat as usual.

**A3 (final review, 2026-10-26):** the iOS swipe's Delete button has **no destructive role** and the swipe **does not allow a full swipe**: `.swipeActions(edge: .trailing, allowsFullSwipe: false)` with a plain `Button("Delete")` tinted red.
- **Why:** SwiftUI animates a destructive (or fully swiped) row out of the List before the data changes. With the confirmation in front of the delete, the row would vanish and then reappear on Cancel.
- **What stays:** the button still looks red, and the confirmation dialog's own "Delete" button keeps `role: .destructive`.
- **Cost if wrong:** none. A full swipe no longer jumps straight to the dialog; the user taps Delete instead.

## Non-goals

- Deleting on the peer's side, or "delete for everyone".
- Leaving a group (later).
- In-app unread indicators: row dots, counts, a tab badge.
- Deleting individual messages.
- Mac new-message notifications. They are a known gap from the macOS port, separate from this work.

## Constraints

- iOS behaviour outside these two features is unchanged. Mac-specific UI goes through the existing `#if os(...)` / `ReTiCaMsgr/Platform/` pattern.
- **Branch:** builds on `feat/macos` (the macOS right-click needs it). Use a new branch off it, `feat/delete-and-badge`, or off main once `feat/macos` merges.
- **Tests:**
  - TCA TestStore tests for the core actions;
  - a migration test for the read-marker seeding;
  - the extension's counter logic tested in its own package (no TCA).
- **Testing rule:** every new test is mutation-verified, per the user's CLAUDE.md three-step rule.
