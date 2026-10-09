import Foundation
import OSLog
import ComposableArchitecture
import Sharing
import SQLiteData
import GRDB
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
import ReTiCAPushCore

/// A registration the push feature asked for before the hub socket was up (spec amendment,
/// final-review I1). Buffered from the registration `Reduce`'s `sendRegistration` case and
/// resumed from `interfaceConnected`, after `registerDelivery`, so the announce precedes it.
public struct PendingPushRegistration: Equatable, Sendable {
    public var hub: Data
    public var path: String
    public var data: Data

    public init(hub: Data, path: String, data: Data) {
        self.hub = hub
        self.path = path
        self.data = data
    }
}

@Reducer
public struct AppFeature {
    public enum Connection: Equatable { case disconnected, connecting, connected }

    /// A terminal Bluetooth-adapter problem worth surfacing to the user (A5). Mapped from the BLE
    /// interface's `adapterUnavailable` delegate, which only fires for causes retrying cannot fix.
    /// `poweredOff`/transient causes never reach here — those stay on the library's internal retry.
    public enum BluetoothAlert: Equatable {
        /// Permission denied. The UI offers an "Open Settings" prompt (the toggle lives there).
        case permissionDenied
        /// No Bluetooth LE radio (e.g. a Mac without the hardware). Informational — nothing to grant.
        case unsupported
    }

    /// Outcome of an announce-row tap: the peer's public key, looked up locally.
    public enum PublicKeyRequestStatus: Equatable {
        /// The key from the peer's signed announce (`Transport.learned`).
        case received(publicKeyHex: String)
        /// No key is known for the peer (no announce heard, or its entry expired).
        case failed(reason: String)
    }

    /// The message a reply is being composed to. Set from the long-press menu, shown above the text
    /// field, and cleared by send, cancel or leaving the conversation. `body` is the untrimmed
    /// original: `ReplyWire.trimQuote` runs at display and at send.
    public struct ReplyTarget: Equatable, Sendable {
        public var messageHash: String
        public var body: String
        public var isOutgoing: Bool

        public init(messageHash: String, body: String, isOutgoing: Bool) {
            self.messageHash = messageHash
            self.body = body
            self.isOutgoing = isOutgoing
        }
    }

    /// A Resource arriving on one link (spec 2026-09-28 §4). `sourceHash` is the peer when we
    /// opened the link, nil when a peer linked to our own destination (the sender is unknown until
    /// the message unpacks), so the UI shows an unattributed one everywhere.
    public struct InboundTransfer: Equatable, Sendable {
        public var sourceHash: Data?
        public var fraction: Double
        public var updatedAt: Date

        public init(sourceHash: Data?, fraction: Double, updatedAt: Date) {
            self.sourceHash = sourceHash
            self.fraction = fraction
            self.updatedAt = updatedAt
        }
    }

    /// An inbound transfer that stops reporting for this long is dropped from the UI.
    public static let inboundTransferTimeout: Duration = .seconds(60)

    /// What the open thread is (spec 2026-10-09 §3): `openPeerHex` holds a peer's address or a
    /// group's id accordingly.
    public enum ConversationKind: Equatable, Sendable { case peer, group }

    @ObservableState
    public struct State: Equatable {
        public var node: LXMFServiceNode.State
        public var identity: Identity
        public var myAddressHex: String
        /// Opt-in push wake-ups (spec 2026-10-01 §3). The feature owns the toggle, the APNs token and
        /// registration; this reducer turns its `delegate(.inject)` into `transport.received`.
        public var push: PushFeature.State
        /// One registration attempt over the hub's link (spec amendment A2): the pure state machine
        /// the registration reducer below feeds with endpoint events.
        public var pushRegistrationFlow = RegistrationLinkFlow()
        /// A registration the push feature asked for before the hub socket was up. Started from
        /// `interfaceConnected`, after `registerDelivery`, so the announce precedes it.
        public var pendingPushRegistration: PendingPushRegistration? = nil
        @Shared(.appStorage("host")) public var host: String = "127.0.0.1"
        @Shared(.appStorage("port")) public var port: Int = 4242
        public var connection: Connection = .disconnected
        /// The set of currently-connected Transport interfaces (TCP client, each accepted server
        /// connection, each BLE peer). `connection` is derived from this: the app is `.connected`
        /// while ANY interface is up. Session-only — rebuilt from live `interfaceConnected` /
        /// `interfaceDisconnected` events, never persisted. Before this, the app collapsed every
        /// interface into one bool, so a single BLE peer dropping marked the whole app offline while
        /// TCP stayed healthy (punch-list A4).
        public var connectedInterfaces: Set<InterfaceID> = []
        /// Set when the BLE adapter is terminally unavailable (permission denied / no radio); drives
        /// the Settings permission surface (A5). Session-only — cleared on each connect attempt so a
        /// resolved denial doesn't stick, and re-set if the adapter is still unavailable.
        public var bluetoothAlert: BluetoothAlert? = nil
        public var draft = ""
        /// The message being replied to, or nil. Session-only.
        public var replyTarget: ReplyTarget? = nil
        /// The attachment waiting in the composer, its in-flight preparation, and the last error.
        /// Session-only; cleared by send, remove, or leaving the conversation.
        public var pendingAttachment: PendingAttachment? = nil
        public var attachmentPreparing = false
        public var attachmentError: String? = nil
        /// The Original value last asked for while a toggle's re-encode is in flight, nil when idle,
        /// so toggling back before the first re-encode lands is compared with what was asked for.
        public var attachmentOriginalRequested: Bool? = nil
        /// Outgoing transfer progress by message hash hex, from `deliveryProgress`: monotonic, and
        /// cleared by every terminal delivery outcome. Session-only.
        public var outgoingProgress: [String: Double] = [:]
        /// Inbound transfers by link ID, from `inboundTransferProgress`. Session-only.
        public var inboundTransfers: [Data: InboundTransfer] = [:]

        /// Transfers to show in the open thread: the unattributed ones, plus those attributed to
        /// the open peer.
        public var inboundTransfersForOpenThread: [InboundTransfer] {
            let open = openPeerHex.flatMap { Data(hexString: $0) }
            return sortedInboundTransfers { $0.sourceHash == nil || $0.sourceHash == open }
        }

        /// Transfers nobody can be named for, shown on the conversation list.
        public var unattributedInboundTransfers: [InboundTransfer] {
            sortedInboundTransfers { $0.sourceHash == nil }
        }

        /// A stable order for the UI (a dictionary's is arbitrary): oldest report first, ties by
        /// link ID hex.
        private func sortedInboundTransfers(_ include: (InboundTransfer) -> Bool) -> [InboundTransfer] {
            inboundTransfers
                .filter { include($0.value) }
                .sorted { a, b in
                    a.value.updatedAt != b.value.updatedAt
                        ? a.value.updatedAt < b.value.updatedAt
                        : a.key.hexString < b.key.hexString
                }
                .map(\.value)
        }
        // Derived list of peers, reloaded after every write.
        public var conversations: [Conversation] = []
        // The peer whose thread is currently open (drives navigation), and its messages.
        public var openPeerHex: String? = nil
        public var threadMessages: [Message] = []
        /// Visible reaction rows for the open thread: reactor is me or the open peer only, so a
        /// third party who knows a message hash can't inject a badge into this conversation.
        /// Always assign through `setThreadReactionRows` so `threadReactions` stays in sync.
        public var threadReactionRows: [Reaction] = []
        /// Badge data keyed by message hash hex. Derived from `threadReactionRows`.
        public var threadReactions: [String: [ReactionSummary.Item]] = [:]
        /// The open thread's attachments by message id, loaded with the thread. Session-only.
        public var attachmentsByMessageId: [UUID: Attachment] = [:]
        /// Whether `openPeerHex` is a peer or a group. Set by the open actions, reset by close.
        public var openConversationKind: ConversationKind = .peer
        /// The open group's row, members (sorted by address, me included) and the delivery rows of
        /// its outgoing messages, loaded with the thread (`groupLoaded`). Session-only.
        public var openGroup: ChatGroup? = nil
        public var openGroupMembers: [GroupMember] = []
        public var deliveriesByMessageId: [UUID: [GroupDelivery]] = [:]
        /// The open conversation's disappearing-messages timer in seconds, nil when off. Loaded with
        /// the thread (`conversationExpiryLoaded`), set by `expirySelected`. Session-only.
        public var openConversationExpiry: Int? = nil
        /// Whether `openConversationExpiry` reflects the stored setting for the open thread
        /// (amendment A16). False from open until `conversationExpiryLoaded` lands, during which a
        /// send reads the setting from the database instead of trusting the nil in state.
        public var openConversationExpiryLoaded = false
        /// The deadline the expiry sleeper is waiting for, nil when none is armed (amendment A15).
        /// A purge completion only re-arms for an earlier deadline, so a stale completion from a
        /// purge that raced another cannot cancel or postpone a live sleeper. Session-only.
        public var armedExpiry: Date? = nil
        /// Whether the scene is active (amendment A5). A message arriving into the open thread is
        /// "viewed" only while this is true. Starts true: a launch is a foreground launch unless
        /// `.backgrounded` says otherwise, and a push-wake launch has no open thread anyway.
        public var isForeground = true
        /// Whether ChatView is on screen (amendment A11). `openPeerHex` stays set while the user is
        /// on another tab, so arrival and foreground stamping also require this. Set by opening or
        /// starting a conversation and `.chatAppeared`, cleared by `.closeConversation` and
        /// `.chatDisappeared`. Session-only.
        public var chatVisible = false
        // The Send gate: peers a send would route to right now (live learned path; from pathLearned
        // and seedReachablePeers). A peer outside it gets a path request on receipt / open
        // (`pathRequestIfUnreachable`); the answer lands here via pathLearned. Session-only.
        public var reachablePeers: Set<String> = []
        // Announce-row tap outcomes, keyed by the peer's delivery-destination hash hex. Session-only.
        public var publicKeyRequests: [String: PublicKeyRequestStatus] = [:]
        @Shared(.appStorage("propagationNodeHex")) public var propagationNodeHex: String = ""
        @Shared(.appStorage("propagationNodeModeEnabled")) public var nodeModeEnabled: Bool = false
        @Shared(.appStorage("displayName")) public var displayName: String = ""
        /// Opt-in: also run a TCP listener so other nodes on the LAN can dial THIS device
        /// directly (peer-to-peer, no shared rnsd). OFF by default — a listening socket is an
        /// attack surface the dialling-only client never was (see the Settings caption). The
        /// natural home for Tier 7 admission-control settings when they arrive.
        @Shared(.appStorage("listenEnabled")) public var listenEnabled: Bool = false
        /// The local port the opt-in listener binds. A DEDICATED setting, not a reuse of `port`:
        /// `port` is the REMOTE rnsd port we dial OUT to; the listener binds a LOCAL port we
        /// accept IN on. Conflating them would bind the listener to whatever remote port the user
        /// happened to dial. Defaults to 4242 (the RNS TCP default).
        @Shared(.appStorage("listenPort")) public var listenPort: Int = 4242
        /// Opt-in: carry OTHER nodes' traffic through this device (Reticulum "transport" mode). OFF
        /// by default — relaying installs this device's identity as the Transport identity, the value
        /// every relay branch in `Transport` gates on, and turns on recursive path requests so the
        /// node answers path requests for third parties. Applied on `interfaceConnected` (like
        /// `nodeModeEnabled`) so a persisted setting survives relaunch, and immediately on toggle so
        /// it takes effect without a reconnect.
        @Shared(.appStorage("relayEnabled")) public var relayEnabled: Bool = false
        /// Opt-in: also run a BLE interface so this device connects directly to nearby Reticulum
        /// devices (other iPhones, Raspberry Pis) to send and relay over Bluetooth. OFF by default.
        /// Gates whether the `ble` driver slot is present; decided at connect time in
        /// `syncEndpointHostPort` (like `listenEnabled`), so toggling takes effect on the next
        /// Connect. The live FCB/CoreBluetooth driver is auto-wired via `\.bleDriver` — nothing to
        /// inject.
        @Shared(.appStorage("bleEnabled")) public var bleEnabled: Bool = false

        public init(identity: Identity, host: String = "127.0.0.1", port: Int = 4242,
                    pushStorage: PushStorage = .temporary(),
                    bundleID: String = Bundle.main.bundleIdentifier ?? "",
                    pushEnvironment: PushEnvironment = AppFeature.defaultPushEnvironment) {
            self.identity = identity
            self.myAddressHex = lxmfAddressHex(identity)
            // Use the LXMF library default — one constant that is both advertised in the
            // node announce and enforced on inbound propagation offers.
            self.node = LXMFServiceNode.State(
                identity: identity,
                endpoint: TCPEndpoint.State(host: host, port: UInt16(port), reconnectOnDrop: true),
                minStampCost: LXMFPropagation.defaultPropagationStampCost
            )
            self.push = PushFeature.State(
                identity: identity, bundleID: bundleID, environment: pushEnvironment, storage: pushStorage,
                keychainService: SharedIdentityLocation.service,
                keychainAccessGroup: SharedIdentityLocation.accessGroup)
            _host = Shared(wrappedValue: host, .appStorage("host"))
            _port = Shared(wrappedValue: port, .appStorage("port"))
        }

        /// A path request for `hex` when the Send gate does not admit it yet, else `.none`.
        ///
        /// The gate stays "a send would route right now" (2026-08-22 unlock-send design): this does
        /// not widen it, it asks the network for the path that would satisfy it. The answer is an
        /// announce (path response) → `.pathLearned` → `reachablePeers`, the existing unlock. Used
        /// where the app learns a peer exists but may hold no path to it: a received message (the
        /// sender needs a path to us, not the reverse) and opening a conversation (after a relaunch).
        func pathRequestIfUnreachable(_ hex: String) -> Effect<Action> {
            guard !reachablePeers.contains(hex),
                  let hash = Data(hexString: hex), hash.count == 16 else { return .none }
            return .send(.node(.client(.endpoint(.requestPath(destinationHash: hash)))))
        }

        public mutating func setThreadReactionRows(_ rows: [Reaction]) {
            threadReactionRows = rows
            threadReactions = ReactionSummary.byMessage(rows, me: myAddressHex)
        }

        /// The open peer's display name from its LXMF delivery announce (`learnedPeers`, the table
        /// the Announces list shows), trimmed. nil when no conversation is open, no announce was
        /// heard, or the name is blank, so labels fall back to "Them" rather than "".
        public var openPeerDisplayName: String? {
            openPeerHex.flatMap(peerDisplayName)
        }

        /// `peerHex`'s display name from its LXMF delivery announce (`learnedPeers`), trimmed; nil
        /// when no announce was heard or the name is blank, so labels fall back to "Them".
        public func peerDisplayName(_ hex: String) -> String? {
            guard let hash = Data(hexString: hex),
                  let name = node.client.learnedPeers[hash]?.displayName?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return name
        }

        /// My name as other members see it in lines and wire bodies: the trimmed display name,
        /// else the first eight hex characters of my address.
        public var myName: String {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? GroupEventText.fallbackName(myAddressHex) : trimmed
        }

        public var isOpenGroupCreator: Bool { openGroup?.creatorHex == myAddressHex }

        /// The open group's members other than me, sorted.
        public var openGroupOthers: [String] {
            openGroupMembers.map(\.memberHex).filter { $0 != myAddressHex }
        }

        /// The group Send gate (spec §3): at least one other member would route right now.
        public var anyGroupMemberReachable: Bool {
            openGroupOthers.contains { reachablePeers.contains($0) }
        }

        /// A member's name for a line: "You", the announce display name, else a short hex.
        public func groupMemberName(_ hex: String) -> String {
            if hex == myAddressHex { return GroupEventText.you }
            return peerDisplayName(hex) ?? GroupEventText.fallbackName(hex)
        }

        /// Display names of the open group's announced members, by address, for reply labels and
        /// the Info sheet.
        public var threadSenderNames: [String: String] {
            Dictionary(uniqueKeysWithValues: openGroupMembers.compactMap { member in
                peerDisplayName(member.memberHex).map { (member.memberHex, $0) }
            })
        }
    }

    public enum Action: Equatable, BindableAction {
        case onLaunch
        /// The app returned to the foreground. iOS tears the socket down while suspended, so this
        /// re-dials rather than trusting a reconnect timer that could not run while suspended.
        case foregrounded
        /// The app entered the background (UIApplication.didEnterBackgroundNotification). Used to
        /// flush the debounced learned-destination write before the process may be killed by the OS.
        case backgrounded
        /// A background push woke the process (AppDelegate). Re-dials like `foregrounded`, then
        /// drains the push inbox.
        case pushWake
        /// APNs issued or refreshed the device token (AppDelegate).
        case pushDeviceToken(Data)
        case pushDeviceTokenFailed(String)
        /// The 20 s registration timer fired. Internal.
        case pushRegistrationTimedOut
        case push(PushFeature.Action)
        case connectTapped
        case disconnectTapped
        case openConversation(String)
        /// A tap on a group row: opens it as a group thread.
        case openGroupConversation(String)
        case closeConversation
        case startConversation(String)
        /// ChatView's onAppear: the open thread is on screen again (back from another tab), so its
        /// unstamped rows are viewed now.
        case chatAppeared
        /// ChatView's onDisappear: the open thread is no longer on screen.
        case chatDisappeared
        case setNodeMode(Bool)
        case setRelayMode(Bool)
        case setPropagationNode(String)
        case setDisplayName(String)
        case syncTapped
        case announceTapped
        /// Tap on a detected-announce row: request that peer's public key over an authenticated link.
        case announceRowTapped(destinationHashHex: String)
        case sendTapped
        case conversationsLoaded([Conversation])
        case threadLoaded([Message], reactions: [Reaction] = [], attachments: [Attachment] = [])
        /// The open thread's group, members and delivery rows, sent by `reloadThread` before
        /// `threadLoaded` (nil group for a peer thread) and guarded on the open key.
        case groupLoaded(groupHex: String, group: ChatGroup?, members: [GroupMember], deliveries: [GroupDelivery])
        /// The user picked a disappearing-messages duration (0 = off) from the chat toolbar menu.
        case expirySelected(seconds: Int)
        /// The open conversation's stored timer, sent by `reloadThread` beside `threadLoaded`.
        case conversationExpiryLoaded(peerHex: String, seconds: Int?)
        /// A purge finished: reload if it deleted anything, and arm the sleeper for `nextDue`. Internal.
        case expiryPurgeCompleted(purged: Int, nextDue: Date?)
        /// The expiry sleeper fired. Internal.
        case expiryDue
        case reactionSelected(messageHash: String, emoji: String)
        /// Long-press → Reply. Ignored for a hashless message or one no longer in the thread.
        case replyTapped(Message.ID)
        /// The ✕ on the reply bar.
        case replyCancelled
        /// The composer's picker delivered bytes; prepare them (encode a photo) off the main thread.
        case attachmentPicked(PickedItem)
        /// The picker began a slow read (a photo's `loadTransferable`, a document's bytes) for the
        /// conversation `peerHex`: show the spinner meanwhile. Ignored for any other conversation.
        case attachmentLoadStarted(peerHex: String)
        case attachmentPrepared(PendingAttachment)
        case attachmentFailed(String)
        /// The × on the attachment bar.
        case attachmentRemoved
        /// The Original toggle on a pending photo: re-encode from the picker's bytes.
        case attachmentOriginalToggled(Bool)
        /// Long-press → Cancel Send on an outgoing message still sending.
        case cancelSendTapped(Message.ID)
        /// The 60 s silence timer for one inbound transfer fired. Internal.
        case inboundTransferTimedOut(linkID: Data)
        /// The send could not write the attachment's bytes, so nothing was sent: show `storeFailed`
        /// in the attachment bar and give the caption back. Internal.
        case attachmentSendFailed(draft: String)
        case rehydratePropagationStore([Data])
        /// Restore the router's dedup sets (seen-message hashes + downloaded transient IDs) from the
        /// previous session. Sent on launch after reading the three durability tables.
        case rehydrateDedup(seenHashes: [Data], downloadedTransientIds: [Data])
        /// Restore the learned-peer table (stamp costs, display names) from the previous session.
        /// Sent on launch alongside `.rehydrateDedup`.
        case rehydrateLearnedPeers([Data: LXMFNode.LearnedPeer])
        /// Restore `Transport.State.learned` from the previous session so that after a cold start
        /// the node can route to known destinations without waiting for re-announces.
        ///
        /// Sent on launch after pruning and reading the `learnedDestinationRows` table. Forwarded to
        /// Transport via `.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations))))`.
        case rehydrateLearnedDestinations([Data: LearnedDestination])
        /// The debounce timer fired — write the current `learned` table to the database.
        ///
        /// Internal: only ever sent by the 30 s debounce effect or by `.backgrounded` flush.
        /// Not part of the public-facing action surface; callers should send `.backgrounded` for
        /// an explicit flush.
        case _flushLearnedDestinations
        case node(LXMFServiceNode.Action)
        case binding(BindingAction<State>)
    }

    /// Effect cancel IDs for this reducer.
    private enum CancelID: Hashable {
        /// The running debounce timer for learned-destination persistence.
        /// Cancelled and restarted on every `.pathLearned`; cancelled on `.backgrounded` flush.
        case learnedDebounce
        /// The one in-flight preparation (photo encode) of a picked attachment.
        case attachmentPreparation
        /// The silence timer of one inbound transfer, keyed by link ID.
        case inboundTransfer(Data)
        /// The 20 s timeout of the in-flight push-registration attempt (spec amendment A2).
        case pushRegistration
        /// The one sleeper waiting for the earliest `expiresAt` (spec §3). Re-armed with
        /// `cancelInFlight` after every purge, so it always waits for the current earliest row.
        case expiry
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.attachmentStore) var attachmentStore
    @Dependency(\.attachmentCacheEvictor) var attachmentCacheEvictor

    /// Path expiry for pruning `learnedDestinationRows`, taken from the library rather than copied.
    ///
    /// This was briefly a local `60 * 60 * 24 * 7` behind a "must be kept in sync" comment, because
    /// `Transport.pathExpiry` was `internal`. It is now `public` precisely so this file does not
    /// have to hold a second copy: a mirrored constant with a sync comment is the drift that
    /// produced a real stamp-cost bug in this project.
    static var pathExpiry: TimeInterval { Transport.pathExpiry }

    /// Request path for the public-key exchange this device ANSWERS (older builds of this app send
    /// it; this build no longer does — see `.announceRowTapped`): it replies with its 64-byte public key
    /// (`Identity.publicKey`). The key is already public — every delivery announce carries it,
    /// signed — so answering discloses nothing new; the exchange's value is that it happens over
    /// an authenticated link, i.e. the peer demonstrably holds the matching private key.
    public static let publicKeyRequestPath = "/publicKey"

    /// APNs environment follows the build configuration, as Xcode's `aps-environment` does.
    public static var defaultPushEnvironment: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    /// Where pushed packets are injected when the endpoint has no TCP client slot.
    static let pushFallbackInterface = InterfaceID("push")

    /// How long one registration attempt may take, path request to response.
    static let pushRegistrationTimeout: Duration = .seconds(20)

    /// Diagnostic channel for inbound-message shape. Filter in Console.app or with
    /// `log stream --predicate 'subsystem == "com.reticamsgr"'`.
    static let inbound = Logger(subsystem: "com.reticamsgr", category: "inbound")

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.node, action: \.node) { LXMFServiceNode() }
        Scope(state: \.push, action: \.push) { PushFeature() }
        Reduce { state, action in
            switch action {
            case .onLaunch:
                state.connection = .connecting
                syncEndpointHostPort(&state)
                let hub = (host: state.host, port: state.port)
                return .merge(
                    .send(.node(.client(.endpoint(.start)))),
                    .send(.push(.hubChanged(host: hub.host, port: hub.port))),
                    .send(.push(.appLaunched)),
                    .run { [database] send in try await reloadConversations(database, send) },
                    .run { [database] send in
                        // ORDER BY storedAt so eviction during rehydration is deterministic across
                        // launches: the oldest entries are ingested first, matching the order in which
                        // they were originally inserted, so the same entries are evicted at the cap.
                        let rows = try await database.read {
                            try PropagationEntryRow.all.order(by: \.storedAt).fetchAll($0)
                        }
                        await send(.rehydratePropagationStore(rows.map(\.lxmfData)))
                    },
                    .run { [database] send in
                        // Restore the router's dedup state. ORDER BY storedAt ASC is load-bearing
                        // (see SeenHashRow): the RingSet evicts at capacity, so oldest-first insertion
                        // keeps the newest 10 000 hashes — supplying them newest-first would do the
                        // opposite and defeat the feature while every test passes.
                        let (seenRows, tidRows): ([SeenHashRow], [DownloadedTransientIdRow]) =
                            try await database.read { db in
                                let seen = try SeenHashRow.all.order(by: \.storedAt).fetchAll(db)
                                let tids = try DownloadedTransientIdRow.all.fetchAll(db)
                                return (seen, tids)
                            }
                        let seenHashes = seenRows.compactMap { Data(hexString: $0.hashHex) }
                        let transientIds = tidRows.compactMap { Data(hexString: $0.transientIdHex) }
                        await send(.rehydrateDedup(seenHashes: seenHashes, downloadedTransientIds: transientIds))
                    },
                    .run { [database, expiryCutoff = date.now.addingTimeInterval(-LXMFNode.stampCostExpiry)] send in
                        // Restore learned-peer data (stamp costs, display names) so outbound messages
                        // are stamped at the costs peers last advertised, not sent unstamped until each
                        // peer re-announces.
                        //
                        // The expired rows are DELETED here, not merely skipped. The library's
                        // `.rehydrateLearnedPeers` sweeps expired entries out of the in-memory table,
                        // but it has no way to tell us to forget the row — so without this delete a
                        // peer heard once, 46 days ago, is re-read and re-skipped at every launch
                        // forever. In-memory growth would be collected while DISK growth was not,
                        // which is the half that actually accumulates on a device.
                        //
                        // The cutoff is computed in the capture list, from the `\.date` dependency:
                        // reading `date.now` inside the @Sendable closure would capture `self`.
                        let cutoff = expiryCutoff
                        let rows = try await database.write { db in
                            try LearnedPeerRow.where { $0.learnedAt < cutoff }.delete().execute(db)
                            return try LearnedPeerRow.all.fetchAll(db)
                        }
                        var peers: [Data: LXMFNode.LearnedPeer] = [:]
                        for row in rows {
                            guard let hash = Data(hexString: row.destinationHashHex) else { continue }
                            peers[hash] = LXMFNode.LearnedPeer(
                                displayName: row.displayName,
                                stampCost: row.stampCost,
                                supportsCompression: row.supportsCompression,
                                learnedAt: row.learnedAt
                            )
                        }
                        await send(.rehydrateLearnedPeers(peers))
                    },
                    .run { [database, expiryCutoff = date.now.addingTimeInterval(-AppFeature.pathExpiry)] send in
                        // Restore the learned transport-path table so routing works immediately after a
                        // cold start, without waiting for announces to re-arrive. iOS kills are routine
                        // (every background suspend is a candidate), so the dead window without this
                        // slice is constant on mobile.
                        //
                        // **Prune BEFORE the read.** `learned` is swept by `Transport.maintenanceTick`
                        // on the same 7-day cutoff. Without this delete a destination heard once,
                        // 8 days ago, is re-read and re-skipped at rehydration forever — in-memory
                        // growth is collected by maintenanceTick while disk growth is not, which is
                        // the half that actually accumulates on a device. This mirrors the fix applied
                        // to `LearnedPeerRow` in the previous slice.
                        //
                        // The cutoff is computed in the capture list, from the `\.date` dependency:
                        // reading `date.now` inside the @Sendable closure would capture `self`.
                        let cutoff = expiryCutoff
                        let destRows = try await database.write { db in
                            try LearnedDestinationRow
                                .where { $0.learnedAt < cutoff }
                                .delete().execute(db)
                            return try LearnedDestinationRow.all.fetchAll(db)
                        }
                        var destinations: [Data: LearnedDestination] = [:]
                        for row in destRows {
                            guard let pair = row.toLearnedDestination() else { continue }
                            destinations[pair.hash] = pair.destination
                        }
                        await send(.rehydrateLearnedDestinations(destinations))
                    },
                    .run { [database, attachmentStore, attachmentCacheEvictor, now = date.now] send in
                        // Nothing ran while suspended or dead: purge what fell due and arm the sleeper.
                        try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                    },
                    .run { [database, cutoff = date.now.timeIntervalSince1970 - Reaction.orphanGraceInterval] _ in
                        // Amendment A17: a reaction that arrived after its target was purged has
                        // nothing to attach to. Reactions can also arrive BEFORE their message, so
                        // only orphans older than the grace interval go.
                        try await database.write { try Reaction.pruneOrphans(olderThan: cutoff, $0) }
                    }
                )

            case .foregrounded:
                // Only re-dial when the TCP socket specifically is down. iOS tears the TCP socket
                // down while suspended, so foreground is when we rebuild it — but a live BLE peer
                // must NOT suppress that: keying on the whole-app `.connected` bool would skip the
                // re-dial whenever any BLE peer held the app "connected", leaving the dead socket
                // unrebuilt (A4). A HEALTHY tcp interface still short-circuits, because re-dialling
                // it would tear down its live links on every app switch.
                // Either way, drain the push inbox: packets may have been stashed while suspended.
                // Disappearing messages: the open thread is being looked at again (first view for
                // rows that arrived while suspended), and rows that fell due meanwhile go now.
                state.isForeground = true
                let expiryCatchUp = viewOpenThreadEffect(state)
                return .merge(redialIfTCPDown(&state), .send(.push(.drainInbox)), expiryCatchUp)

            case .pushWake:
                return .merge(redialIfTCPDown(&state), .send(.push(.drainInbox)))

            case let .pushDeviceToken(token):
                return .send(.push(.deviceTokenReceived(token)))

            case let .pushDeviceTokenFailed(reason):
                return .send(.push(.deviceTokenFailed(reason)))

            case let .push(.delegate(.inject(packets))):
                // Transport records a packet hash before it looks for a local destination, so a
                // packet injected before `registerDelivery` would be dropped AND never re-ingested.
                // Until the delivery destination exists (interfaceConnected registers it and then
                // drains again), put the packets back in the inbox.
                guard state.node.client.deliveryDestinationHash != nil else {
                    let inbox = state.push.storage.inbox
                    return .run { _ in
                        for raw in packets { _ = try? inbox.append(raw) }
                    }
                }
                // Feed each pushed packet to Transport as if the TCP driver had read it from the
                // socket: it unmasks (plain), dedups on packet hash, decrypts for our delivery
                // destination, and LXMFNode proves (a no-op when the interface is down) and routes.
                // A second proof for a packet the extension already proved is dropped by the
                // sender's transport because the receipt is gone.
                let interfaceID = state.node.client.endpoint.tcpClient?.interfaceID ?? AppFeature.pushFallbackInterface
                return .merge(packets.map { raw in
                    .send(.node(.client(.endpoint(.transport(.received(interfaceID, raw))))))
                })

            case .push(.setHubHex):
                // I3: the child has already reduced `setHubHex` (new hub text, old record forgotten).
                // Enabling first and typing the hub second is the natural order: once the field
                // holds a valid hub and a token is already in hand, register now instead of on the
                // next launch. The child cleared the old record, so the 24-hour rule does not skip it.
                guard state.push.enabled, let token = state.push.deviceToken,
                      let hub = Data(pushHex: state.push.hubHex), hub.count == 16 else { return .none }
                return .send(.push(.deviceTokenReceived(token)))

            case .push:
                return .none

            case .backgrounded:
                // Amendment A5: a message arriving into the open thread from now on is not viewed.
                state.isForeground = false
                // Flush the learned-destination table immediately instead of waiting out the
                // debounce interval. On iOS, applicationDidEnterBackground gives the app ~5 s
                // before the process is suspended; the debounce timer cannot run while suspended,
                // so without this flush up to ~30 s of path learning is lost on every background
                // cycle. Cancel the pending debounce so it doesn't fire redundantly on resume.
                let learnedToFlush = state.node.client.endpoint.learned
                // Close the hub socket NOW, while the process still runs. A suspended app's socket
                // stays open from the hub's side (the kernel keeps answering keepalives and ACKing
                // writes), so the push hub keeps writing packets into a socket nobody reads and
                // never goes dormant — no pushes for as long as the socket survives, which on
                // cellular was 2–15 minutes (2026-10-02 hub investigation). A clean FIN makes the
                // hub's interface dormant at once, and `.foregrounded` re-dials on return.
                // Only the TCP client: BLE peers keep running in the background on their own terms.
                let closeHubSocket: Effect<Action> = state.node.client.endpoint.tcpClient != nil
                    ? .send(.node(.client(.endpoint(.tcpClient(.disconnect)))))
                    : .none
                return .merge(
                    .cancel(id: CancelID.learnedDebounce),
                    closeHubSocket,
                    .run { [database] _ in
                        try await writeLearnedDestinations(learnedToFlush, to: database)
                    }
                )

            case ._flushLearnedDestinations:
                // Debounce timer fired: write the current learned table. The table may have grown
                // since the timer was armed; we always write the latest snapshot, so rapid
                // announces are coalesced into one write per 30 s window.
                let learnedToWrite = state.node.client.endpoint.learned
                return .run { [database] _ in
                    try await writeLearnedDestinations(learnedToWrite, to: database)
                }

            case .connectTapped:
                state.connection = .connecting
                syncEndpointHostPort(&state)
                let hub = (host: state.host, port: state.port)
                return .merge(
                    .send(.node(.client(.endpoint(.start)))),
                    .send(.push(.hubChanged(host: hub.host, port: hub.port)))
                )

            case .disconnectTapped:
                state.connection = .disconnected
                return .send(.node(.client(.endpoint(.stop))))

            case let .node(.client(.endpoint(.transport(.interfaceConnected(interfaceID, _))))):
                // Per-interface tracking (A4): record WHICH interface came up. TCP client, each
                // accepted server connection, and each BLE peer all surface here with a distinct
                // InterfaceID. The app is `.connected` while any interface is up.
                state.connectedInterfaces.insert(interfaceID)
                state.connection = .connected
                // Admit to the Send gate (`reachablePeers`) every peer whose persisted path is now usable
                // (interface just registered).
                // The Transport Scope has already run (child reducers reduce before this Reduce body — see the
                // pathLearned comment), so `endpoint.interfaces` already contains the new interface here.
                let learnedForSeed = state.node.client.endpoint.learned
                seedReachablePeers(&state, from: learnedForSeed)
                // setDisplayName must come BEFORE registerDelivery so the registration announce
                // carries the name (registerDelivery packs LXMFAnnounceData from state.displayName
                // at call time; TCA processes .send effects in FIFO order).
                // An empty display name sends nil, not "": LXMFAnnounceData.pack encodes a non-nil name
                // as msgpack bin, so "" would advertise a zero-length name. Reference's
                // display_name_from_app_data (LXMF.py:165) strips and returns it — showing an empty
                // label rather than no label in Sideband/NomadNet. nil is the correct "no name" signal.
                // A WHITESPACE-ONLY name is empty for this purpose: nothing on the emit path trims
                // (`LXMFAnnounceData.pack` bins the bytes as given), and the receiver's strip turns
                // "   " into exactly the empty label this rule exists to prevent. Trimmed here too,
                // not just in the setter, so a whitespace-only name persisted by an older build
                // still announces as nil.
                let launchName = state.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                var effects: [Effect<Action>] = [
                    .send(.node(.client(.setDisplayName(launchName.isEmpty ? nil : launchName, stampCost: nil)))),
                    .send(.node(.client(.registerDelivery))),
                    // C1: Transport records a packet hash before it looks for a local destination,
                    // so any packet the inject arm had to stash (no delivery destination yet) must
                    // be re-drained now that registerDelivery (just above) has set one. Idempotent —
                    // the inbox is usually already empty.
                    .send(.push(.drainInbox)),
                    // Answer peers' /publicKey requests (the app's requestResponder dependency
                    // supplies the key). Idempotent — re-registering on reconnect is harmless.
                    .send(.node(.client(.endpoint(
                        .registerRequestHandler(path: AppFeature.publicKeyRequestPath, policy: .all))))),
                ]
                // I1: a registration the push feature asked for before the hub socket was up is
                // resumed now — only for the TCP interface (the hub always sits behind it), and
                // only after registerDelivery/the announce above, so the hub sees the registration
                // once this device is actually reachable.
                if interfaceID == state.node.client.endpoint.tcpClient?.interfaceID,
                   let pending = state.pendingPushRegistration {
                    state.pendingPushRegistration = nil
                    effects.append(.send(.push(.delegate(.sendRegistration(
                        hub: pending.hub, path: pending.path, data: pending.data)))))
                }
                if let pn = Data(hexString: state.propagationNodeHex), pn.count == 16 {
                    effects.append(.send(.node(.client(.setPropagationNode(destinationHash: pn)))))
                    effects.append(.send(.node(.client(.syncFromPropagationNode))))
                }
                if state.nodeModeEnabled {
                    effects.append(.send(.node(.setNodeMode(true))))
                }
                // Re-apply a persisted relay-mode setting so the node relays again after relaunch.
                // Idempotent — setTransportIdentity/setRecursivePathRequests just overwrite the same
                // shared Transport state on every reconnect. See `.setRelayMode`.
                if state.relayEnabled {
                    effects.append(.send(.node(.client(.endpoint(.enableRelay(state.identity))))))
                    effects.append(.send(.node(.client(.endpoint(.transport(.setRecursivePathRequests(true)))))))
                }
                return .merge(effects)

            case let .node(.client(.endpoint(.transport(.interfaceDisconnected(interfaceID))))):
                // Per-interface tracking (A4): only THIS interface went away. The app stays
                // `.connected` as long as another interface remains — so one BLE peer dropping no
                // longer marks the whole app offline while TCP is healthy. Only when the set empties
                // (the last interface departed) does the app become `.disconnected`.
                state.connectedInterfaces.remove(interfaceID)
                state.connection = state.connectedInterfaces.isEmpty ? .disconnected : .connected
                return .none

            case let .node(.client(.endpoint(.ble(.delegate(.adapterUnavailable(cause)))))):
                // A5: the BLE adapter is terminally unavailable. Map the cause to a user-facing alert.
                // Only terminal causes arrive here (the library keeps transient ones on its retry
                // loop), so poweredOff/other are defensively ignored rather than shown as a fault.
                switch cause {
                case .unauthorized:       state.bluetoothAlert = .permissionDenied
                case .unsupported:        state.bluetoothAlert = .unsupported
                case .poweredOff, .other: break
                }
                return .none

            case let .node(.client(.endpoint(.delegate(.linkClosed(linkID, _))))):
                // An inbound transfer on this link is over, one way or the other.
                var effects: [Effect<Action>] = []
                if state.inboundTransfers.removeValue(forKey: linkID) != nil {
                    effects.append(.cancel(id: CancelID.inboundTransfer(linkID)))
                }
                return .merge(effects)

            case let .openConversation(peerHex):
                state.openPeerHex = peerHex
                state.chatVisible = true
                state.openConversationKind = .peer
                state.openGroup = nil
                state.openGroupMembers = []
                state.deliveriesByMessageId = [:]
                // The new thread's timer is unknown until `conversationExpiryLoaded` (A16).
                state.openConversationExpiryLoaded = false
                // Review fix: a target from the previous conversation must not survive the switch —
                // it would point at a message the new thread doesn't even contain.
                state.replyTarget = nil
                // Neither may a pending attachment, nor its preparation still in flight.
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database, attachmentStore, attachmentCacheEvictor, now = date.now] send in
                        // First view (spec §3): stamp before the load so the rows arrive stamped.
                        _ = try await stampViewed(database, peerHex, now: now)
                        try await reloadThread(database, peerHex, send)
                        try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                    },
                    // After a relaunch a conversation peer may have no path (session-only gate, none
                    // persisted or it expired): ask for one instead of leaving Send disabled until
                    // the peer happens to re-announce.
                    state.pathRequestIfUnreachable(peerHex)
                )

            case .closeConversation:
                state.openPeerHex = nil
                state.chatVisible = false
                state.threadMessages = []
                state.setThreadReactionRows([])
                state.attachmentsByMessageId = [:]
                state.openConversationKind = .peer
                state.openGroup = nil
                state.openGroupMembers = []
                state.deliveriesByMessageId = [:]
                state.openConversationExpiry = nil
                state.openConversationExpiryLoaded = false
                state.draft = ""
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                return .cancel(id: CancelID.attachmentPreparation)

            case let .openGroupConversation(groupHex):
                guard let data = Data(hexString: groupHex), data.count == GroupWire.idLength else { return .none }
                state.openPeerHex = groupHex
                state.openConversationKind = .group
                state.chatVisible = true
                state.openGroup = nil
                state.openGroupMembers = []
                state.deliveriesByMessageId = [:]
                state.openConversationExpiryLoaded = false
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                // No first-view stamp and no purge: timers are one-to-one only in v1.
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database] send in try await reloadThread(database, groupHex, send) }
                )

            case let .groupLoaded(groupHex, group, members, deliveries):
                // Guarded like reactions and attachments: a late load for a thread the user has
                // left must not label the next conversation with the previous group.
                guard groupHex == state.openPeerHex else { return .none }
                state.openGroup = group
                state.openGroupMembers = members.sorted { $0.memberHex < $1.memberHex }
                state.deliveriesByMessageId = GroupDelivery.byMessageId(deliveries)
                guard group != nil else { return .none }
                // Spec §3: a group thread asks for the paths of the members it cannot reach, so
                // the Send gate unlocks when they answer (the one-to-one open does the same).
                return .merge(state.openGroupOthers.map { state.pathRequestIfUnreachable($0) })

            case let .startConversation(hex):
                guard let data = Data(hexString: hex), data.count == 16 else { return .none }
                state.openPeerHex = hex
                state.chatVisible = true
                state.openConversationKind = .peer
                state.openGroup = nil
                state.openGroupMembers = []
                state.deliveriesByMessageId = [:]
                state.openConversationExpiryLoaded = false
                // Review fix: same as `openConversation` — clear any stale target from before.
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database, attachmentStore, attachmentCacheEvictor, now = date.now] send in
                        // First view (spec §3): stamp before the load so the rows arrive stamped.
                        _ = try await stampViewed(database, hex, now: now)
                        try await reloadThread(database, hex, send)
                        try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                    },
                    state.pathRequestIfUnreachable(hex)
                )

            case .chatAppeared:
                // Back on the chat from another tab: what arrived meanwhile is viewed now (A11).
                state.chatVisible = true
                return viewOpenThreadEffect(state)

            case .chatDisappeared:
                state.chatVisible = false
                return .none

            case .sendTapped:
                let text = state.draft
                let pending = state.pendingAttachment
                // Text or an attachment, not while a pick is still being prepared.
                guard !text.isEmpty || pending != nil,
                      !state.attachmentPreparing,
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                // A reply carries the original's full hash and a trimmed quote in the standard LXMF
                // fields 0x30 / 0x31. The quote is trimmed once, and the same string goes on the wire
                // and in the row. A target whose hash does not decode is sent as a plain message.
                var replyFields: [MsgPackValue.IntPair] = []
                var replyToHash: String? = nil
                var replyQuote: String? = nil
                if let target = state.replyTarget,
                   let replyTo = Data(hexString: target.messageHash), !replyTo.isEmpty {
                    let quote = ReplyWire.trimQuote(target.body)
                    replyFields = ReplyWire.encode(replyTo: replyTo, quote: quote)
                    replyToHash = target.messageHash
                    // Review fix: an empty trimmed quote (a whitespace-only original) is stored as
                    // nil, matching the wire, which now omits 0x31 for an empty quote too.
                    replyQuote = quote.isEmpty ? nil : quote
                }
                // Disappearing messages (spec §3 "Sending"): the field rides last, and the sender's
                // copy is stamped at send. The receiving side stamps on first view instead. Until
                // the thread's setting has loaded, the value in state is only "unknown", so the
                // effect reads the database instead (amendment A16); once loaded, state wins, since a
                // pick in `expirySelected` reaches state before its database write lands.
                let knownExpiry: Int?? = state.openConversationExpiryLoaded ? .some(state.openConversationExpiry) : nil
                let identity = state.identity
                let now = date.now
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                let attachmentStore = self.attachmentStore
                let attachmentCacheEvictor = self.attachmentCacheEvictor
                state.draft = ""
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentError = nil
                // The guard above refuses while preparing, so nothing should be in flight here;
                // cancelling anyway means no late result can land on the emptied composer.
                guard let pending else {
                    return .merge(
                        .cancel(id: CancelID.attachmentPreparation),
                        .run { [database, replyFields, replyToHash, replyQuote] send in
                            let expiry = try await resolveExpiry(knownExpiry, peerHex: peerHex, database)
                            let expiryFields = expiry.map { ExpiryWire.encode(seconds: $0) } ?? []
                            let (msg, row) = Self.outgoing(
                                identity: identity, peer: peer, peerHex: peerHex, text: text, now: now,
                                fields: replyFields + expiryFields, alsoViaPropagation: alsoViaPropagation,
                                replyToHash: replyToHash, replyQuote: replyQuote,
                                expirySeconds: expiry,
                                expiresAt: expiry.map { now.addingTimeInterval(TimeInterval($0)) })
                            try await database.write { try Message.insert { row }.execute($0) }
                            await send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation))))
                            try await reloadThread(database, peerHex, send)
                            try await reloadConversations(database, send)
                            if expiry != nil {
                                try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                            }
                        }
                    )
                }
                // With an attachment the message (several copies of the bytes deep) is built inside
                // the effect, off the main thread. The bytes go to disk first, then both rows in one
                // transaction, and only then the send — a failure at either step sends nothing, gives
                // the caption back, and leaves no file behind (spec §4 errors).
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database, replyFields, replyToHash, replyQuote] send in
                        let expiry = try await resolveExpiry(knownExpiry, peerHex: peerHex, database)
                        let expiryFields = expiry.map { ExpiryWire.encode(seconds: $0) } ?? []
                        // The attachment field (0x05 or 0x06) comes first, then any reply fields.
                        let attachmentFields = pending.isImage
                            ? AttachmentWire.encodeImage(pending.data)
                            : AttachmentWire.encodeFile(name: pending.name, data: pending.data)
                        let (msg, row) = Self.outgoing(
                            identity: identity, peer: peer, peerHex: peerHex, text: text, now: now,
                            fields: attachmentFields + replyFields + expiryFields, alsoViaPropagation: alsoViaPropagation,
                            replyToHash: replyToHash, replyQuote: replyQuote,
                            expirySeconds: expiry,
                            expiresAt: expiry.map { now.addingTimeInterval(TimeInterval($0)) })
                        let messageHash = row.messageHash
                        let path: String
                        do {
                            path = try attachmentStore.store(pending.data, messageHash: messageHash,
                                                             outgoing: true, ext: pending.format)
                        } catch {
                            AppFeature.inbound.error("attachment send: store failed for \(String(messageHash.prefix(8)), privacy: .public): \(String(describing: error), privacy: .public)")
                            await send(.attachmentSendFailed(draft: text))
                            return
                        }
                        let attachment = Attachment(
                            id: UUID(), messageId: row.id, kind: pending.kind, name: pending.name,
                            format: pending.format, size: pending.data.count,
                            width: pending.width, height: pending.height, path: path)
                        do {
                            try await database.write { db in
                                try Message.insert { row }.execute(db)
                                try Attachment.insert { attachment }.execute(db)
                            }
                        } catch {
                            AppFeature.inbound.error("attachment send: database write failed for \(String(messageHash.prefix(8)), privacy: .public): \(String(describing: error), privacy: .public)")
                            try? attachmentStore.delete(path)
                            await send(.attachmentSendFailed(draft: text))
                            return
                        }
                        await send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation))))
                        try await reloadThread(database, peerHex, send)
                        try await reloadConversations(database, send)
                        if expiry != nil {
                            try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                        }
                    }
                )

            case let .reactionSelected(messageHash, emoji):
                guard !messageHash.isEmpty,
                      let target = Data(hexString: messageHash),
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                let me = state.myAddressHex
                let mine = state.threadReactionRows.first { $0.messageHash == messageHash && $0.reactorHex == me }
                // Same emoji again = remove (Signal/iMessage toggle).
                let newEmoji = mine?.emoji == emoji ? "" : emoji
                // Strictly monotonic per reactor so two taps in one clock tick still apply in order
                // on both ends (Reaction.apply ignores equal timestamps).
                let sentAt = max(date.now.timeIntervalSince1970, (mine?.sentAt ?? 0) + 0.001)
                let msg = LXMessage.create(
                    source: state.identity,
                    destinationHash: peer,
                    timestamp: sentAt,
                    title: Data(),
                    content: Data(),
                    fields: ReactionWire.encode(target: target, emoji: newEmoji)
                )
                let row = Reaction(messageHash: messageHash, reactorHex: me, emoji: newEmoji, sentAt: sentAt)
                // Optimistic: update in-memory rows now so a second tap before the reload sees it.
                state.setThreadReactionRows(
                    state.threadReactionRows.filter { !($0.messageHash == messageHash && $0.reactorHex == me) } + [row]
                )
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                    .run { [database] send in
                        try await database.write { try Reaction.apply(row, $0) }
                        try await reloadThread(database, peerHex, send)
                    }
                )

            case let .replyTapped(id):
                // Only a message with an LXMF hash can be replied to: the hash is what FIELD_REPLY_TO
                // carries. A hashless legacy row, or an id from a menu that outlived a thread reload,
                // leaves any reply already in progress alone.
                guard let message = state.threadMessages.first(where: { $0.id == id }),
                      !message.messageHash.isEmpty else { return .none }
                state.replyTarget = ReplyTarget(
                    messageHash: message.messageHash,
                    body: AttachmentPlaceholder.preview(body: message.body,
                                                        attachment: state.attachmentsByMessageId[message.id]),
                    isOutgoing: message.isOutgoing)
                return .none

            case .replyCancelled:
                state.replyTarget = nil
                return .none

            case let .attachmentPicked(item):
                // A read that outlived its chat view (the user switched conversations while the
                // picker was still loading) must not land in another conversation's composer.
                guard item.peerHex == state.openPeerHex else { return .none }
                // A new pick replaces whatever was pending, even if it then fails.
                state.pendingAttachment = nil
                state.attachmentError = nil
                state.attachmentPreparing = true
                state.attachmentOriginalRequested = nil
                return prepareEffect(item, original: false)

            case let .attachmentLoadStarted(peerHex):
                // The spinner shows while the picker reads (an iCloud photo can take a while). Any
                // earlier pick is being replaced, so its preparation stops too.
                guard peerHex == state.openPeerHex else { return .none }
                state.pendingAttachment = nil
                state.attachmentError = nil
                state.attachmentPreparing = true
                state.attachmentOriginalRequested = nil
                return .cancel(id: CancelID.attachmentPreparation)

            case let .attachmentOriginalToggled(original):
                // Compared with the value last ASKED for while a re-encode is in flight, so toggling
                // back before it lands is not mistaken for "already in that state".
                guard let pending = state.pendingAttachment, pending.isImage,
                      let source = pending.originalSource,
                      (state.attachmentOriginalRequested ?? pending.isOriginal) != original
                else { return .none }
                state.attachmentPreparing = true
                state.attachmentOriginalRequested = original
                // The name is passed through so a toggle never renames the photo.
                return prepareEffect(PickedItem(kind: AttachmentKind.image, name: pending.name, data: source,
                                                peerHex: state.openPeerHex ?? ""),
                                     original: original)

            case let .attachmentPrepared(pending):
                state.pendingAttachment = pending
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                return .none

            case let .attachmentFailed(reason):
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = reason
                state.attachmentOriginalRequested = nil
                // The view sends this too (a picker read failed) while an earlier pick may still be
                // encoding: stop it, or its late result would replace the error. Harmless when the
                // preparation itself sent it.
                return .cancel(id: CancelID.attachmentPreparation)

            case .attachmentRemoved:
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                return .cancel(id: CancelID.attachmentPreparation)

            case let .attachmentSendFailed(draft):
                // Inline, in the attachment bar (no alert plumbing): nothing was sent, the caption
                // comes back, and the attachment has to be picked again.
                state.attachmentError = AttachmentPreparation.storeFailed
                state.draft = draft
                return .none

            case let .node(.client(.endpoint(.delegate(.pathLearned(h, _))))):
                // LXMFNode's Scope reducer has already run and updated state.node.client.learnedPeers[h]
                // if the announce was a delivery-destination one with valid app-data. Persist whatever
                // the library stored — if nothing was stored (not a delivery announce, or no app-data),
                // there is nothing to write. Only delivery announces update learnedPeers (see
                // LXMFNode.swift:633-641), so an absent entry here means "not a delivery peer".
                let peerToStore: (key: Data, peer: LXMFNode.LearnedPeer)?
                if let peer = state.node.client.learnedPeers[h] {
                    peerToStore = (key: h, peer: peer)
                } else {
                    peerToStore = nil
                }
                state.reachablePeers.insert(h.hexString)

                // Arm (or restart) the debounce timer for the learned-destination table. ALL
                // pathLearned events touch Transport.State.learned (that is what pathLearned means),
                // so we arm the debounce unconditionally here — even when learnedPeers has no entry
                // (not a delivery-destination announce). The debounce writes the ENTIRE learned
                // table once the interval elapses, so rapid announces are coalesced into one write.
                //
                // Write policy: debounced, not per-event. See LearnedDestinationRow for the full
                // ruling. The contrast with LearnedPeerRow (per-event) is intentional and explained
                // there: path updates are continuous on a meshed network; peer announces are not.
                let debounceEffect: Effect<Action> = .run { [clock] send in
                    try await clock.sleep(for: .seconds(30))
                    await send(._flushLearnedDestinations)
                }
                .cancellable(id: CancelID.learnedDebounce, cancelInFlight: true)

                guard let (hashKey, learned) = peerToStore else {
                    return debounceEffect
                }
                let hashHex = hashKey.hexString
                let row = LearnedPeerRow(
                    destinationHashHex: hashHex,
                    displayName: learned.displayName,
                    stampCost: learned.stampCost,
                    supportsCompression: learned.supportsCompression,
                    learnedAt: learned.learnedAt
                )
                return .merge(
                    debounceEffect,
                    .run { [database] _ in
                        try await database.write { db in
                            try LearnedPeerRow.where { $0.destinationHashHex.eq(hashHex) }.delete().execute(db)
                            try LearnedPeerRow.insert { row }.execute(db)
                        }
                    }
                )

            case let .node(.client(.delegate(.messageReceived(m, validated, method)))):
                let incomingPeer = m.sourceHash.hexString
                // DIAGNOSTIC (2026-08-21) — remove once the empty-body question is settled.
                //
                // Messages from Sideband are landing with an empty `content` while the sender
                // reports them delivered. This is NOT a framing bug: `LXMessage.unpack` is strict
                // and returns nil on any malformed frame, and `LXMFRouter.received` drops nil — so
                // nothing can reach here with a body that merely failed to parse. The content is
                // genuinely empty on the wire, which means the payload is most likely in `fields`.
                // LXMF defines FIELD_TELEMETRY (0x02), FIELD_ICON_APPEARANCE (0x04) and
                // FIELD_COMMANDS (0x09), all of which carry empty content by design, and this app
                // renders every delivered message as a chat bubble while discarding `fields`.
                //
                // That is a HYPOTHESIS. This line records what actually arrived so it can be
                // confirmed or killed with evidence instead of being fixed on a guess.
                let fieldKeys = m.fields.map { "0x" + String($0.key, radix: 16) }.joined(separator: ",")
                let wireBytes = m.receivedBytes?.count ?? -1
                AppFeature.inbound.notice("""
                    inbound lxmf from=\(incomingPeer.prefix(8), privacy: .public) \
                    content=\(m.content.count, privacy: .public)B \
                    title=\(m.title.count, privacy: .public)B \
                    fields=[\(fieldKeys, privacy: .public)] \
                    wire=\(wireBytes, privacy: .public)B \
                    validated=\(validated, privacy: .public)
                    """)
                let seenHashHex = m.hash.hexString
                let seenNow = date.now
                let openPeer = state.openPeerHex
                switch ReactionWire.decode(m.fields) {
                case let .reaction(target, emoji):
                    // Reactions never become bubbles and never touch the conversation list.
                    // Unvalidated ones can't be attributed, so only the seen hash is recorded.
                    let reaction: Reaction? = validated
                        ? Reaction(messageHash: target.hexString, reactorHex: incomingPeer,
                                   emoji: emoji, sentAt: m.timestamp)
                        : nil
                    return .run { [database] send in
                        try await database.write { db in
                            if let reaction { try Reaction.apply(reaction, db) }
                            try recordSeenHash(seenHashHex, at: seenNow, db)
                        }
                        if reaction != nil, incomingPeer == openPeer {
                            try await reloadThread(database, incomingPeer, send)
                        }
                    }
                case .malformed:
                    return .run { [database] _ in
                        try await database.write { try recordSeenHash(seenHashHex, at: seenNow, $0) }
                    }
                case .notReaction:
                    break
                }
                // Standard LXMF reply fields (0x30 / 0x31). Only an ordinary message gets here: a
                // reaction that also carries reply fields was handled above, reply fields ignored.
                let reply = ReplyWire.decode(m.fields)
                // Disappearing messages (spec §3 "Receiving", amendments A1, A4, A5). Only a
                // validated sender may set or carry a timer: an unsigned message is plain text.
                let decodedExpiry = validated ? ExpiryWire.decode(m.fields) : nil
                let isTimerChange = decodedExpiry?.isChange == true
                // Standard LXMF attachment fields (0x05 / 0x06). Decoded here, written inside the
                // effect: the bytes go to disk first, then the message and attachment rows land in
                // one transaction. A field that does not decode leaves an ordinary text message.
                // A timer-change line never carries one (amendment A14): nothing would show it.
                let decodedAttachment = isTimerChange ? nil : AttachmentWire.decode(m.fields)
                if let dropped = decodedAttachment?.droppedFileCount, dropped > 0 {
                    // Spec §2: one attachment per message is kept; say what was left out.
                    AppFeature.inbound.notice("attachment: kept one, dropped \(dropped, privacy: .public) other file entries from \(String(m.hash.hexString.prefix(8)), privacy: .public)")
                }
                let incomingSeconds: Int? = {
                    guard let decoded = decodedExpiry, !decoded.isChange, decoded.seconds > 0 else { return nil }
                    return decoded.seconds
                }()
                // Arriving into the open thread while the app is active and the chat is on screen
                // (amendment A11) is "viewed" at once.
                let viewedNow: Date? = (incomingPeer == openPeer && state.isForeground && state.chatVisible) ? date.now : nil
                let peerName = state.peerDisplayName(incomingPeer)
                // Captured by value for the effect: when the sender says it wrote the message (A10).
                let senderTime = MessageMetadata.senderTimestamp(m.timestamp)
                let receivedBody = String(decoding: m.content, as: UTF8.self)
                let attachmentStore = self.attachmentStore
                let attachmentCacheEvictor = self.attachmentCacheEvictor
                // Receiving gives no path back to the sender (it needed a path to US; a propagated
                // download gives none at all), so a sender whose delivery announce we never heard
                // would stay un-repliable. Ask for its path; the response unlocks Send via pathLearned.
                let pathRequest = state.pathRequestIfUnreachable(incomingPeer)
                let row = Message(
                    id: UUID(),
                    peerHex: incomingPeer,
                    isOutgoing: false,
                    // Amendment A13: a change row always shows our own sentence for the decoded
                    // value, so the line cannot be made to say something other than what was set.
                    body: isTimerChange
                        ? ExpiryPreset.peerAnnouncement(peerName: peerName, seconds: decodedExpiry?.seconds ?? 0)
                        : receivedBody,
                    timestamp: date.now,
                    status: MessageStatus.received,
                    validated: validated,
                    messageHash: seenHashHex,
                    senderTimestamp: senderTime,
                    arrivalMethod: MessageMetadata.arrivalMethod(method),
                    wireSize: m.receivedBytes?.count,
                    titleSize: m.title.count,
                    contentSize: m.content.count,
                    fieldKeys: MessageMetadata.fieldKeys(m.fields),
                    stampState: MessageMetadata.stampState(m),
                    replyToHash: reply?.replyTo.hexString,
                    replyQuote: reply?.quote,
                    expirySeconds: incomingSeconds,
                    expiresAt: incomingSeconds.flatMap { seconds in
                        viewedNow.map { $0.addingTimeInterval(TimeInterval(seconds)) }
                    },
                    isTimerChange: isTimerChange
                )
                let storeMessage: Effect<Action> = .run { [database] send in
                    var pendingAttachmentRow: Attachment? = nil
                    if let decoded = decodedAttachment {
                        // An image ImageIO cannot read is kept as a file so it can still be shared.
                        let dims = decoded.kind == AttachmentKind.image ? ImageEncoder.dimensions(of: decoded.data) : nil
                        let kind = (decoded.kind == AttachmentKind.image && dims == nil) ? AttachmentKind.file : decoded.kind
                        // Review Focus 4: a failed write keeps the row with no bytes (path "").
                        let path: String
                        do {
                            path = try attachmentStore.store(decoded.data, messageHash: seenHashHex,
                                                             outgoing: false, ext: decoded.format)
                        } catch {
                            AppFeature.inbound.error("attachment write failed for \(seenHashHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                            path = ""
                        }
                        pendingAttachmentRow = Attachment(
                            id: UUID(), messageId: row.id, kind: kind, name: decoded.name,
                            format: decoded.format, size: decoded.data.count,
                            width: dims?.width, height: dims?.height, path: path)
                    }
                    // A `let` copy so an escaping `@Sendable` closure captures a value, not the
                    // mutable var above.
                    let attachmentRow = pendingAttachmentRow
                    let storedExpiresAt = try await database.write { db -> Date? in
                        var stored = row
                        if let decoded = decodedExpiry {
                            // Amendment A10: the value is applied only when it was set later than the
                            // stored one. Its time is the sender's timestamp, capped at arrival so a
                            // future-dated clock cannot lock the timer. No stored row means adopt. A
                            // change message that is not newer is still stored as its line below.
                            let effectiveAt = min(senderTime ?? seenNow, seenNow)
                            let setting = try ConversationSetting.current(for: incomingPeer, db)
                            let isNewer = setting.map { effectiveAt > $0.updatedAt } ?? true
                            if isNewer {
                                let current = try ConversationSetting.expiry(for: incomingPeer, db) ?? 0
                                if decoded.isChange {
                                    try ConversationSetting.set(incomingPeer, seconds: decoded.seconds, at: effectiveAt, db)
                                } else if decoded.seconds != current {
                                    // Convergence after a missed change message: adopt the peer's timer
                                    // and say so, 1 ms before the message so the line sorts above it.
                                    try ConversationSetting.set(incomingPeer, seconds: decoded.seconds, at: effectiveAt, db)
                                    try Message.insert {
                                        Message(id: UUID(), peerHex: incomingPeer, isOutgoing: false,
                                                body: ExpiryPreset.peerAnnouncement(peerName: peerName, seconds: decoded.seconds),
                                                timestamp: row.timestamp.addingTimeInterval(-0.001),
                                                status: MessageStatus.received, validated: validated,
                                                messageHash: "", fieldKeys: "", isTimerChange: true)
                                    }.execute(db)
                                }
                            }
                        } else if !isTimerChange, let local = try ConversationSetting.expiry(for: incomingPeer, db) {
                            // Amendment A12: a message with no expiry of ours (none, a foreign 0xFD,
                            // a malformed one, or an unsigned sender) takes the local timer, so this
                            // device deletes the whole conversation on the user's own setting. It
                            // never changes the setting (spec §3).
                            stored.expirySeconds = local
                            stored.expiresAt = viewedNow.map { $0.addingTimeInterval(TimeInterval(local)) }
                        }
                        try Message.insert { stored }.execute(db)
                        if let attachmentRow {
                            try Attachment.insert { attachmentRow }.execute(db)
                        }
                        // Persist the seen hash so a cold start doesn't re-deliver this message.
                        // Upsert: replace any existing row for the same hash (a duplicate from a
                        // previous session should already be in seen, but a re-deliver would be
                        // wrong regardless). Then prune to RingSet.capacity so the table mirrors
                        // the in-memory ring and doesn't grow without bound.
                        try recordSeenHash(seenHashHex, at: seenNow, db)
                        return stored.expiresAt
                    }
                    try await reloadConversations(database, send)
                    if incomingPeer == openPeer {
                        try await reloadThread(database, incomingPeer, send)
                    }
                    if storedExpiresAt != nil {
                        try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: seenNow, send)
                    }
                }
                return .merge(pathRequest, storeMessage)

            case let .node(.client(.delegate(.deliveryFailed(hash)))):
                return markUndeliverable(&state, hash, status: MessageStatus.failed, reason: nil)

            case let .node(.client(.delegate(.deliveryRejected(hash)))):
                // The recipient refused the transfer: terminal, styled as failed with a reason.
                return markUndeliverable(&state, hash, status: MessageStatus.failed, reason: FailureReason.rejected)

            case let .node(.client(.delegate(.deliveryCancelled(hash)))):
                // The user stopped the send: its own status, same guards and milestone as failed.
                return markUndeliverable(&state, hash, status: MessageStatus.cancelled, reason: FailureReason.cancelled)

            case let .conversationsLoaded(rows):
                state.conversations = rows
                return .none

            case let .threadLoaded(rows, reactions, attachments):
                state.threadMessages = rows
                // Spec §2: in a group thread the reactor must be me or a current member; in a peer
                // thread me or the open peer. `groupLoaded` lands first, so the members are known.
                let allowed: Set<String> = state.openConversationKind == .group
                    ? Set(state.openGroupMembers.map(\.memberHex)).union([state.myAddressHex])
                    : [state.myAddressHex, state.openPeerHex ?? ""]
                state.setThreadReactionRows(reactions.filter { allowed.contains($0.reactorHex) })
                state.attachmentsByMessageId = Attachment.byMessageId(attachments)
                return .none

            case let .conversationExpiryLoaded(peerHex, seconds):
                // Guarded like reactions and attachments: a late load for a thread the user has
                // left must not label the next conversation with the previous one's timer.
                guard peerHex == state.openPeerHex else { return .none }
                state.openConversationExpiry = seconds
                state.openConversationExpiryLoaded = true
                return .none

            case let .expirySelected(seconds):
                guard let peerHex = state.openPeerHex, let peer = Data(hexString: peerHex) else { return .none }
                let seconds = ExpiryWire.clamp(seconds)
                // Amendment A14: picking the value already in force sends and stores nothing.
                guard seconds != (state.openConversationExpiry ?? 0) else { return .none }
                state.openConversationExpiry = seconds > 0 ? seconds : nil
                // The user's pick is the truth from here on, ahead of the database write below.
                state.openConversationExpiryLoaded = true
                let now = date.now
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                // The change goes out as a message with a readable body (spec §1): other LXMF
                // clients show the sentence, ReTiCaMsgr peers adopt the timer from the field.
                let (msg, row) = Self.outgoing(
                    identity: state.identity, peer: peer, peerHex: peerHex,
                    text: ExpiryPreset.announcement(seconds: seconds), now: now,
                    fields: ExpiryWire.encodeChange(seconds: seconds), alsoViaPropagation: alsoViaPropagation,
                    replyToHash: nil, replyQuote: nil, isTimerChange: true)
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                    .run { [database] send in
                        try await database.write { db in
                            try ConversationSetting.set(peerHex, seconds: seconds, at: now, db)
                            try Message.insert { row }.execute(db)
                        }
                        try await reloadThread(database, peerHex, send)
                        try await reloadConversations(database, send)
                    }
                )

            case let .expiryPurgeCompleted(purged, nextDue):
                // Reload only when something went (amendment A2): every caller already reloaded
                // after its own write, so a no-op purge must not reload twice.
                let openPeer = state.openPeerHex
                let reload: Effect<Action> = purged > 0
                    ? .run { [database] send in
                        try await reloadConversations(database, send)
                        if let openPeer { try await reloadThread(database, openPeer, send) }
                    }
                    : .none
                // Amendment A15: purges run concurrently (a send and an arrival, say) and their
                // completions can land out of order. A completion with nothing due, or with a later
                // deadline than the one armed, may be stale, so it never cancels or postpones the
                // live sleeper. That sleeper fires on time, purges, and re-arms from fresh data.
                guard let nextDue else { return reload }
                if let armed = state.armedExpiry, armed <= nextDue { return reload }
                state.armedExpiry = nextDue
                let delay = max(0, nextDue.timeIntervalSince(date.now))
                let sleeper: Effect<Action> = .run { [clock] send in
                    try await clock.sleep(for: .seconds(delay))
                    await send(.expiryDue)
                }
                .cancellable(id: CancelID.expiry, cancelInFlight: true)
                return .merge(reload, sleeper)

            case .expiryDue:
                // The armed deadline has passed: whatever the purge finds next is a new deadline.
                state.armedExpiry = nil
                return .run { [database, attachmentStore, attachmentCacheEvictor, now = date.now] send in
                    try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                }

            case let .setNodeMode(enabled):
                state.$nodeModeEnabled.withLock { $0 = enabled }
                return .send(.node(.setNodeMode(enabled)))

            case let .setRelayMode(enabled):
                // Persist, then apply immediately so toggling while connected takes effect without a
                // reconnect (mirrors setNodeMode). Enabling installs THIS device's identity as the
                // Transport identity (the gate every relay branch checks) and turns on recursive path
                // requests; disabling clears the identity — relaying goes back to dead — and stops
                // answering path requests for third parties. There is no `disableRelay` verb, so the
                // clear goes through the raw transport action. The persisted flag is re-applied on
                // interfaceConnected so it survives relaunch.
                state.$relayEnabled.withLock { $0 = enabled }
                if enabled {
                    let identity = state.identity
                    return .merge(
                        .send(.node(.client(.endpoint(.enableRelay(identity))))),
                        .send(.node(.client(.endpoint(.transport(.setRecursivePathRequests(true))))))
                    )
                } else {
                    return .merge(
                        .send(.node(.client(.endpoint(.transport(.setTransportIdentity(nil)))))),
                        .send(.node(.client(.endpoint(.transport(.setRecursivePathRequests(false))))))
                    )
                }

            case let .setPropagationNode(hex):
                state.$propagationNodeHex.withLock { $0 = hex }
                guard let pn = Data(hexString: hex), pn.count == 16 else { return .none }
                return .merge(
                    .send(.node(.client(.setPropagationNode(destinationHash: pn)))),
                    .send(.node(.client(.syncFromPropagationNode)))
                )

            case let .setDisplayName(name):
                // Persist the TRIMMED value so local state and the wire agree, and so
                // `displayName.isEmpty` stays a correct "no name set" test for the UI.
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                state.$displayName.withLock { $0 = trimmed }
                // Empty maps to nil for the same reason as the launch path above — but note it must
                // still be SENT. An earlier version had `guard !name.isEmpty else { return .none }`
                // here, which meant CLEARING a name updated local state and told the network nothing,
                // so peers kept showing the old name forever. That is the same defect this whole
                // feature exists to fix (state changed locally, announce never updated), and it
                // survived because the tests covered only the launch path, not this setter.
                // Announcing unconditionally is safe: this action is a settled edit (a Save tap), not
                // a per-keystroke binding — the keystroke flood is what the pod's setter/announce
                // split guards against (LXMFNode.swift:181-190) — and `announceDelivery` is a
                // documented no-op before `registerDelivery` (LXMFNode.swift:352-354), so naming
                // yourself while disconnected costs nothing.
                let advertised: String? = trimmed.isEmpty ? nil : trimmed
                return .merge(
                    .send(.node(.client(.setDisplayName(advertised, stampCost: nil)))),
                    .send(.node(.client(.announceDelivery)))
                )

            case .syncTapped:
                return .send(.node(.client(.syncFromPropagationNode)))

            case .announceTapped:
                return .send(.node(.client(.announceDelivery)))

            case let .announceRowTapped(hex):
                guard let hash = Data(hexString: hex), hash.count == 16 else { return .none }
                // The key comes from the peer's announce in the learned table: the announce is signed
                // by that key and the destination hash is derived from it, so it is authenticated.
                // There is no network request. The former link + `/publicKey` request could only run
                // when this entry existed (`openLink` needs it), so it never learned anything new, and
                // reference LXMF peers (NomadNet, Sideband) never answer `/publicKey` ("no response").
                // This device still ANSWERS `/publicKey` (handler registered on interfaceConnected).
                if let known = state.node.client.endpoint.learned[hash]?.identity {
                    state.publicKeyRequests[hex] = .received(publicKeyHex: known.publicKey.hexString)
                } else {
                    state.publicKeyRequests[hex] = .failed(reason: "key unknown (no announce heard)")
                }
                return .none

            case let .node(.client(.delegate(.propagationAccepted(hash)))):
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                let milestoneAt: Date? = date.now
                return .run { [database] send in
                    try await database.write { db in
                        // Same hash-collision hazard as `deliveryFailed` above: scope to outgoing
                        // rows only so an incoming row sharing this hash isn't rewritten.
                        // Delivered beats stored: the propagated copy can be accepted after the
                        // delivery copy was already proved, so leave delivered rows alone.
                        try Message.where {
                            $0.messageHash.eq(hex) && $0.status.neq(MessageStatus.delivered) && $0.isOutgoing
                        }
                            .update { $0.status = MessageStatus.propagated }
                            .execute(db)
                        // Info milestone: the FIRST acceptance time, including a late acceptance
                        // after "delivered" (the status stays delivered, the time is still news).
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.storedAt.is(nil) }
                            .update { $0.storedAt = milestoneAt }
                            .execute(db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }

            case let .node(.client(.delegate(.deliveryConfirmed(hash)))):
                // The recipient proved receipt of the delivery copy (for opportunistic sends, via
                // ReTiCA single-packet proofs). Without this a delivered message would read "sending"
                // forever, because a proving peer never yields a later `deliveryFailed`.
                let hex = hash.hexString
                state.outgoingProgress[hex] = nil
                let openPeer = state.openPeerHex
                let milestoneAt: Date? = date.now
                // Optional on purpose, like `milestoneAt`: the update subscript takes an optional
                // expression, not a nil literal.
                let noReason: String? = nil
                return .run { [database] send in
                    try await database.write { db in
                        // Same hash-collision hazard as `deliveryFailed` above: scope to outgoing
                        // rows only so an incoming row sharing this hash isn't rewritten.
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing }
                            .update {
                                $0.status = MessageStatus.delivered
                                // A failure reported before the proof no longer applies.
                                $0.failureReason = noReason
                            }
                            .execute(db)
                        // Info milestone: the FIRST proof time. A repeat proof never moves it.
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.deliveredAt.is(nil) }
                            .update { $0.deliveredAt = milestoneAt }
                            .execute(db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }

            case let .node(.delegate(.messagesStored(entries))):
                let rows = entries.map {
                    PropagationEntryRow(transientIdHex: $0.transientId.hexString,
                                        destinationHashHex: $0.destinationHash.hexString,
                                        lxmfData: $0.lxmfData,
                                        storedAt: date.now)
                }
                return .run { [database] _ in
                    try await database.write { db in
                        for row in rows {
                            try PropagationEntryRow.where { $0.transientIdHex.eq(row.transientIdHex) }
                                .delete().execute(db)
                            try PropagationEntryRow.insert { row }.execute(db)
                        }
                    }
                }

            case let .node(.delegate(.messagesPurged(ids))):
                let hexes = ids.map(\.hexString)
                return .run { [database] _ in
                    try await database.write { db in
                        try PropagationEntryRow.where { $0.transientIdHex.in(hexes) }.delete().execute(db)
                    }
                }

            case let .rehydratePropagationStore(entries):
                // Restore through the tested ingest path (re-validates + re-dedups) rather than a bypass.
                guard !entries.isEmpty else { return .none }
                let container = LXMFPropagation.container(timestamp: date.now.timeIntervalSince1970,
                                                          entries: entries)
                return .send(.node(.pn(.ingestContainer(container))))

            case let .rehydrateDedup(seenHashes, downloadedTransientIds):
                // Forward to the library reducer — it inserts hashes into the RingSet and unions
                // the transient-ID set. No app-level state to update.
                return .send(.node(.client(.router(.rehydrateDedup(
                    seenHashes: seenHashes, downloadedTransientIds: downloadedTransientIds)))))

            case let .rehydrateLearnedPeers(peers):
                // Forward to the library reducer — it sweeps expired entries and restores the rest,
                // never overwriting a fresher live entry that arrived via announce before this DB
                // read completed.
                return .send(.node(.client(.rehydrateLearnedPeers(peers))))

            case let .rehydrateLearnedDestinations(destinations):
                // Forward to Transport via the full action path. The Transport reducer sweeps
                // expired and future-dated entries in this same pass (matching the prune done at
                // launch) and never overwrites a fresher live entry — so an announce that arrived
                // before this DB read completes is not displaced.
                //
                // Path: AppFeature → LXMFServiceNode → LXMFNode → TransportEndpoint
                //       → Transport.rehydrateLearnedDestinations (transport is now shared at the
                //       container level, so the address no longer traverses the tcpClient slot)
                guard !destinations.isEmpty else { return .none }
                // Launch race: if the interface already registered before this DB read landed, the seed in
                // interfaceConnected (Task 1) ran against an empty learned table and missed these entries. Seed
                // from the payload now — only those whose interface is currently registered (same reachability
                // test). No-op when disconnected: interfaceConnected will seed from Transport.learned instead.
                if state.connection == .connected {
                    seedReachablePeers(&state, from: destinations)
                }
                return .send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations(destinations))))))

            case let .node(.client(.router(.messagesDownloaded(transientIds)))):
                // Persist the newly-downloaded transient IDs so a cold start doesn't re-request
                // them on the next sync. An empty batch requires no write.
                guard !transientIds.isEmpty else { return .none }
                let tidRows = transientIds.map {
                    DownloadedTransientIdRow(transientIdHex: $0.hexString, storedAt: date.now)
                }
                return .run { [database] _ in
                    try await database.write { db in
                        for tidRow in tidRows {
                            try DownloadedTransientIdRow
                                .where { $0.transientIdHex.eq(tidRow.transientIdHex) }
                                .delete().execute(db)
                            try DownloadedTransientIdRow.insert { tidRow }.execute(db)
                        }
                        // downloadedTransientIds is deliberately NOT pruned — see
                        // DownloadedTransientIdRow for the ruling and revisit trigger.
                    }
                }

            case let .node(.client(.delegate(.deliveryProgress(hash, fraction)))):
                // Monotonic per message: a retry restarts the wire transfer, the bar does not.
                let hex = hash.hexString
                let clamped = min(max(fraction, 0), 1)
                state.outgoingProgress[hex] = max(state.outgoingProgress[hex] ?? 0, clamped)
                return .none

            case let .node(.client(.delegate(.propagationRefused(hash, reason)))):
                // The propagated copy was never sent; the direct copy decides the message. Recorded
                // for the Info sheet so "stored" never arriving has an explanation.
                let hex = hash.hexString
                // Optional on purpose: the column is `String?`, and structured-queries' update
                // subscript takes an optional expression (the `milestoneAt: Date?` pattern).
                let text: String?
                switch reason {
                case .tooLargeForNode: text = PropagationRefusal.tooLargeForNode
                }
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write { db in
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing }
                            .update { $0.propagationRefused = text }
                            .execute(db)
                    }
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }

            case let .cancelSendTapped(id):
                // Only our own message, still sending, with a hash the node can act on.
                guard let message = state.threadMessages.first(where: { $0.id == id }),
                      message.isOutgoing, message.status == MessageStatus.sending,
                      let hash = Data(hexString: message.messageHash), !hash.isEmpty
                else { return .none }
                return .send(.node(.client(.cancelOutbound(messageHash: hash))))

            case let .node(.client(.delegate(.inboundTransferProgress(sourceHash, linkID, fraction)))):
                if fraction >= 1 {
                    state.inboundTransfers[linkID] = nil
                    return .cancel(id: CancelID.inboundTransfer(linkID))
                }
                // Clamped like `deliveryProgress`; NaN (which fails every comparison) reads as 0.
                let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
                state.inboundTransfers[linkID] = InboundTransfer(sourceHash: sourceHash, fraction: clamped, updatedAt: date.now)
                // Review Focus 7: every report restarts the silence timer.
                return .run { [clock] send in
                    try await clock.sleep(for: AppFeature.inboundTransferTimeout)
                    await send(.inboundTransferTimedOut(linkID: linkID))
                }
                .cancellable(id: CancelID.inboundTransfer(linkID), cancelInFlight: true)

            case let .inboundTransferTimedOut(linkID):
                state.inboundTransfers[linkID] = nil
                return .none

            case .node, .binding, .pushRegistrationTimedOut:
                return .none
            }
        }

        Reduce { state, action in
            // Push registration over the hub's link (spec amendment A2). Translate the actions the
            // flow cares about into its events, run it, and turn its commands into endpoint actions.
            let event: RegistrationLinkFlow.Event?
            switch action {
            case let .push(.delegate(.sendRegistration(hub, path, data))):
                // I1: `sendRegistration` fired at launch races the socket — `learned[hub]` can
                // exist (rehydrated from the previous session) while the interface itself is not
                // up yet, so `openLink` would fail `.pathStale` at once; an unknown hub would send
                // a path request nothing can answer. Buffer until the TCP interface actually
                // connects, then `interfaceConnected` resumes this with the real check below.
                let tcpID = state.node.client.endpoint.tcpClient?.interfaceID
                guard let tcpID, state.connectedInterfaces.contains(tcpID) else {
                    state.pendingPushRegistration = PendingPushRegistration(hub: hub, path: path, data: data)
                    event = nil
                    break
                }
                let known = state.node.client.endpoint.transport.reachableLearned(hub) != nil
                event = .start(hub: hub, path: path, data: data, hubKnown: known)
            case let .node(.client(.endpoint(.delegate(.pathLearned(hash, _))))):
                event = .pathLearned(hash)
            case let .node(.client(.endpoint(.delegate(.linkEstablished(linkID, hash))))):
                event = .linkEstablished(linkID: linkID, destinationHash: hash)
            case let .node(.client(.endpoint(.delegate(.linkFailed(hash, _))))):
                event = .linkFailed(destinationHash: hash)
            case let .node(.client(.endpoint(.delegate(.linkClosed(linkID, _))))):
                event = .linkClosed(linkID: linkID)
            case let .node(.client(.endpoint(.delegate(.responseReceived(linkID, _, data))))):
                event = .responseReceived(linkID: linkID, data: data)
            case let .node(.client(.endpoint(.delegate(.requestFailed(linkID, _))))):
                event = .requestFailed(linkID: linkID)
            case .pushRegistrationTimedOut:
                event = .timedOut
            default:
                event = nil
            }
            guard let event else { return .none }
            let commands = state.pushRegistrationFlow.handle(event)
            var effects: [Effect<Action>] = []
            if case .start = event {
                effects.append(
                    .run { [clock] send in
                        try await clock.sleep(for: AppFeature.pushRegistrationTimeout)
                        await send(.pushRegistrationTimedOut)
                    }
                    .cancellable(id: CancelID.pushRegistration, cancelInFlight: true)
                )
            }
            let identity = state.identity
            // Commands run IN ORDER (`identify` must precede `sendRequest`, or the hub answers
            // `not_identified`): concatenate the sends, and merge only the timer alongside.
            var ordered: [Effect<Action>] = []
            for command in commands {
                switch command {
                case let .requestPath(hub):
                    ordered.append(.send(.node(.client(.endpoint(.requestPath(destinationHash: hub))))))
                case let .openLink(hub):
                    ordered.append(.send(.node(.client(.endpoint(.openLink(destinationHash: hub))))))
                case let .identify(linkID):
                    ordered.append(.send(.node(.client(.endpoint(.identifyOverLink(linkID: linkID, identity: identity))))))
                case let .sendRequest(linkID, path, data):
                    ordered.append(.send(.node(.client(.endpoint(.sendRequestOverLink(linkID: linkID, path: path, data: data))))))
                case let .closeLink(linkID):
                    ordered.append(.send(.node(.client(.endpoint(.closeLink(linkID: linkID))))))
                case let .finished(result):
                    switch result {
                    case let .success(data):
                        ordered.append(.cancel(id: CancelID.pushRegistration))
                        ordered.append(.send(.push(.registrationResponse(.success(data)))))
                    case .failure(.cancelled):
                        // I2: a cancellation is caused by a newer attempt's `.start`, whose own
                        // timer was just armed with `cancellable(id:, cancelInFlight: true)` —
                        // that already retired the old timer. Cancelling here too would hit the
                        // SAME CancelID and retire the NEW attempt's timer instead (a stray cancel
                        // on an otherwise-idle flow is a no-op, so this is not merely redundant,
                        // it is actively wrong). The newer attempt reports its own result;
                        // forwarding this one would land on it.
                        break
                    case let .failure(failure):
                        ordered.append(.cancel(id: CancelID.pushRegistration))
                        ordered.append(.send(.push(.registrationResponse(.failure(RegistrationFailure(failure))))))
                    }
                }
            }
            if !ordered.isEmpty { effects.append(.concatenate(ordered)) }
            return effects.isEmpty ? .none : .merge(effects)
        }
    }

    /// The open thread is being looked at again (`.foregrounded`, `.chatAppeared`): stamp its
    /// unstamped rows (first view, spec §3) and reload it if any changed, but only while ChatView is
    /// on screen (amendment A11). Rows that fell due meanwhile are purged and the sleeper re-armed
    /// either way.
    private func viewOpenThreadEffect(_ state: State) -> Effect<Action> {
        let openPeer = state.openPeerHex
        let chatVisible = state.chatVisible
        return .run { [database, attachmentStore, attachmentCacheEvictor, now = date.now] send in
            if let openPeer, chatVisible, try await stampViewed(database, openPeer, now: now) > 0 {
                try await reloadThread(database, openPeer, send)
            }
            try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
        }
    }

    /// A message that will not go out: `failed` or `cancelled`, with the reason the Info sheet
    /// shows. The status guards keep a stored or delivered row as it is (a success is never
    /// clobbered) and a cancelled one too (the user's cancel is terminal, and a later failure
    /// report for it must not rewrite its reason). `messageHash` alone is not unique (an incoming
    /// row can share it) so only outgoing rows are touched, and `failedAt` records the FIRST
    /// failure time only.
    private func markUndeliverable(_ state: inout State, _ hash: Data, status: String, reason: String?) -> Effect<Action> {
        let hex = hash.hexString
        state.outgoingProgress[hex] = nil
        let openPeer = state.openPeerHex
        let milestoneAt: Date? = date.now
        return .run { [database] send in
            try await database.write { db in
                try Message.where {
                    $0.messageHash.eq(hex)
                        && $0.status.neq(MessageStatus.propagated)
                        && $0.status.neq(MessageStatus.delivered)
                        && $0.status.neq(MessageStatus.cancelled)
                        && $0.isOutgoing
                }
                    .update {
                        $0.status = status
                        $0.failureReason = reason
                    }
                    .execute(db)
                try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.failedAt.is(nil) }
                    .update { $0.failedAt = milestoneAt }
                    .execute(db)
            }
            try await reloadConversations(database, send)
            if let openPeer {
                try await reloadThread(database, openPeer, send)
            }
        }
    }

    /// The outgoing LXMessage and its `sending` row. Outgoing Info metadata: `wireSize` is the
    /// unstamped packed size (LXMFNode adds any stamp downstream, where the app cannot see it, hence
    /// no stampState either). `packed` is a computed re-encode, so it is read once.
    static func outgoing(identity: Identity, peer: Data, peerHex: String, text: String, now: Date,
                         fields: [MsgPackValue.IntPair], alsoViaPropagation: Bool,
                         replyToHash: String?, replyQuote: String?,
                         expirySeconds: Int? = nil, expiresAt: Date? = nil,
                         isTimerChange: Bool = false) -> (LXMessage, Message) {
        let msg = LXMessage.create(
            source: identity,
            destinationHash: peer,
            timestamp: now.timeIntervalSince1970,
            title: Data(),
            content: Data(text.utf8),
            fields: fields
        )
        let packed = msg.packed
        let row = Message(
            id: UUID(),
            peerHex: peerHex,
            isOutgoing: true,
            body: text,
            timestamp: now,
            status: MessageStatus.sending,
            validated: false,
            messageHash: msg.hash.hexString,
            senderTimestamp: now,
            sentViaPropagation: alsoViaPropagation,
            wireSize: packed.count,
            titleSize: msg.title.count,
            contentSize: msg.content.count,
            fieldKeys: MessageMetadata.fieldKeys(msg.fields),
            replyToHash: replyToHash,
            replyQuote: replyQuote,
            expirySeconds: expirySeconds,
            expiresAt: expiresAt,
            isTimerChange: isTimerChange
        )
        return (msg, row)
    }

    /// Encodes a picked item off the main thread (spec §3). One preparation at a time: a newer
    /// pick or Original toggle cancels the one in flight (`cancelInFlight`), and Remove, leaving or
    /// switching the thread, and Send cancel it too, so a late result can never replace or
    /// resurrect the pending attachment (a cancelled effect's `send` is dropped).
    private func prepareEffect(_ item: PickedItem, original: Bool) -> Effect<Action> {
        let now = date.now
        return .run { [clock] send in
            // A real (clock-driven, not cooperative-yield) suspension point BEFORE the encode:
            // under the live `ContinuousClock` this costs 1 ms; under `TestClock` it waits until
            // the test explicitly advances it. Unlike `Task.yield()`, this cannot be satisfied by
            // simply running this task to completion in one scheduling turn, so a `.cancel(id:)`
            // issued concurrently (Remove, leaving, or Send) gets a real, deterministic window to
            // land before the (synchronous, ImageIO-bound) encode ever starts. `clock.sleep`
            // throws `CancellationError` once cancelled; `Effect.run` swallows that silently, so
            // the function simply returns and the cancelled `send` below is never reached.
            try await clock.sleep(for: .milliseconds(1))
            let result = AttachmentPreparation.prepare(item, original: original, now: now)
            // The encode itself is synchronous with no suspension point, so a cancel arriving
            // WHILE it runs can't be caught mid-flight — check again here: a cancel during a long
            // encode must not deliver either.
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(pending): await send(.attachmentPrepared(pending))
            case let .failure(error): await send(.attachmentFailed(error.message))
            }
        }
        .cancellable(id: CancelID.attachmentPreparation, cancelInFlight: true)
    }
}

// The TransportEndpoint is built once at init with the host/port passed to State.init (defaults to
// 127.0.0.1:4242). The Settings fields bind to separate @Shared values, so without this the app
// would always dial those init defaults regardless of what the user configured. Copy the current
// Settings values into the endpoint immediately before dialing (onLaunch / connectTapped).
//
// The endpoint is now a STRUCT product (Task 1b/2): one shared `transport`/`linkPlane`, plus
// optional per-KIND driver slots. The dial host/port live on the `tcpClient` slot's interface, so
// we mutate that slot IN PLACE — never `state.node.client.endpoint = .tcp(...)`, which would
// rebuild the container and reset the shared `transport`/`linkPlane` (learned paths, live links).
//
// This is also where the opt-in listener is applied: `listenEnabled` gates whether the `tcpServer`
// slot is present, and it is decided at connect time here (not at State.init) because the endpoint
// is constructed before the persisted Settings are read in. Toggling the setting takes effect on
// the next connect (onLaunch / connectTapped / foregrounded), matching how host/port already work.
/// The `.foregrounded` re-dial: nothing when the TCP interface is up, otherwise sync the hub
/// settings and start the endpoint. Returns the effects to merge (the hub forward rides along).
private func redialIfTCPDown(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    let tcpID = state.node.client.endpoint.tcpClient?.interfaceID
    if let tcpID, state.connectedInterfaces.contains(tcpID) { return .none }
    state.connection = .connecting
    syncEndpointHostPort(&state)
    let hub = (host: state.host, port: state.port)
    return .merge(
        .send(.node(.client(.endpoint(.start)))),
        .send(.push(.hubChanged(host: hub.host, port: hub.port)))
    )
}

private func syncEndpointHostPort(_ state: inout AppFeature.State) {
    guard state.node.client.endpoint.tcpClient != nil else { return }
    // Read the @Shared Settings into locals first: mutating `state.node…` while reading
    // `state.host`/`state.port` in the same statement is an exclusive-access violation.
    let host = state.host
    let dialPort = UInt16(exactly: state.port)
    let listenEnabled = state.listenEnabled
    let listenPort = UInt16(exactly: state.listenPort)
    let bleEnabled = state.bleEnabled

    state.node.client.endpoint.tcpClient?.interface.host = host
    if let dialPort {
        state.node.client.endpoint.tcpClient?.interface.port = dialPort
    }

    // Add or remove the listener slot to match the current setting. Rebuilding only the OPTIONAL
    // slot leaves the shared transport/linkPlane untouched.
    if listenEnabled, let listenPort {
        // Preserve an already-running listener on the same port rather than tearing it down and
        // re-binding on every re-dial (foreground/reconnect would otherwise drop live accepted
        // connections). Only build a fresh slot when there is none or the port changed.
        if state.node.client.endpoint.tcpServer?.interface.port != listenPort {
            state.node.client.endpoint.tcpServer = TCPServerEndpoint.State(port: listenPort)
        }
    } else {
        state.node.client.endpoint.tcpServer = nil
    }

    // A fresh connect attempt clears any stale Bluetooth alert (A5): the user may have resolved the
    // permission and is retrying. If the adapter is still unavailable, the library re-emits and the
    // alert re-appears; if it now works, the denial correctly disappears.
    state.bluetoothAlert = nil

    // Add or remove the BLE driver slot to match the current setting (A1). Same in-place, optional-
    // slot pattern as the listener: rebuilding only the OPTIONAL slot leaves the shared
    // transport/linkPlane untouched. PRESERVE an already-running slot rather than rebuilding it on
    // every re-dial — a fresh BLEEndpoint.State would reset `peerInterfaces` and drop every live
    // BLE peer on each foreground/reconnect. Build a slot only when there is none.
    if bleEnabled {
        if state.node.client.endpoint.ble == nil {
            // ble-reticulum v2.2 identifies this device to peers by its 16-byte identity hash —
            // the same identity the LXMF node was built with (`State.init`).
            state.node.client.endpoint.ble = BLEEndpoint.State(localIdentity: state.identity.hash)
        }
    } else {
        state.node.client.endpoint.ble = nil
    }
}

// Seed `reachablePeers` (the Send gate, "a send would route now") from learned destinations that
// are reachable RIGHT NOW:
// present in `destinations` AND whose interface is currently registered. `interfaces` is EMPTY
// whenever the socket is down (every interface deregisters), so this no-ops until an interface
// registers — the same reachability test `reachableLearned` uses (ReTiCA Transport.swift:159-163)
// and DiagnosticsSnapshot's pathsLayer uses. Idempotent (Set insert); safe to call from multiple
// sites. Read `interfaces` into a local FIRST so we are not reading and mutating `state` in the
// same access.
private func seedReachablePeers(_ state: inout AppFeature.State,
                                from destinations: [Data: LearnedDestination]) {
    let interfaces = state.node.client.endpoint.interfaces
    guard !interfaces.isEmpty else { return }
    for (hash, entry) in destinations where interfaces[entry.interfaceID] != nil {
        state.reachablePeers.insert(hash.hexString)
    }
}

// Reload helpers (file-scope free functions — no self capture in @Sendable effects).
private func reloadConversations(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let (all, attachments, groups) = try await database.read { db -> ([Message], [Attachment], [ChatGroup]) in
        let all = try Message.fetchAll(db)
        // Only a message with no text needs its attachment for the preview placeholder.
        let ids = all.filter { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        let groups = try ChatGroup.all.fetchAll(db)
        return (all, attachments, groups)
    }
    let byMessage = Attachment.byMessageId(attachments)
    let byGroup = Dictionary(uniqueKeysWithValues: groups.map { ($0.groupHex, $0) })
    await send(.conversationsLoaded(Conversation.list(from: all, attachments: byMessage, groups: byGroup)))
}

/// Loads one thread by its key: a peer's address or a group's id. Sends `groupLoaded` first (nil
/// group for a peer thread), then `threadLoaded`, then the conversation's timer.
private func reloadThread(_ database: any DatabaseWriter, _ key: String, _ send: Send<AppFeature.Action>) async throws {
    let loaded = try await database.read { db -> ([Message], [Reaction], [Attachment], Int?, ChatGroup?, [GroupMember], [GroupDelivery]) in
        // Amendment A13: a group thread is its rows, a peer thread is the rows with no group.
        let rows = try Message
            .where { $0.groupHex.eq(key) || ($0.groupHex.is(nil) && $0.peerHex.eq(key)) }
            .order(by: \.timestamp).fetchAll(db)
        let hashes = rows.map(\.messageHash).filter { !$0.isEmpty }
        let reactions = hashes.isEmpty ? [] : try Reaction.where { $0.messageHash.in(hashes) }.fetchAll(db)
        let ids = rows.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        let expiry = try ConversationSetting.expiry(for: key, db)
        let group = try ChatGroup.fetch(key, db)
        let members = group == nil ? [] : try GroupMember.where { $0.groupHex.eq(key) }.fetchAll(db)
        let outgoingIds = rows.filter(\.isOutgoing).map(\.id)
        let deliveries = (group == nil || outgoingIds.isEmpty) ? [] : try GroupDelivery.where { $0.messageId.in(outgoingIds) }.fetchAll(db)
        return (rows, reactions, attachments, expiry, group, members, deliveries)
    }
    await send(.groupLoaded(groupHex: key, group: loaded.4, members: loaded.5, deliveries: loaded.6))
    await send(.threadLoaded(loaded.0, reactions: loaded.1, attachments: loaded.2))
    await send(.conversationExpiryLoaded(peerHex: key, seconds: loaded.3))
}

/// First view (spec §3): every row of `peerHex` that carries a duration and has no `expiresAt`
/// yet is stamped `now + expirySeconds`. Outgoing rows are stamped at send, so in practice this
/// touches received rows. Returns how many rows changed, so the caller knows whether to reload.
private func stampViewed(_ database: any DatabaseWriter, _ peerHex: String, now: Date) async throws -> Int {
    try await database.write { db in
        let unstamped = try Message
            .where { $0.peerHex.eq(peerHex) && $0.expirySeconds.isNot(nil) && $0.expiresAt.is(nil) }
            .fetchAll(db)
        for row in unstamped {
            guard let seconds = row.expirySeconds else { continue }
            let due: Date? = now.addingTimeInterval(TimeInterval(seconds))
            try Message.where { $0.id.eq(row.id) }.update { $0.expiresAt = due }.execute(db)
        }
        return unstamped.count
    }
}

/// The timer a send should carry (amendment A16). `known` is `.some(value)` once the open thread's
/// setting has loaded (value nil = off) and nil before that, in which case the stored setting is
/// read so a send within milliseconds of opening a thread still carries the field.
private func resolveExpiry(_ known: Int??, peerHex: String, _ database: any DatabaseWriter) async throws -> Int? {
    if let known { return known }
    return try await database.read { try ConversationSetting.expiry(for: peerHex, $0) }
}

/// Purge what is due, then tell the reducer what is left so it can arm the sleeper (spec §3
/// "Purge"). Called on launch, foreground, thread open, after every stamp, after every send with a
/// timer, and when the sleeper fires. Decoded images of the purged attachments are evicted from
/// the app's cache on the way (amendment A17), so a deleted photo does not stay in memory.
private func purgeAndReschedule(_ database: any DatabaseWriter, _ attachmentStore: AttachmentStore,
                                _ evictor: AttachmentCacheEvictor,
                                now: Date, _ send: Send<AppFeature.Action>) async throws {
    let result = try await MessagePurge.run(database, attachmentStore: attachmentStore, now: now)
    if !result.purgedAttachmentIds.isEmpty {
        await evictor.evict(result.purgedAttachmentIds)
    }
    await send(.expiryPurgeCompleted(purged: result.purged, nextDue: result.nextDue))
}

/// Persist the full `learned` snapshot to `learnedDestinationRows`, replacing the table atomically.
///
/// Called by both the debounce path (`._flushLearnedDestinations`) and the immediate-flush path
/// (`.backgrounded`). Writing the entire current snapshot — not an incremental delta — is simpler
/// and correct: the table always reflects exactly what the in-memory state held at write time,
/// regardless of how many announces arrived between writes.
///
/// Write policy: this is the debounced write for learned destinations, NOT the per-event write
/// used for `LearnedPeerRow` and `SeenHashRow`. See `LearnedDestinationRow` for the ruling.
/// Short form: path updates are continuous on a meshed network; per-event writes here would mean
/// continuous disk traffic. The debounce caps that at one write per 30 s.
private func writeLearnedDestinations(_ learned: [Data: LearnedDestination],
                                      to database: any DatabaseWriter) async throws {
    let rows = learned.compactMap { hash, dest in LearnedDestinationRow(hash: hash, destination: dest) }
    try await database.write { db in
        // Full replace: delete all rows, then insert the current snapshot.
        try LearnedDestinationRow.all.delete().execute(db)
        for row in rows {
            try LearnedDestinationRow.insert { row }.execute(db)
        }
    }
}

/// Prune `seenHashRows` to `RingSet.capacity` (10 000), keeping the newest rows.
///
/// Must be called inside a write transaction after every insert. The in-memory `RingSet` evicts
/// the oldest hash at capacity, so pruning oldest-first keeps the DB consistent with the ring.
/// Without this prune, the table grows without bound while mirroring a bounded structure.
///
/// The SQL is `DELETE … WHERE hashHex IN (SELECT hashHex … ORDER BY storedAt ASC LIMIT max(0, count - 10000))`.
/// Structured-queries doesn't expose a `LIMIT` on DELETE directly, so we use a `WHERE … IN (SELECT …)`
/// shape, which is a standard GRDB / SQLite pattern.
private func pruneSeenHashes(_ db: GRDB.Database) throws {
    // RingSet capacity — must match LXMFRouter.State's `RingSet(capacity: 10_000)`.
    let capacity = 10_000
    try db.execute(sql: """
        DELETE FROM seenHashRows
        WHERE hashHex IN (
            SELECT hashHex FROM seenHashRows
            ORDER BY storedAt ASC
            LIMIT MAX(0, (SELECT COUNT(*) FROM seenHashRows) - \(capacity))
        )
        """)
}

/// Upsert a seen-hash row and prune to the ring capacity (shared by text and reaction receives).
private func recordSeenHash(_ hashHex: String, at now: Date, _ db: GRDB.Database) throws {
    try SeenHashRow.where { $0.hashHex.eq(hashHex) }.delete().execute(db)
    try SeenHashRow.insert { SeenHashRow(hashHex: hashHex, storedAt: now) }.execute(db)
    try pruneSeenHashes(db)
}
