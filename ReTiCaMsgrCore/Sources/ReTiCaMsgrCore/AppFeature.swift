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

/// The hub a node edit moved the push role off, whose `/unregister` is in flight over the socket
/// of `interfaceID` (backlog 2026-10-11 item 1). While set, every slot sync keeps that slot and
/// push is not re-pointed; `.pushRegistrationSettled` clears it and applies both.
public struct PendingUnregister: Equatable, Sendable {
    public var hub: Data
    public var interfaceID: InterfaceID

    public init(hub: Data, interfaceID: InterfaceID) {
        self.hub = hub
        self.interfaceID = interfaceID
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

    /// How long before iOS's background time runs out the app holds and closes on its own, so the
    /// close lands while the process still runs (amendment A4). iOS's own expiry is the backstop.
    public static let backgroundTimeMargin: TimeInterval = 5
    /// The early deadline when the time left is huge or infinite (as it reads in the foreground).
    public static let backgroundDeadlineCap: TimeInterval = 25

    /// The early deadline for `remaining` seconds of background time: the margin before it, at
    /// least zero, at most the cap.
    static func backgroundDeadline(remaining: TimeInterval) -> TimeInterval {
        guard remaining.isFinite else { return backgroundDeadlineCap }
        return min(max(0, remaining - backgroundTimeMargin), backgroundDeadlineCap)
    }

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
        /// A node edit moved the push role off a hub that is still reachable: its slot is kept and
        /// the push re-point waits until that hub's `/unregister` settles (backlog item 1).
        public var pendingUnregister: PendingUnregister? = nil
        /// Set by `.backgrounded`, consumed by the next `.foregrounded`: a listener that was alive
        /// across a suspension may have been cancelled by the system without the actor hearing it,
        /// so that foreground restarts the listener regardless of its reported status.
        public var suspendedSinceForeground = false
        /// The TCP nodes the app dials (spec 2026-10-10 §2), persisted as JSON. Empty only before
        /// the first launch's migration; afterwards it always holds the built-in entry.
        @Shared(.fileStorage(AppFeature.nodesFileURL)) public var nodes: [NodeEntry] = []
        /// Use the default node's propagation node while one is known (`\.defaultPropagationHex`);
        /// the stored `propagationNodeHex` is ignored meanwhile.
        @Shared(.appStorage("usePropagationDefault")) public var usePropagationDefault: Bool = true
        /// The pre-nodes dial target. Read ONLY by the one-time migration (amendment A6); the
        /// keys are never written again.
        @Shared(.appStorage("host")) var legacyHost: String = NodeMigration.legacyDefaultHost
        @Shared(.appStorage("port")) var legacyPort: Int = NodeMigration.legacyDefaultPort
        public var connection: Connection = .disconnected
        /// The set of currently-connected Transport interfaces (TCP client, each accepted server
        /// connection, each BLE peer). `connection` is derived from this: the app is `.connected`
        /// while ANY interface is up. Session-only — rebuilt from live `interfaceConnected` /
        /// `interfaceDisconnected` events, never persisted. Before this, the app collapsed every
        /// interface into one bool, so a single BLE peer dropping marked the whole app offline while
        /// TCP stayed healthy (punch-list A4).
        public var connectedInterfaces: Set<InterfaceID> = []
        /// When a radio going down last re-announced us over TCP (`radioDownAnnounceInterval`).
        var lastRadioDownAnnounceAt: Date? = nil
        /// Set when the BLE adapter is terminally unavailable (permission denied / no radio); drives
        /// the Settings permission surface (A5). Session-only — cleared on each connect attempt so a
        /// resolved denial doesn't stick, and re-set if the adapter is still unavailable.
        public var bluetoothAlert: BluetoothAlert? = nil
        /// The open conversation's composer text. Loaded from `drafts` on open and written back to
        /// it on every edit, so leaving the chat or the app keeps it.
        public var draft = ""
        /// Unsent composer text by conversation key, persisted as JSON. A send removes its entry.
        @Shared(.fileStorage(AppFeature.draftsFileURL)) public var drafts: [String: ConversationDraft] = [:]
        /// The conversation list as shown: `conversations` with each draft applied.
        public var conversationRows: [Conversation] { Conversation.applyingDrafts(conversations, drafts) }
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
        /// Hashes of sends handed to the node and not yet settled: inserted on `sendMessage`,
        /// removed by every terminal delegate (an unknown hash is a no-op). Session-only.
        public var inFlightSends: Set<Data> = []
        /// The background time held while sends finish after `.backgrounded` (amendment A4), nil
        /// when none is held. Ended when the last send settles, the time runs out, or on foreground.
        public var backgroundTaskID: Int? = nil
        /// Whether ReTiCA's outbound retries are held (amendment A3): set when the background time
        /// ran out, released on foreground or the next `interfaceConnected`. Session-only.
        public var outboundHeld = false
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
        /// Blocked senders (spec 2026-10-15 §2): lowercase lxmf.delivery hashes, mirrored from the
        /// `blockedPeers` table on launch and on every change. The node's ignore list and the
        /// extension's app-group list are both derived from this.
        public var blockedPeers: Set<String> = []
        /// The same rows with their dates, newest first, for the Settings list.
        public var blockedPeerRows: [BlockedPeer] = []
        /// A report waiting for the mail composer; nil when none is showing.
        public var reportDraft: ReportDraft? = nil

        public func isBlocked(_ hex: String) -> Bool { blockedPeers.contains(hex.lowercased()) }

        /// Opening a conversation: its saved draft goes back into the composer.
        mutating func loadDraft(_ key: String) {
            draft = drafts[key]?.text ?? ""
        }

        /// Writes the composer text to the open conversation's draft; empty text removes it.
        mutating func saveDraft(now: Date) {
            guard let key = openPeerHex else { return }
            let text = draft
            let isGroup = openConversationKind == .group
            $drafts.withLock {
                $0[key] = text.isEmpty ? nil : ConversationDraft(text: text, updatedAt: now, isGroup: isGroup)
            }
        }
        // Announce-row tap outcomes, keyed by the peer's delivery-destination hash hex. Session-only.
        public var publicKeyRequests: [String: PublicKeyRequestStatus] = [:]
        @Shared(.appStorage("propagationNodeHex")) public var propagationNodeHex: String = ""
        @Shared(.appStorage("propagationNodeModeEnabled")) public var nodeModeEnabled: Bool = false
        @Shared(.appStorage("displayName")) public var displayName: String = ""
        /// 16-char hex version of my profile photo; "" means none (spec 2026-10-19).
        @Shared(.appStorage("profilePhotoVersion")) public var myPhotoVersion: String = ""
        public var profilePhotoError: String? = nil
        /// Peers' stored profiles by lowercase hex, mirrored from the `peerProfiles` table.
        public var peerProfiles: [String: PeerProfile] = [:]
        /// The photo may be attached only when a non-Meshtastic interface is connected (the slow
        /// radio path would take minutes for it).
        public var profilePhotoMayRide: Bool {
            connectedInterfaces.contains { !$0.rawValue.hasPrefix("meshtastic:") }
        }
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
        /// `syncEndpointNodes` (like `listenEnabled`), so toggling takes effect on the next
        /// Connect. The live FCB/CoreBluetooth driver is auto-wired via `\.bleDriver` — nothing to
        /// inject.
        @Shared(.appStorage("bleEnabled")) public var bleEnabled: Bool = false
        /// Opt-in: also reach Reticulum through a Meshtastic radio paired over Bluetooth (spec
        /// 2026-10-16 §7). OFF by default. Like `bleEnabled`, it is read at connect time, and the
        /// endpoint slot itself is wired by lane E (`syncEndpointNodes`): this build stores the
        /// choice and shows it in Settings and Diagnostics.
        @Shared(.appStorage("meshtasticEnabled")) public var meshtasticEnabled: Bool = false
        /// The chosen radio's CoreBluetooth peripheral UUID as a string, nil when none is chosen.
        /// Read it through `meshtasticRadioUUID`, which treats a non-UUID string as no radio.
        @Shared(.appStorage("meshtasticRadioID")) public var meshtasticRadioID: String? = nil
        /// The chosen radio's advertised name when it was picked, for the Settings row only.
        /// Unauthenticated text from the air: never put it in a diagnostics reason.
        @Shared(.appStorage("meshtasticRadioName")) public var meshtasticRadioName: String? = nil
        /// The radio picker sheet (spec 2026-10-16 §7), nil when closed. Closed ONLY through
        /// `.radioPicker(.dismiss)` (swipe, Cancel, or a pick), which is where paused BLE resumes:
        /// never set this to nil directly.
        @Presents public var radioPicker: RadioPickerFeature.State?
        /// BLE should be (re)started when the picker closes: set when the picker stopped a running
        /// BLE interface so its scan owns FCB's one scan (spec §2), and when `redialDownNodes`
        /// (foreground, push wake) wanted to start BLE while the picker was open and deferred it.
        /// `.radioPicker(.dismiss)` performs that start and clears this. Session-only.
        public var blePausedForRadioScan = false
        /// `bleEnabled` went off while the BLE slot was running: the slot was sent `.stop` and is
        /// dropped once its interface is idle (`BLESlotReducer`). Cleared when the setting comes
        /// back on before then, which keeps the slot. Session-only.
        public var bleSlotRemovalPending = false
        /// The radio's state for Diagnostics, from the Meshtastic endpoint's delegates and counters (MeshtasticRadioReducer). Session-only.
        public var meshtasticStatus = MeshtasticStatus()
        /// A radio slot replacement in flight (spec Contract 3): the old slot was sent `.stop` and is
        /// dropped at its `.radioOffline`. Session-only.
        public var meshtasticSwap: MeshtasticSlotSwap? = nil
        /// Counters of radio slots already replaced, so Diagnostics stays cumulative since launch
        /// (`MeshtasticStatus.Counters`) across a radio change. Session-only.
        public var meshtasticRetiredCounters = MeshtasticStatus.Counters()

        /// Contact links by peer address (spec 2026-10-11 §4), loaded at launch and after every
        /// link write. The one source for "what do we call this peer" when a link exists.
        public var contactLinks: [String: ContactLink] = [:]
        /// What Contacts last reported. Session-only; drives the denied explanation.
        public var contactsAuthorization: ContactsAuthorization = .notDetermined
        /// Non-nil while the system contact picker should be up (presented at the root).
        public var linkPickerTarget: LinkPickerTarget? = nil
        /// A pick that collides with an existing link, awaiting Replace or Cancel.
        public var pendingLinkCollision: LinkCollision? = nil
        /// A link was asked for with Contacts access denied: the root alert explains it and
        /// offers Settings, whichever entry point the tap came from (backlog 2026-10-11 item 2).
        public var showingContactsDenied = false
        /// Peers whose row asks for verification (spec §3 "Confirmation prompt"): derived from the
        /// rows, never stored, so a prompt — and a "Not now" — survives a relaunch.
        public var pendingVerifyPrompts: Set<String> {
            Set(contactLinks.values.filter(\.needsVerifyPrompt).map(\.peerHex))
        }
        /// Spec §3 "Contact-card mirror": write `reticulum:<peerHex>` into linked cards (full
        /// access only) and import such URLs found on cards.
        @Shared(.appStorage("contactMirrorEnabled")) public var contactMirrorEnabled: Bool = false
        /// `reticulum:` URLs found on cards and not yet linked, offered for import.
        public var importCandidates: [ImportCandidate] = []
        /// What Contacts reports for each linked card, keyed by `contactIdentifier` so a changed
        /// link never shows the previous contact's photo (backlog 2026-10-11 items 6, 10).
        public var contactCards: [String: ContactCard] = [:]

        public init(identity: Identity,
                    pushStorage: PushStorage = .temporary(),
                    bundleID: String = Bundle.main.bundleIdentifier ?? "",
                    pushEnvironment: PushEnvironment = AppFeature.defaultPushEnvironment) {
            self.identity = identity
            self.myAddressHex = lxmfAddressHex(identity)
            // No TCP client yet: `syncEndpointNodes` builds one slot per enabled node entry at
            // launch and connect (amendment A8). Use the LXMF library default stamp cost — one
            // constant that is both advertised in the node announce and enforced on inbound offers.
            self.node = LXMFServiceNode.State(
                identity: identity,
                endpoint: TransportEndpoint.State(),
                minStampCost: LXMFPropagation.defaultPropagationStampCost
            )
            self.push = PushFeature.State(
                identity: identity, bundleID: bundleID, environment: pushEnvironment, storage: pushStorage,
                keychainService: SharedIdentityLocation.service,
                keychainAccessGroup: SharedIdentityLocation.accessGroup)
        }

        /// The push node (spec §2): the enabled entry that carries a push hex.
        public var pushNode: NodeEntry? { NodeRules.pushNode(in: nodes) }

        public var enabledNodes: [NodeEntry] { nodes.filter(\.enabled) }

        /// The push status line for Settings: while a registration waits for the push node's socket
        /// (`pendingPushRegistration`), say so instead of an open-ended "Registering…" (backlog item 6).
        public var pushStatusText: String {
            if pendingPushRegistration != nil, push.status == .registering, let node = pushNode {
                return "Waiting for \(node.name)…"
            }
            return push.status.displayText
        }

        /// The propagation node to use: the default's while one exists and the toggle is on, else
        /// the stored hex ("" when none). Read through the dependency so tests can supply a default.
        public var effectivePropagationNodeHex: String {
            @Dependency(\.defaultPropagationHex) var defaultHex
            if usePropagationDefault, let defaultHex { return defaultHex }
            return propagationNodeHex
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

        /// The open peer's display name (spec 2026-10-11 §4): the linked contact's name wins,
        /// else the display name from its LXMF delivery announce (`learnedPeers`, the table the
        /// Announces list shows), trimmed. nil when no conversation is open, there is no link and
        /// no announce was heard, or the name is blank, so labels fall back to "Them" rather than "".
        public var openPeerDisplayName: String? {
            openPeerHex.flatMap(peerDisplayName)
        }

        /// What we call `hex`: the linked contact's name when a link exists (spec 2026-10-11 §4),
        /// else the display name from its LXMF delivery announce, trimmed; nil when neither, so
        /// labels fall back to "Them".
        public func peerDisplayName(_ hex: String) -> String? {
            contactName(hex) ?? peerAnnounceName(hex)
        }

        /// The linked contact's cached name, or nil when the peer is not linked or the cached
        /// name is empty (an unnamed card must not blank out a title that already has one).
        public func contactName(_ hex: String) -> String? {
            guard let name = contactLinks[hex]?.cachedName, !name.isEmpty else { return nil }
            return name
        }

        /// The display name from `hex`'s LXMF delivery announce only (`learnedPeers`), trimmed;
        /// nil when no announce was heard or the name is blank.
        public func peerAnnounceName(_ hex: String) -> String? {
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

        /// A member's name for a line: "You", the linked contact's name, else the announce
        /// display name, else a short hex.
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
        /// iOS answered the background-time request `.backgrounded` made for sends in flight: the
        /// task's id, or nil when none was granted. Internal.
        case backgroundTaskBegan(Int?)
        /// That background time ran out with sends still in flight. Internal.
        case backgroundTimeExpired
        /// A background push woke the process (AppDelegate). Re-dials like `foregrounded`, then
        /// drains the push inbox.
        case pushWake
        /// A propagated push arrived while the app is in front (AppDelegate `willPresent`): the hub
        /// says mail is waiting at a propagation node. Syncs from the configured node (A1).
        case propagatedPush
        /// APNs issued or refreshed the device token (AppDelegate).
        case pushDeviceToken(Data)
        case pushDeviceTokenFailed(String)
        /// The 20 s registration timer fired. Internal.
        case pushRegistrationTimedOut
        /// `/unregister` from `hub` over its (still open) link; the registration reducer runs it
        /// (backlog 2026-10-11 item 1: a push-node switch leaves the old hub cleanly).
        case unregisterFromHub(Data)
        /// The registration flow finished (any result but a superseded attempt's cancellation).
        case pushRegistrationSettled
        case push(PushFeature.Action)
        case connectTapped
        case disconnectTapped
        case openConversation(String)
        /// A tap on a group row: opens it as a group thread.
        case openGroupConversation(String)
        /// "Create group" (spec §3): `name` is trimmed, `members` are the other members' addresses
        /// (me and invalid entries are dropped). Opens the new group's thread.
        case createGroup(name: String, members: [String])
        /// Creator only, on the open group (spec §3): each bumps the revision, writes its line and
        /// fans the new roster to every member.
        case addGroupMembers([String])
        case removeGroupMember(String)
        case renameGroup(String)
        case deleteGroup
        /// Member only: sends the leave to every member and marks the group left.
        case leaveGroup
        case acceptInvite
        /// Marks the invite left and sends the leave to the creator only (amendment A6).
        case declineInvite
        /// A roster was re-issued inside a receive (a member left a group I created): send the
        /// waiting copies to the reachable members. Internal.
        case groupRosterChanged(groupHex: String)
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
        /// Node list edits (spec 2026-10-10 §3 "Node actions"). Each validates, writes the list,
        /// keeps one push node, re-syncs the endpoint and re-points push. The built-in entry
        /// accepts only `setNodeEnabled`.
        case addNode(name: String, host: String, port: Int, pushHubHex: String?)
        case updateNode(NodeEntry)
        case removeNode(id: UUID)
        case setNodeEnabled(id: UUID, enabled: Bool)
        /// "Use the default node's propagation node". Takes effect only while a default exists.
        case setUsePropagationDefault(Bool)
        /// Contact links (spec 2026-10-11 §5).
        case linkContactTapped(peerHex: String, source: String)
        case contactsAccessResolved(ContactsAuthorization, peerHex: String, source: String)
        case linkPickerDismissed
        case dismissContactsDenied
        case contactPicked(peerHex: String, identifier: String, name: String, source: String)
        case replaceLinkConfirmed
        case cancelLinkCollision
        case unlinkContact(peerHex: String)
        case markContactVerified(peerHex: String)
        /// A later exchange returned the same identity for this contact; the app asks the user
        /// whether to mark the link verified. Sent by the exchange (a later feature).
        case confirmationReceived(peerHex: String, confirmation: ContactConfirmation)
        case dismissVerifyPrompt(peerHex: String)
        /// A later exchange returned a different identity for this contact. Ignored when the
        /// reported contact no longer matches the link (the link changed since).
        case conflictReported(peerHex: String, contactIdentifier: String, otherPeerHex: String, at: Date)
        case resolveConflict(peerHex: String)
        case contactNameRefreshed(peerHex: String, name: String)
        /// A contact row came on screen: load the live name (refreshing the cache) and the photo.
        case contactRowAppeared(peerHex: String)
        case contactCardLoaded(contactIdentifier: String, ContactCard)
        case contactLinksLoaded([ContactLink])
        case setContactMirror(Bool)
        /// A sheet that shows Contacts state opened (the info sheets, Settings): refresh the
        /// access status and, with the mirror on, scan the cards for importable addresses.
        case contactLinkSheetAppeared
        case importCandidatesFound([ImportCandidate])
        case importContactLinks
        // Blocking (spec 2026-10-15 §2, §3), handled in `BlockingReducer`.
        case blockPeer(String)
        case unblockPeer(String)
        case blockedPeersLoaded([BlockedPeer])
        case reportPeer(String)
        case reportDraftReady(ReportDraft)
        case reportDismissed
        // Profile photos (spec 2026-10-19), handled in `ProfilePhotoReducer`.
        case profilePhotoPicked(Data)
        case profilePhotoSaved(version: String)
        case profilePhotoFailed
        case removeProfilePhotoTapped
        /// Launch found no `me.jpg` matching this stored version (a backup restore).
        case myPhotoFileMissing(version: String)
        case peerProfilesLoaded([PeerProfile])
        case peerProfileUpdated(peerHex: String, PeerProfile?)
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
        /// "Choose radio…" in Settings (spec 2026-10-16 §7): opens the radio picker and pauses a
        /// running BLE interface. Handled in `MeshtasticSettingsReducer`.
        case chooseRadioTapped
        case radioPicker(PresentationAction<RadioPickerFeature.Action>)
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
        /// The background-time request and its wait for expiry. Cancelled when the task is ended.
        case backgroundTask
        /// The early deadline before the background time runs out. Cancelled when the task is ended.
        case backgroundDeadline
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    @Dependency(\.contactsClient) var contactsClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.attachmentStore) var attachmentStore
    @Dependency(\.attachmentCacheEvictor) var attachmentCacheEvictor
    @Dependency(\.avatarStore) var avatarStore
    @Dependency(\.backgroundTask) var backgroundTask

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

    /// Where pushed packets are injected when the push node has no slot.
    static let pushFallbackInterface = InterfaceID("push")

    /// Where the node list lives: `<Application Support>/nodes.json`.
    public static let nodesFileURL = URL.applicationSupportDirectory.appending(path: "nodes.json")
    public static let draftsFileURL = URL.applicationSupportDirectory.appending(path: "drafts.json")
    /// The shortest gap between two radio-down re-announces over TCP.
    static let radioDownAnnounceInterval: TimeInterval = 10 * 60

    /// Where to re-announce when `departing` goes down: every connected TCP client and server
    /// interface, but only when `departing` is a radio and the last such announce is at least
    /// `radioDownAnnounceInterval` old. Sorted, so the announces go out in a stable order.
    static func radioDownAnnounceTargets(departing: InterfaceID, connected: Set<InterfaceID>,
                                         lastAnnounceAt: Date?, now: Date) -> [InterfaceID] {
        guard departing.rawValue.hasPrefix("meshtastic:") else { return [] }
        if let lastAnnounceAt, now.timeIntervalSince(lastAnnounceAt) < radioDownAnnounceInterval { return [] }
        return connected
            .filter { $0.rawValue.hasPrefix("tcp:") || $0.rawValue.hasPrefix("tcpserver:") }
            .sorted { $0.rawValue < $1.rawValue }
    }

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
                migrateNodesIfNeeded(&state, makeID: { uuid() })
                // Amendment A13 at launch too (backlog item 19): a list persisted with no push hex
                // at all (an earlier dev build) regains the default now, not on the next edit.
                state.$nodes.withLock { $0 = NodeRules.restoringDefaultPushHex($0) }
                // Amendment A10 (final-review M1): only show "Connecting…" when something will
                // actually dial — an empty/all-disabled node list with the listener and BLE both
                // off would otherwise leave the UI stuck on "Connecting…" forever.
                if state.somethingWillDial {
                    state.connection = .connecting
                }
                let sync = syncEndpointNodes(&state)
                return .concatenate(
                    // Spec 2026-10-15 A5: the node must know the blocklist before it starts and
                    // before the push inbox drains. `reloadBlockedPeers` sends the node action itself.
                    .run { [database] send in
                        try await reloadBlockedPeers(database, send)
                    } catch: { error, _ in
                        AppFeature.inbound.error("blocked peers failed to load, node starts with an empty ignore list: \(String(describing: error), privacy: .public)")
                    },
                    .merge(
                    // Removals first (`.concatenate`): a departing slot must be gone before
                    // `.start` could dial it.
                    .concatenate(sync.removals, sync.meshtastic, .send(.node(.client(.endpoint(.start))))),
                    pushSyncEffects(state),
                    .send(.push(.appLaunched)),
                    .run { [database] send in try await reloadConversations(database, send) },
                    .run { [database] send in try await reloadContactLinks(database, send) },
                    // Final review 1 and 5: reconcile profile-photo state with what survived the
                    // last run (a kill, a backup restore) before state gets the rows.
                    .run { [database, avatarStore, myVersion = state.myPhotoVersion, now = date.now] send in
                        try await reconcileProfilePhotosAtLaunch(database, avatarStore, myVersion: myVersion,
                                                                 now: now, send)
                        try await reloadPeerProfiles(database, send)
                    },
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
                ))

            case .foregrounded:
                // Only re-dial when the TCP socket specifically is down. iOS tears the TCP socket
                // down while suspended, so foreground is when we rebuild it — but a live BLE peer
                // must NOT suppress that: keying on the whole-app `.connected` bool would skip the
                // re-dial whenever any BLE peer held the app "connected", leaving the dead socket
                // unrebuilt (A4). `redialDownNodes` does this per node: a live node's interface is
                // left alone (re-dialling it would tear down its live links on every app switch),
                // every down node is dialed again, and `connection` goes to `.connecting` only when
                // nothing is up AND something will actually dial (amendment A10).
                // Either way, drain the push inbox: packets may have been stashed while suspended.
                // Disappearing messages: the open thread is being looked at again (first view for
                // rows that arrived while suspended), and rows that fell due meanwhile go now.
                state.isForeground = true
                let resumed = state.suspendedSinceForeground
                state.suspendedSinceForeground = false
                let expiryCatchUp = viewOpenThreadEffect(state)
                // Background time is no longer needed, and a hold must not outlive the background
                // (amendment A3): opened with no connectivity, it would stop every send from ever
                // failing or falling back.
                let release: Effect<Action> = state.outboundHeld ? .send(.node(.client(.holdOutbound(false)))) : .none
                state.outboundHeld = false
                // A redial's `interfaceConnected` already syncs from the propagation node; only a
                // foreground that dials nothing needs to ask.
                let sync = tcpDownIDs(state).isEmpty ? propagationSyncEffect(state) : .none
                return .merge(redialDownNodes(&state, restartListener: resumed), .send(.push(.drainInbox)), expiryCatchUp,
                              endBackgroundTask(&state), release, sync)

            case .pushWake:
                return .merge(redialDownNodes(&state, restartListener: false), .send(.push(.drainInbox)))

            case .propagatedPush:
                return propagationSyncEffect(state)

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
                // Inject on the push node's interface when its slot exists (the hub proved the
                // packet over that socket), else the fallback id.
                let pushID = state.pushNode?.interfaceID
                let interfaceID = pushID.flatMap { state.node.client.endpoint.tcpClients[id: $0] != nil ? $0 : nil }
                    ?? AppFeature.pushFallbackInterface
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
                // The next foreground restarts the listener (see `suspendedSinceForeground`).
                state.suspendedSinceForeground = true
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
                // Only the TCP clients: BLE peers keep running in the background on their own terms.
                // Amendment A4: with sends in flight, ask for background time instead and close when
                // they settle, the time nearly runs out, or none is granted (`backgroundTaskBegan(nil)`).
                // The effect stays alive until the time runs out, so `onExpire` sends through a live
                // effect; ending the task cancels it.
                let closeOrFinishSending: Effect<Action> = state.inFlightSends.isEmpty
                    ? closeHubSockets(state)
                    : .run { [backgroundTask] send in
                        let (expired, expire) = AsyncStream.makeStream(of: Void.self)
                        let id = await backgroundTask.begin { expire.yield() }
                        await send(.backgroundTaskBegan(id))
                        guard id != nil else { return }
                        for await _ in expired {
                            await send(.backgroundTimeExpired)
                            return
                        }
                    }
                    .cancellable(id: CancelID.backgroundTask)
                return .merge(
                    .cancel(id: CancelID.learnedDebounce),
                    closeOrFinishSending,
                    .run { [database] _ in
                        try await writeLearnedDestinations(learnedToFlush, to: database)
                    },
                    // File storage writes a second after the last edit; write the drafts now, in
                    // case the process is suspended and killed before that second passes.
                    .run { [drafts = state.$drafts] _ in try await drafts.save() }
                )

            case let .backgroundTaskBegan(id):
                // A grant replacing one still held gives the old one back. Only its `end`: the
                // begin effect that sent this one shares the cancel ID and must keep running.
                var replaced: Effect<Action> = .none
                if let held = state.backgroundTaskID, held != id {
                    replaced = .run { [backgroundTask] _ in await backgroundTask.end(held) }
                }
                state.backgroundTaskID = id
                // Foregrounded before iOS answered: the time is not needed and the sockets stay open.
                if state.isForeground { return .merge(replaced, endBackgroundTask(&state)) }
                // None granted, or the last send settled while asking: close now, as with nothing
                // in flight.
                guard id != nil, !state.inFlightSends.isEmpty else {
                    let close = closeHubSockets(state)
                    return .merge(replaced, close, endBackgroundTask(&state))
                }
                // Hold and close early, while the process certainly still runs: by the time iOS's
                // expiry handler has ended the task, a close sent from the reducer usually lands
                // after suspension, leaving the hub writing into a socket nobody reads.
                return .merge(replaced, .run { [backgroundTask, clock] send in
                    let deadline = AppFeature.backgroundDeadline(remaining: await backgroundTask.remaining())
                    try await clock.sleep(for: .seconds(deadline))
                    await send(.backgroundTimeExpired)
                }
                .cancellable(id: CancelID.backgroundDeadline, cancelInFlight: true))

            case .backgroundTimeExpired:
                // Sent by the early deadline and, as a backstop, by iOS's expiry: whichever comes
                // second finds no task held.
                guard state.backgroundTaskID != nil else { return .none }
                // Hold FIRST: ReTiCA's hold protects an attempt only if it is already on when the
                // link-closed events of the closing sockets reach the router (`holdOutbound` doc).
                state.outboundHeld = true
                let close = closeHubSockets(state)
                return .concatenate(.send(.node(.client(.holdOutbound(true)))), close, endBackgroundTask(&state))

            case ._flushLearnedDestinations:
                // Debounce timer fired: write the current learned table. The table may have grown
                // since the timer was armed; we always write the latest snapshot, so rapid
                // announces are coalesced into one write per 30 s window.
                let learnedToWrite = state.node.client.endpoint.learned
                return .run { [database] _ in
                    try await writeLearnedDestinations(learnedToWrite, to: database)
                }

            case .connectTapped:
                // Never while the radio picker is open (spec 2026-10-16 §7 lane E): `.endpoint(.start)`
                // would restart a BLE interface the picker paused and take FCB's one scan from it.
                // The Connect button sits behind the sheet; the tap is dropped, not deferred.
                guard state.radioPicker == nil else { return .none }
                // Amendment A10 (final-review M1): only show "Connecting…" when something will
                // actually dial.
                if state.somethingWillDial {
                    state.connection = .connecting
                }
                let sync = syncEndpointNodes(&state)
                return .merge(
                    .concatenate(sync.removals, sync.meshtastic, .send(.node(.client(.endpoint(.start))))),
                    heldPushSyncEffects(state)
                )

            case .disconnectTapped:
                state.connection = .disconnected
                // A radio swap that finishes after this leaves the new radio stopped.
                state.meshtasticSwap?.startNext = false
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
                let alreadyRegistered = state.node.client.deliveryDestinationHash != nil
                var effects: [Effect<Action>] = [
                    .send(.node(.client(.setDisplayName(launchName.isEmpty ? nil : launchName, stampCost: nil)))),
                    // Contract 4 (spec 2026-10-16): only the FIRST interface registers the delivery
                    // destination, which announces on whatever is up then. Every later interface-up
                    // re-announces on THAT interface only, so a radio coming up never re-broadcasts
                    // on every other interface and a TCP reconnect never puts an announce on the radio.
                    alreadyRegistered
                        ? .send(.node(.client(.announceDeliveryOnInterface(interfaceID))))
                        : .send(.node(.client(.registerDelivery))),
                    // C1: Transport records a packet hash before it looks for a local destination,
                    // so any packet the inject arm had to stash (no delivery destination yet) must
                    // be re-drained now that a delivery destination exists (registered on the first
                    // interface-up, re-announced on later ones). Idempotent —
                    // the inbox is usually already empty.
                    .send(.push(.drainInbox)),
                    // Answer peers' /publicKey requests (the app's requestResponder dependency
                    // supplies the key). Idempotent — re-registering on reconnect is harmless.
                    .send(.node(.client(.endpoint(
                        .registerRequestHandler(path: AppFeature.publicKeyRequestPath, policy: .all))))),
                ]
                // Amendment A3: an interface is back, so held retries resume from where they stood.
                if state.outboundHeld {
                    state.outboundHeld = false
                    effects.append(.send(.node(.client(.holdOutbound(false)))))
                }
                // Group copies waiting on members whose persisted path just became usable.
                effects.append(groupDispatchEffect(state, members: state.reachablePeers))
                // I1: a registration the push feature asked for before the hub socket was up is
                // resumed now — only for the push node's interface (the hub sits behind it), and
                // only after registerDelivery/the announce above, so the hub sees the registration
                // once this device is actually reachable.
                if interfaceID == state.pushNode?.interfaceID,
                   let pending = state.pendingPushRegistration {
                    state.pendingPushRegistration = nil
                    effects.append(.send(.push(.delegate(.sendRegistration(
                        hub: pending.hub, path: pending.path, data: pending.data)))))
                }
                if let pn = Data(hexString: state.effectivePropagationNodeHex), pn.count == 16 {
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
                // A radio going away re-announces us on every TCP interface still up. Peers that
                // heard our radio-up announce route to us over the radio; a newer announce over TCP
                // moves them off it now, instead of after a failed send. TCP and BLE departures
                // announce nothing: a TCP blip comes back and re-announces on its own interface-up,
                // and BLE sessions come and go per peer. Throttled, so a radio flapping at the edge
                // of range does not trip a hub's announce rate limit.
                let now = date.now
                guard state.node.client.deliveryDestinationHash != nil else { return .none }
                let targets = AppFeature.radioDownAnnounceTargets(departing: interfaceID,
                                                                  connected: state.connectedInterfaces,
                                                                  lastAnnounceAt: state.lastRadioDownAnnounceAt,
                                                                  now: now)
                guard !targets.isEmpty else { return .none }
                state.lastRadioDownAnnounceAt = now
                return .merge(targets.map { .send(.node(.client(.announceDeliveryOnInterface($0)))) })

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
                state.loadDraft(peerHex)
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
                state.loadDraft(groupHex)
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
                // Spec §3: the paths are asked for once per open, not on every reload (final review I1).
                let firstLoad = state.openGroup == nil
                state.openGroup = group
                state.openGroupMembers = members.sorted { $0.memberHex < $1.memberHex }
                state.deliveriesByMessageId = GroupDelivery.byMessageId(deliveries)
                guard group != nil, firstLoad else { return .none }
                // Spec §3: a group thread asks for the paths of the members it cannot reach, so
                // the Send gate unlocks when they answer (the one-to-one open does the same).
                return .merge(state.openGroupOthers.map { state.pathRequestIfUnreachable($0) })

            case let .createGroup(name, members):
                let trimmedName = GroupWire.trimName(name)
                let me = state.myAddressHex
                let others = Set(members.map { $0.lowercased() }.filter { isValidPeerAddress($0) && $0 != me })
                guard !trimmedName.isEmpty, !others.isEmpty, others.count + 1 <= GroupWire.maxMembers else { return .none }
                let groupHex = GroupWire.randomId().hexString
                let now = date.now
                let group = ChatGroup(groupHex: groupHex, name: trimmedName, creatorHex: me, revision: 1,
                                      state: GroupState.active, updatedAt: now)
                let roster = others.union([me]).sorted()
                let line = Self.groupEventRow(groupHex: groupHex, me: me, body: GroupEventText.created(name: trimmedName),
                                              control: GroupControl.roster, now: now)
                let deliveries = others.sorted().map { GroupDelivery.waiting(messageId: line.id, memberHex: $0) }
                // Open the new group as `startConversation` opens a peer.
                state.openPeerHex = groupHex
                state.loadDraft(groupHex)
                state.openConversationKind = .group
                state.chatVisible = true
                state.openGroup = group
                state.openGroupMembers = roster.map { GroupMember(groupHex: groupHex, memberHex: $0) }
                state.deliveriesByMessageId = [:]
                state.openConversationExpiryLoaded = false
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                let reachable = others.intersection(state.reachablePeers)
                let identity = state.identity
                let myName = state.myName
                let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
                // Spec §3: members with no path get a request now; their copies wait.
                let pathRequests = others.subtracting(reachable).map { state.pathRequestIfUnreachable($0) }
                let myVersion = state.myPhotoVersion
                let imageAllowed = state.profilePhotoMayRide
                let avatarStore = self.avatarStore
                let write: Effect<Action> = .run { [database] send in
                    try await database.write { db in
                        try ChatGroup.upsert(group, db)
                        try GroupMember.replace(groupHex, with: roster, db)
                        try Message.insert { line }.execute(db)
                        for delivery in deliveries { try GroupDelivery.insert { delivery }.execute(db) }
                        try GroupDelivery.refreshDerivedStatus(messageId: line.id, db)
                    }
                    _ = try await dispatchWaitingGroupCopies(database, members: reachable, identity: identity,
                                                             myName: myName, fallbackToPropagation: fallbackToPropagation,
                                                             now: now, myVersion: myVersion,
                                                             myPhoto: myVersion.isEmpty ? nil : avatarStore.mine(),
                                                             imageAllowed: imageAllowed, send)
                    try await reloadThread(database, groupHex, send)
                    try await reloadConversations(database, send)
                }
                return .merge(pathRequests + [.cancel(id: CancelID.attachmentPreparation), write])

            case let .addGroupMembers(hexes):
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active else { return .none }
                let current = Set(state.openGroupMembers.map(\.memberHex))
                let added = Set(hexes.map { $0.lowercased() }.filter { isValidPeerAddress($0) }).subtracting(current)
                guard !added.isEmpty, current.count + added.count <= GroupWire.maxMembers else { return .none }
                let who: String = added.sorted().map { state.groupMemberName($0) }.joined(separator: ", ")
                let groupHex = group.groupHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.added(by: GroupEventText.you, who: who),
                                   control: GroupControl.roster,
                                   recipients: current.union(added).subtracting([state.myAddressHex])) { group, db in
                    group.revision += 1
                    let members = try GroupMember.members(of: groupHex, db)
                    try GroupMember.replace(groupHex, with: members + Array(added), db)
                }

            case let .removeGroupMember(hex):
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active,
                      hex != state.myAddressHex, state.openGroupMembers.contains(where: { $0.memberHex == hex })
                else { return .none }
                let groupHex = group.groupHex
                return groupChange(state, groupHex: groupHex,
                                   line: GroupEventText.removed(by: GroupEventText.you, who: state.groupMemberName(hex)),
                                   control: GroupControl.roster, recipients: Set(state.openGroupOthers)) { group, db in
                    group.revision += 1
                    try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(hex) }.delete().execute(db)
                }

            case let .renameGroup(name):
                let trimmed = GroupWire.trimName(name)
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active,
                      !trimmed.isEmpty, trimmed != group.name
                else { return .none }
                return groupChange(state, groupHex: group.groupHex,
                                   line: GroupEventText.renamed(by: GroupEventText.you, to: trimmed),
                                   control: GroupControl.roster, recipients: Set(state.openGroupOthers)) { group, _ in
                    group.revision += 1
                    group.name = trimmed
                }

            case .deleteGroup:
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active else { return .none }
                let groupHex = group.groupHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.deleted(by: GroupEventText.you),
                                   control: GroupControl.roster, recipients: Set(state.openGroupOthers)) { group, db in
                    group.revision += 1
                    group.state = GroupState.dissolved
                    try GroupMember.replace(groupHex, with: [], db)
                }

            case .leaveGroup:
                // An invited group is declined, not left.
                guard let group = state.openGroup, !state.isOpenGroupCreator, group.state == GroupState.active else { return .none }
                let groupHex = group.groupHex
                let me = state.myAddressHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.left(who: GroupEventText.you),
                                   control: GroupControl.leave, recipients: Set(state.openGroupOthers)) { group, db in
                    group.state = GroupState.left
                    try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(me) }.delete().execute(db)
                }

            case .acceptInvite:
                guard let group = state.openGroup, group.state == GroupState.invited else { return .none }
                let groupHex = group.groupHex
                let now = date.now
                return .run { [database] send in
                    try await database.write { db in
                        guard var stored = try ChatGroup.fetch(groupHex, db) else { return }
                        stored.state = GroupState.active
                        stored.updatedAt = now
                        try ChatGroup.upsert(stored, db)
                    }
                    try await reloadThread(database, groupHex, send)
                    try await reloadConversations(database, send)
                }

            case .declineInvite:
                guard let group = state.openGroup, group.state == GroupState.invited else { return .none }
                let groupHex = group.groupHex
                let me = state.myAddressHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.declined(),
                                   control: GroupControl.leave, recipients: [group.creatorHex]) { group, db in
                    group.state = GroupState.left
                    try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(me) }.delete().execute(db)
                }

            case let .groupRosterChanged(groupHex):
                // The waiting rows were written inside the receive; the unreachable members get
                // their copy when their path is learned (Task 5's hook). Only this group's rows go.
                return groupDispatchEffect(state, members: state.reachablePeers, groupHex: groupHex)

            case let .startConversation(hex):
                guard let data = Data(hexString: hex), data.count == 16 else { return .none }
                state.openPeerHex = hex
                state.loadDraft(hex)
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
                if state.openConversationKind == .group { return sendGroupPost(&state) }
                let text = state.draft
                let pending = state.pendingAttachment
                // Text or an attachment, not while a pick is still being prepared.
                guard !text.isEmpty || pending != nil,
                      !state.attachmentPreparing,
                      let peerHex = state.openPeerHex,
                      !state.isBlocked(peerHex),            // spec 2026-10-15 §2: no sends to a blocked peer
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
                let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
                let attachmentStore = self.attachmentStore
                let attachmentCacheEvictor = self.attachmentCacheEvictor
                // My profile photo (spec 2026-10-19): the plan is built in the effect from the
                // peer's delivery row; the image rides only off the slow radio path.
                let myVersion = state.myPhotoVersion
                let imageAllowed = state.profilePhotoMayRide
                let avatarStore = self.avatarStore
                state.draft = ""
                state.saveDraft(now: now)
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
                            let plan = try await profilePhotoPlan(database, avatarStore, peerHex: peerHex,
                                                                  myVersion: myVersion, imageAllowed: imageAllowed)
                            let (msg, row) = Self.outgoing(
                                identity: identity, peer: peer, peerHex: peerHex, text: text, now: now,
                                fields: replyFields + expiryFields + plan.fields,
                                replyToHash: replyToHash, replyQuote: replyQuote,
                                expirySeconds: expiry,
                                expiresAt: expiry.map { now.addingTimeInterval(TimeInterval($0)) })
                            try await database.write { db in
                                try Message.insert { row }.execute(db)
                                if let version = plan.pendingVersion {
                                    try ProfilePhotoDelivery.markPending(peerHex, version: version, hash: row.messageHash, db)
                                }
                            }
                            await send(.node(.client(.sendMessage(message: msg, fallbackToPropagation: fallbackToPropagation))))
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
                        let plan = try await profilePhotoPlan(database, avatarStore, peerHex: peerHex,
                                                              myVersion: myVersion, imageAllowed: imageAllowed)
                        let (msg, row) = Self.outgoing(
                            identity: identity, peer: peer, peerHex: peerHex, text: text, now: now,
                            fields: attachmentFields + replyFields + expiryFields + plan.fields,
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
                                if let version = plan.pendingVersion {
                                    try ProfilePhotoDelivery.markPending(peerHex, version: version, hash: messageHash, db)
                                }
                            }
                        } catch {
                            AppFeature.inbound.error("attachment send: database write failed for \(String(messageHash.prefix(8)), privacy: .public): \(String(describing: error), privacy: .public)")
                            try? attachmentStore.delete(path)
                            await send(.attachmentSendFailed(draft: text))
                            return
                        }
                        await send(.node(.client(.sendMessage(message: msg, fallbackToPropagation: fallbackToPropagation))))
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
                if state.openConversationKind == .group {
                    // Spec §3: one reaction message per reachable member, the post id as the
                    // standard target plus the group marker; unreachable members miss it
                    // (amendment A9). The row keys on the post id like every group reaction.
                    guard target.count == GroupWire.idLength else { return .none }
                    let me = state.myAddressHex
                    let mine = state.threadReactionRows.first { $0.messageHash == messageHash && $0.reactorHex == me }
                    let newEmoji = mine?.emoji == emoji ? "" : emoji
                    let sentAt = max(date.now.timeIntervalSince1970, (mine?.sentAt ?? 0) + 0.001)
                    let recipients = state.openGroupOthers.filter { state.reachablePeers.contains($0) }
                    let copies: [LXMessage] = recipients.compactMap { hex in
                        guard let member = Data(hexString: hex) else { return nil }
                        return LXMessage.create(
                            source: state.identity, destinationHash: member, timestamp: sentAt,
                            title: Data(), content: Data(),
                            fields: ReactionWire.encode(target: target, emoji: newEmoji) + GroupWire.encodeMarker(groupId: peer))
                    }
                    let row = Reaction(messageHash: messageHash, reactorHex: me, emoji: newEmoji, sentAt: sentAt)
                    state.setThreadReactionRows(
                        state.threadReactionRows.filter { !($0.messageHash == messageHash && $0.reactorHex == me) } + [row]
                    )
                    let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
                    let sends: [Effect<Action>] = copies.map {
                        .send(.node(.client(.sendMessage(message: $0, fallbackToPropagation: fallbackToPropagation))))
                    }
                    return .merge(sends + [.run { [database] send in
                        _ = try await database.write { try Reaction.apply(row, $0) }
                        try await reloadThread(database, peerHex, send)
                    }])
                }
                // Spec 2026-10-15 §2: a reaction is a message, none to a blocked peer.
                guard !state.isBlocked(peerHex) else { return .none }
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
                let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, fallbackToPropagation: fallbackToPropagation)))),
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
                state.saveDraft(now: date.now)
                return .none

            case .binding(\.draft):
                // Every edit is saved, so backgrounding or leaving the chat loses nothing.
                state.saveDraft(now: date.now)
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
                // Spec §3 "Deferred copies": this member may have group copies waiting for a path.
                let groupDispatch = groupDispatchEffect(state, members: [h.hexString])

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
                    return .merge(debounceEffect, groupDispatch)
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
                    },
                    groupDispatch
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
                    // A group reaction (spec §3 "Receiving") carries the group marker and is kept
                    // only from a current member of a known open group; it keys on the post id.
                    let marker: String? = {
                        guard validated, case let .marker(gid)? = GroupWire.decode(m.fields) else { return nil }
                        return gid.hexString
                    }()
                    let reaction: Reaction? = validated
                        ? Reaction(messageHash: target.hexString, reactorHex: incomingPeer,
                                   emoji: emoji, sentAt: m.timestamp)
                        : nil
                    return .run { [database] send in
                        let applied = try await database.write { db -> Bool in
                            var applied = false
                            if let reaction {
                                if let marker {
                                    if let group = try ChatGroup.fetch(marker, db), group.isOpen,
                                       try GroupMember.contains(marker, incomingPeer, db) {
                                        try Reaction.apply(reaction, db)
                                        applied = true
                                    }
                                } else {
                                    try Reaction.apply(reaction, db)
                                    applied = true
                                }
                            }
                            try recordSeenHash(seenHashHex, at: seenNow, db)
                            return applied
                        }
                        if applied, let openPeer, incomingPeer == openPeer || marker == openPeer {
                            try await reloadThread(database, openPeer, send)
                        }
                    }
                case .malformed:
                    return .run { [database] _ in
                        try await database.write { try recordSeenHash(seenHashHex, at: seenNow, $0) }
                    }
                case .notReaction:
                    break
                }
                // Profile photo (0xA0) and LXMF icon appearance (0x04), spec 2026-10-19
                // "Receiving": only a validated sender may set either. Applied in the effects
                // below, before the message write; never on a reaction (handled above).
                let profile = validated ? ProfileWire.decode(m.fields) : nil
                let icon = validated ? IconAppearanceWire.decode(m.fields) : nil
                let avatarStore = self.avatarStore
                // Standard LXMF reply fields (0x30 / 0x31). Only an ordinary message gets here: a
                // reaction that also carries reply fields was handled above, reply fields ignored.
                let reply = ReplyWire.decode(m.fields)
                // Disappearing messages (spec §3 "Receiving", amendments A1, A4, A5). Only a
                // validated sender may set or carry a timer: an unsigned message is plain text.
                let decodedExpiry = validated ? ExpiryWire.decode(m.fields) : nil
                // Group chats (spec §3 "Receiving"): only a validated sender's group entry counts.
                // `.post` is handled in the write below; `.roster` and `.leave` in their own
                // branches; `.marker` on a non-reaction is ignored (an ordinary message).
                let groupDecoded = validated ? GroupWire.decode(m.fields) : nil
                switch groupDecoded {
                case .roster?, .leave?:
                    return .merge(state.pathRequestIfUnreachable(incomingPeer),
                                  receiveGroupControl(state, message: m, validated: validated, method: method, control: groupDecoded!))
                default:
                    break
                }
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
                // Captured by value for the effects: when the sender says it wrote the message (A10).
                let senderTime = MessageMetadata.senderTimestamp(m.timestamp)
                // Spec "Bug fix folded in", narrowed by final review 3: a message is not a bubble
                // only when it has nothing to show (no content, title, attachment, timer line or
                // reply) AND every field it carries is one known to carry nothing displayable on
                // its own: telemetry 0x02, telemetry stream 0x03, icon 0x04, commands 0x09,
                // results 0x0A, profile photo 0xA0, and our own expiry/group meta 0xFD. Sideband's
                // icon-only and telemetry-only messages land here: the profile and icon still
                // apply, the hash is remembered so it is not re-delivered, and no Message row is
                // written. Anything else (a voice message, an attachment AttachmentWire could not
                // decode, a field we do not know) is stored with a placeholder body.
                let hasDisplay = !m.content.isEmpty || !m.title.isEmpty || decodedAttachment != nil
                    || isTimerChange || reply != nil
                let noDisplayFields: Set<Int> = [0x02, 0x03, IconAppearanceWire.fieldIconAppearance, 0x09, 0x0A,
                                                 ProfileWire.fieldProfilePhoto, ExpiryWire.fieldCustomMeta]
                if !hasDisplay && m.fields.allSatisfy({ noDisplayFields.contains($0.key) }) {
                    return .run { [database] send in
                        await applyPeerProfile(profile, icon, peerHex: incomingPeer, sentAt: senderTime,
                                               at: seenNow, database, avatarStore, send)
                        try await database.write { try recordSeenHash(seenHashHex, at: seenNow, $0) }
                        try await reloadConversations(database, send)
                    }
                }
                // FIELD_AUDIO (0x07): Sideband/Columba voice messages, which this app cannot play.
                let placeholderBody: String? = hasDisplay ? nil
                    : (m.fields.contains { $0.key == 0x07 } ? "Voice message (not supported)" : "Unsupported message")
                let incomingSeconds: Int? = {
                    guard let decoded = decodedExpiry, !decoded.isChange, decoded.seconds > 0 else { return nil }
                    return decoded.seconds
                }()
                // Arriving into the open thread while the app is active and the chat is on screen
                // (amendment A11) is "viewed" at once.
                let viewedNow: Date? = (incomingPeer == openPeer && state.isForeground && state.chatVisible) ? date.now : nil
                let peerName = state.peerDisplayName(incomingPeer)
                let receivedBody = placeholderBody ?? String(decoding: m.content, as: UTF8.self)
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
                    // Never throws: a failed photo or icon leaves the message to be stored below.
                    await applyPeerProfile(profile, icon, peerHex: incomingPeer, sentAt: senderTime,
                                           at: seenNow, database, avatarStore, send)
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
                    let result = try await database.write { db -> (expiresAt: Date?, threadKey: String?) in
                        var stored = row
                        // A post goes into its group only from a current member of a known open
                        // group (spec §1 receive rules); anything else stays a one-to-one message
                        // with the field ignored. A duplicate post id records its hash and stores
                        // nothing. A group post never carries a timer (amendment A9).
                        var isGroupPost = false
                        if case let .post(gid, pid)? = groupDecoded {
                            let gidHex = gid.hexString
                            let pidHex = pid.hexString
                            if let group = try ChatGroup.fetch(gidHex, db), group.isOpen,
                               try GroupMember.contains(gidHex, incomingPeer, db) {
                                let duplicate = try Message.where { $0.groupHex.eq(gidHex) && $0.groupPostId.eq(pidHex) }.fetchOne(db)
                                if duplicate != nil {
                                    try recordSeenHash(seenHashHex, at: seenNow, db)
                                    return (nil, nil)
                                }
                                stored.groupHex = gidHex
                                stored.groupPostId = pidHex
                                stored.messageHash = pidHex   // amendment A2
                                stored.expirySeconds = nil
                                stored.expiresAt = nil
                                stored.isTimerChange = false
                                isGroupPost = true
                            }
                        }
                        if isGroupPost {
                            // No conversation-setting logic for a group row.
                        } else if let decoded = decodedExpiry {
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
                        return (stored.expiresAt, stored.groupHex ?? incomingPeer)
                    }
                    try await reloadConversations(database, send)
                    if let key = result.threadKey, key == openPeer {
                        try await reloadThread(database, key, send)
                    }
                    if result.expiresAt != nil {
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
                guard !state.isBlocked(peerHex) else { return .none }   // spec 2026-10-15 §2
                let seconds = ExpiryWire.clamp(seconds)
                // Amendment A14: picking the value already in force sends and stores nothing.
                guard seconds != (state.openConversationExpiry ?? 0) else { return .none }
                state.openConversationExpiry = seconds > 0 ? seconds : nil
                // The user's pick is the truth from here on, ahead of the database write below.
                state.openConversationExpiryLoaded = true
                let now = date.now
                let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
                // The change goes out as a message with a readable body (spec §1): other LXMF
                // clients show the sentence, ReTiCaMsgr peers adopt the timer from the field.
                let (msg, row) = Self.outgoing(
                    identity: state.identity, peer: peer, peerHex: peerHex,
                    text: ExpiryPreset.announcement(seconds: seconds), now: now,
                    fields: ExpiryWire.encodeChange(seconds: seconds),
                    replyToHash: nil, replyQuote: nil, isTimerChange: true)
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, fallbackToPropagation: fallbackToPropagation)))),
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
                let before = state.effectivePropagationNodeHex
                state.$propagationNodeHex.withLock { $0 = hex }
                // While the default is in effect the stored hex is kept for later but not applied.
                return propagationChangeEffects(state, from: before)

            case let .setUsePropagationDefault(on):
                let before = state.effectivePropagationNodeHex
                state.$usePropagationDefault.withLock { $0 = on }
                return propagationChangeEffects(state, from: before)

            case let .addNode(name, host, port, pushHubHex):
                guard NodeRules.validationError(host: host, port: port, pushHubHex: pushHubHex,
                                                among: state.nodes) == nil else {
                    return .none
                }
                let (cleanHost, hex) = NodeRules.normalized(host: host, pushHubHex: pushHubHex)
                let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let entry = NodeEntry(id: uuid(), name: cleanName.isEmpty ? cleanHost : cleanName,
                                      host: cleanHost, port: port, enabled: true, pushHubHex: hex)
                let before = state.pushNode
                state.$nodes.withLock { $0 = NodeRules.enforceOnePushNode($0 + [entry], keeping: entry.id) }
                return nodeChangeEffects(&state, from: before)

            case let .updateNode(updated):
                guard let index = state.nodes.firstIndex(where: { $0.id == updated.id }),
                      !state.nodes[index].isBuiltIn,
                      NodeRules.validationError(host: updated.host, port: updated.port,
                                                pushHubHex: updated.pushHubHex,
                                                among: state.nodes, excluding: updated.id) == nil
                else { return .none }
                var entry = updated
                (entry.host, entry.pushHubHex) = NodeRules.normalized(host: updated.host, pushHubHex: updated.pushHubHex)
                entry.isBuiltIn = false
                let cleanName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
                entry.name = cleanName.isEmpty ? entry.host : cleanName
                let before = state.pushNode
                state.$nodes.withLock { nodes in
                    nodes[index] = entry
                    nodes = NodeRules.enforceOnePushNode(nodes, keeping: entry.id)
                    nodes = NodeRules.restoringDefaultPushHex(nodes)
                }
                return nodeChangeEffects(&state, from: before)

            case let .removeNode(id):
                guard let entry = state.nodes.first(where: { $0.id == id }), !entry.isBuiltIn else { return .none }
                let before = state.pushNode
                state.$nodes.withLock { nodes in
                    nodes.removeAll { $0.id == id }
                    nodes = NodeRules.restoringDefaultPushHex(nodes)
                }
                return nodeChangeEffects(&state, from: before)

            case let .setNodeEnabled(id, enabled):
                guard let index = state.nodes.firstIndex(where: { $0.id == id }),
                      state.nodes[index].enabled != enabled
                else { return .none }
                let before = state.pushNode
                state.$nodes.withLock { $0[index].enabled = enabled }
                return nodeChangeEffects(&state, from: before)

            case .pushRegistrationSettled:
                // The deferred half of a node edit (backlog item 1): the old hub's unregister
                // settled, so the slots can change and push can be re-pointed.
                guard state.pendingUnregister != nil else { return .none }
                state.pendingUnregister = nil
                return nodeChangeEffects(&state)

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
                state.inFlightSends.remove(hash)
                let finished = finishSendingInBackground(&state)
                let openPeer = state.openPeerHex
                let accepted: Bool? = true   // Optional on purpose, like `milestoneAt`.
                let milestoneAt: Date? = date.now
                return .merge(finished, .run { [database] send in
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
                        // The node holds a copy whatever the status says, so Info reports it.
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing }
                            .update { $0.sentViaPropagation = accepted }
                            .execute(db)
                        // Info milestone: the FIRST acceptance time, including a late acceptance
                        // after "delivered" (the status stays delivered, the time is still news).
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.storedAt.is(nil) }
                            .update { $0.storedAt = milestoneAt }
                            .execute(db)
                        // A group copy carries its own hash in its delivery row (spec §3).
                        try GroupDelivery.applyOutcome(hash: hex, .stored, at: milestoneAt ?? .distantPast, db)
                        // A propagation node holding it counts as delivered for my photo (spec 2026-10-19).
                        try ProfilePhotoDelivery.applyOutcome(hash: hex, confirmed: true, db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                })

            case let .node(.client(.delegate(.deliveryConfirmed(hash)))):
                // The recipient proved receipt of the delivery copy (for opportunistic sends, via
                // ReTiCA single-packet proofs). Without this a delivered message would read "sending"
                // forever, because a proving peer never yields a later `deliveryFailed`.
                let hex = hash.hexString
                state.outgoingProgress[hex] = nil
                // Idempotent: the propagated copy can also be accepted, before or after this.
                state.inFlightSends.remove(hash)
                let finished = finishSendingInBackground(&state)
                let openPeer = state.openPeerHex
                let milestoneAt: Date? = date.now
                // Optional on purpose, like `milestoneAt`: the update subscript takes an optional
                // expression, not a nil literal.
                let noReason: String? = nil
                return .merge(finished, .run { [database] send in
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
                        try GroupDelivery.applyOutcome(hash: hex, .delivered, at: milestoneAt ?? .distantPast, db)
                        try ProfilePhotoDelivery.applyOutcome(hash: hex, confirmed: true, db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                })

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
                //       container level, so the address no longer traverses the tcpClients set)
                guard !destinations.isEmpty else { return .none }
                // Launch race: if the interface already registered before this DB read landed, the seed in
                // interfaceConnected (Task 1) ran against an empty learned table and missed these entries. Seed
                // from the payload now — only those whose interface is currently registered (same reachability
                // test). No-op when disconnected: interfaceConnected will seed from Transport.learned instead.
                var groupDispatch: Effect<Action> = .none
                if state.connection == .connected {
                    seedReachablePeers(&state, from: destinations)
                    groupDispatch = groupDispatchEffect(state, members: state.reachablePeers)
                }
                return .merge(
                    .send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations(destinations)))))),
                    groupDispatch
                )

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

            case let .node(.client(.sendMessage(message, _))):
                state.inFlightSends.insert(message.hash)
                return .none

            case .node, .binding, .pushRegistrationTimedOut, .unregisterFromHub:
                return .none

            // The contact-link arms live in `ContactLinksReducer` (AppFeature+ContactLinks.swift).
            case .linkContactTapped, .contactsAccessResolved, .dismissContactsDenied, .linkPickerDismissed,
                 .contactPicked, .replaceLinkConfirmed, .cancelLinkCollision, .unlinkContact,
                 .markContactVerified, .confirmationReceived, .dismissVerifyPrompt, .conflictReported,
                 .resolveConflict, .contactNameRefreshed, .contactRowAppeared, .contactCardLoaded,
                 .contactLinksLoaded, .setContactMirror, .contactLinkSheetAppeared, .importCandidatesFound,
                 .importContactLinks:
                return .none

            // The blocking arms live in `BlockingReducer` (AppFeature+Blocking.swift).
            case .blockPeer, .unblockPeer, .blockedPeersLoaded, .reportPeer, .reportDraftReady, .reportDismissed:
                return .none

            // The profile-photo arms live in `ProfilePhotoReducer` (AppFeature+ProfilePhoto.swift).
            case .profilePhotoPicked, .profilePhotoSaved, .profilePhotoFailed, .removeProfilePhotoTapped,
                 .myPhotoFileMissing, .peerProfilesLoaded, .peerProfileUpdated:
                return .none

            // The Meshtastic picker arms live in `MeshtasticSettingsReducer` (AppFeature+Meshtastic.swift).
            case .chooseRadioTapped, .radioPicker:
                return .none
            }
        }

        Reduce { state, action in
            // Push registration over the hub's link (spec amendment A2). Translate the actions the
            // flow cares about into its events, run it, and turn its commands into endpoint actions.
            let event: RegistrationLinkFlow.Event?
            switch action {
            case let .push(.delegate(.sendRegistration(hub, path, data))):
                if path == RegistrationWire.unregisterPath {
                    // Never buffered (backlog item 1): a stale unregister resumed on a later
                    // connect would `.start`-cancel a live registration. Best effort — the hub
                    // expires registrations on its own — so an unreachable hub settles at once.
                    guard state.node.client.endpoint.transport.reachableLearned(hub) != nil else {
                        return .send(.pushRegistrationSettled)
                    }
                    event = .start(hub: hub, path: path, data: data, hubKnown: true)
                    break
                }
                // I1: `sendRegistration` fired at launch races the socket — `learned[hub]` can
                // exist (rehydrated from the previous session) while the interface itself is not
                // up yet, so `openLink` would fail `.pathStale` at once; an unknown hub would send
                // a path request nothing can answer. Buffer until the push node's interface actually
                // connects, then `interfaceConnected` resumes this with the real check below.
                let hubID = state.pushNode?.interfaceID
                guard let hubID, state.connectedInterfaces.contains(hubID) else {
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
            case let .unregisterFromHub(hub):
                // A node edit moved the push role off `hub` (backlog item 1). Same rule as the
                // push feature's own unregister above: run only against a reachable hub.
                guard state.node.client.endpoint.transport.reachableLearned(hub) != nil else {
                    return .send(.pushRegistrationSettled)
                }
                event = .start(hub: hub, path: RegistrationWire.unregisterPath,
                               data: RegistrationWire.unregisterRequest(), hubKnown: true)
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
                        ordered.append(.send(.pushRegistrationSettled))
                    case .failure(.cancelled):
                        // I2: a cancellation is caused by a newer attempt's `.start`, whose own
                        // timer was just armed with `cancellable(id:, cancelInFlight: true)` —
                        // that already retired the old timer. Cancelling here too would hit the
                        // SAME CancelID and retire the NEW attempt's timer instead (a stray cancel
                        // on an otherwise-idle flow is a no-op, so this is not merely redundant,
                        // it is actively wrong). The newer attempt reports its own result;
                        // forwarding this one would land on it — and it settles for both.
                        break
                    case let .failure(failure):
                        ordered.append(.cancel(id: CancelID.pushRegistration))
                        ordered.append(.send(.push(.registrationResponse(.failure(RegistrationFailure(failure))))))
                        ordered.append(.send(.pushRegistrationSettled))
                    }
                }
            }
            if !ordered.isEmpty { effects.append(.concatenate(ordered)) }
            return effects.isEmpty ? .none : .merge(effects)
        }

        ContactLinksReducer()
        BlockingReducer()
        ProfilePhotoReducer()
        MeshtasticSettingsReducer()
        MeshtasticRadioReducer()
        BLESlotReducer()
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
        state.inFlightSends.remove(hash)
        let finished = finishSendingInBackground(&state)
        let openPeer = state.openPeerHex
        let milestoneAt: Date? = date.now
        return .merge(finished, .run { [database] send in
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
                try GroupDelivery.applyOutcome(hash: hex, status == MessageStatus.cancelled ? .cancelled : .failed,
                                               at: milestoneAt ?? .distantPast, db)
                // The photo it carried did not arrive: the next message attaches it again.
                try ProfilePhotoDelivery.applyOutcome(hash: hex, confirmed: false, db)
            }
            try await reloadConversations(database, send)
            if let openPeer {
                try await reloadThread(database, openPeer, send)
            }
        })
    }

    /// Disconnects every TCP client: the hub's side of a suspended app's socket never goes
    /// dormant otherwise (see `.backgrounded`). BLE peers are left to run on their own terms.
    private func closeHubSockets(_ state: State) -> Effect<Action> {
        .merge(state.node.client.endpoint.tcpClients.ids.map {
            .send(.node(.client(.endpoint(.tcpClients(.element(id: $0, action: .disconnect))))))
        })
    }

    /// Gives back the background time held for sends in flight, if any, and stops waiting for it
    /// to run out (iOS's expiry and the early deadline both). Clearing the id first makes it once only.
    private func endBackgroundTask(_ state: inout State) -> Effect<Action> {
        guard let id = state.backgroundTaskID else { return .none }
        state.backgroundTaskID = nil
        return .merge(.cancel(id: CancelID.backgroundTask), .cancel(id: CancelID.backgroundDeadline),
                      .run { [backgroundTask] _ in await backgroundTask.end(id) })
    }

    /// A send settled. If it was the last one and the app is in the background on borrowed time,
    /// close the sockets now and give the time back (amendment A4).
    private func finishSendingInBackground(_ state: inout State) -> Effect<Action> {
        guard !state.isForeground, state.inFlightSends.isEmpty, state.backgroundTaskID != nil else { return .none }
        let close = closeHubSockets(state)
        return .merge(close, endBackgroundTask(&state))
    }

    /// The outgoing LXMessage and its `sending` row. Outgoing Info metadata: `wireSize` is the
    /// unstamped packed size (LXMFNode adds any stamp downstream, where the app cannot see it, hence
    /// no stampState either). `packed` is a computed re-encode, so it is read once.
    static func outgoing(identity: Identity, peer: Data, peerHex: String, text: String, now: Date,
                         fields: [MsgPackValue.IntPair],
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
            sentViaPropagation: false,
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

    /// An outgoing event line (spec §3): a system line with `isGroupEvent`, carrying `control` to
    /// the members through its delivery rows. `status` starts as `sending` and is derived from the
    /// delivery rows from then on (`GroupDelivery.refreshDerivedStatus`).
    static func groupEventRow(groupHex: String, me: String, body: String, control: String?, now: Date) -> Message {
        Message(id: UUID(), peerHex: me, isOutgoing: true, body: body, timestamp: now,
                status: MessageStatus.sending, validated: false, messageHash: "",
                senderTimestamp: now, fieldKeys: "", groupHex: groupHex, isGroupEvent: true, groupControl: control)
    }

    /// One member's copy of a group row (spec §3, amendment A3). The title is the group name; the
    /// fields follow the row's kind: a post carries its reply fields then the group and post ids,
    /// a roster line the group's current roster (an empty one, with the delete body, once the
    /// group is dissolved), a leave line the leave marker. `timestamp` is the dispatch time, so a
    /// re-sent copy has a fresh hash. nil when an id does not decode. `profileFields` (my profile
    /// photo, spec 2026-10-19) are appended to a post copy only.
    static func groupCopy(of row: Message, to member: Data, group: ChatGroup, members: [String],
                          identity: Identity, myName: String, timestamp: Double,
                          profileFields: [MsgPackValue.IntPair] = []) -> LXMessage? {
        guard let groupId = Data(hexString: group.groupHex), groupId.count == GroupWire.idLength else { return nil }
        let title = Data(GroupWire.trimName(group.name).utf8)
        let body: String
        let fields: [MsgPackValue.IntPair]
        switch row.groupControl {
        case GroupControl.roster?:
            let roster = members.compactMap { Data(hexString: $0) }.filter { $0.count == GroupWire.idLength }
            body = group.state == GroupState.dissolved
                ? GroupEventText.deleteBody(who: myName, name: group.name)
                : GroupEventText.rosterBody(inviter: myName, name: group.name)
            fields = GroupWire.encodeRoster(groupId: groupId, name: group.name, members: roster, revision: group.revision)
        case GroupControl.leave?:
            body = GroupEventText.leaveBody(who: myName, name: group.name)
            fields = GroupWire.encodeLeave(groupId: groupId)
        default:
            guard let postId = row.groupPostId.flatMap({ Data(hexString: $0) }), postId.count == GroupWire.idLength
            else { return nil }
            var replyFields: [MsgPackValue.IntPair] = []
            if let replyTo = row.replyToHash.flatMap({ Data(hexString: $0) }), !replyTo.isEmpty {
                replyFields = ReplyWire.encode(replyTo: replyTo, quote: row.replyQuote ?? "")
            }
            body = row.body
            fields = replyFields + GroupWire.encodePost(groupId: groupId, postId: postId) + profileFields
        }
        return LXMessage.create(source: identity, destinationHash: member, timestamp: timestamp,
                                title: title, content: Data(body.utf8), fields: fields)
    }

    /// Spec §3 "Deferred copies": sends the waiting group copies addressed to `members`, then
    /// reloads if anything went out. Used at `pathLearned`, `interfaceConnected` and the launch
    /// seeding of reachable peers, and at `groupRosterChanged` with `groupHex` set so only that
    /// group's rows go.
    private func groupDispatchEffect(_ state: State, members: Set<String>, groupHex: String? = nil) -> Effect<Action> {
        guard !members.isEmpty else { return .none }
        let identity = state.identity
        let myName = state.myName
        let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
        let openPeer = state.openPeerHex
        let now = date.now
        let myVersion = state.myPhotoVersion
        let imageAllowed = state.profilePhotoMayRide
        let avatarStore = self.avatarStore
        return .run { [database] send in
            let sent = try await dispatchWaitingGroupCopies(database, members: members, identity: identity,
                                                            myName: myName, fallbackToPropagation: fallbackToPropagation,
                                                            now: now, groupHex: groupHex, myVersion: myVersion,
                                                            myPhoto: myVersion.isEmpty ? nil : avatarStore.mine(),
                                                            imageAllowed: imageAllowed, send)
            guard sent > 0 else { return }
            try await reloadConversations(database, send)
            if let openPeer { try await reloadThread(database, openPeer, send) }
        }
    }

    /// Spec §3 "Sending a post": one row with a fresh post id (in `messageHash` too, amendment A2)
    /// and one waiting delivery per other member, then the copies to the reachable members and a
    /// path request for the rest. Text only in v1: a pending attachment blocks the send.
    private func sendGroupPost(_ state: inout State) -> Effect<Action> {
        let text = state.draft
        guard !text.isEmpty, !state.attachmentPreparing, state.pendingAttachment == nil,
              let groupHex = state.openPeerHex, let groupId = Data(hexString: groupHex),
              let group = state.openGroup, group.state == GroupState.active
        else { return .none }
        let me = state.myAddressHex
        let others = Set(state.openGroupOthers)
        let postId = GroupWire.randomId()
        let now = date.now
        var replyFields: [MsgPackValue.IntPair] = []
        var replyToHash: String? = nil
        var replyQuote: String? = nil
        if let target = state.replyTarget,
           let replyTo = Data(hexString: target.messageHash), !replyTo.isEmpty {
            let quote = ReplyWire.trimQuote(target.body)
            replyFields = ReplyWire.encode(replyTo: replyTo, quote: quote)
            replyToHash = target.messageHash
            replyQuote = quote.isEmpty ? nil : quote
        }
        let fields = replyFields + GroupWire.encodePost(groupId: groupId, postId: postId)
        let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
        let row = Message(
            id: UUID(), peerHex: me, isOutgoing: true, body: text, timestamp: now,
            status: MessageStatus.sending, validated: false, messageHash: postId.hexString,
            senderTimestamp: now, sentViaPropagation: false,
            titleSize: GroupWire.trimName(group.name).utf8.count, contentSize: text.utf8.count,
            fieldKeys: MessageMetadata.fieldKeys(fields),
            replyToHash: replyToHash, replyQuote: replyQuote,
            groupHex: groupHex, groupPostId: postId.hexString)
        let deliveries = others.sorted().map { GroupDelivery.waiting(messageId: row.id, memberHex: $0) }
        state.draft = ""
        state.saveDraft(now: now)
        state.replyTarget = nil
        state.attachmentError = nil
        let reachable = others.intersection(state.reachablePeers)
        let identity = state.identity
        let myName = state.myName
        let pathRequests = others.subtracting(reachable).map { state.pathRequestIfUnreachable($0) }
        let myVersion = state.myPhotoVersion
        let imageAllowed = state.profilePhotoMayRide
        let avatarStore = self.avatarStore
        let write: Effect<Action> = .run { [database] send in
            try await database.write { db in
                try Message.insert { row }.execute(db)
                for delivery in deliveries { try GroupDelivery.insert { delivery }.execute(db) }
                try GroupDelivery.refreshDerivedStatus(messageId: row.id, db)
            }
            _ = try await dispatchWaitingGroupCopies(database, members: reachable, identity: identity,
                                                     myName: myName, fallbackToPropagation: fallbackToPropagation,
                                                     now: now, myVersion: myVersion,
                                                     myPhoto: myVersion.isEmpty ? nil : avatarStore.mine(),
                                                     imageAllowed: imageAllowed, send)
            try await reloadThread(database, groupHex, send)
            try await reloadConversations(database, send)
        }
        return .merge(pathRequests + [.cancel(id: CancelID.attachmentPreparation), write])
    }

    /// Spec §3 "Receiving" for `.roster` and `.leave` (amendments A5, A7): the rules run inside
    /// one write; an applied change reloads (and fans a creator's re-issued roster out), a stale
    /// roster is dropped, and anything invalid is stored as the plain one-to-one message its
    /// readable body already is. Names are resolved here, where announces live.
    private func receiveGroupControl(_ state: State, message m: LXMessage, validated: Bool,
                                     method: LXMFRouter.DeliveryMethod, control: GroupWire.Decoded) -> Effect<Action> {
        let incomingPeer = m.sourceHash.hexString
        let seenHashHex = m.hash.hexString
        let now = date.now
        let openPeer = state.openPeerHex
        // Amendment A12 of the disappearing-messages spec applies to the plain-message fallback
        // too: a message with no expiry of its own takes the local timer, stamped at once when
        // the thread is open and visible, exactly as the ordinary receive path does.
        let viewedNow: Date? = (incomingPeer == openPeer && state.isForeground && state.chatVisible) ? now : nil
        let attachmentStore = self.attachmentStore
        let attachmentCacheEvictor = self.attachmentCacheEvictor
        var byHex: [String: String] = [:]
        if case let .roster(_, _, members, _) = control {
            for member in members {
                let hex = member.hexString
                if let name = state.peerDisplayName(hex) { byHex[hex] = name }
            }
        }
        let names = GroupControlApply.Names(me: state.myAddressHex, sender: state.groupMemberName(incomingPeer), byHex: byHex)
        let plain = Message(
            id: UUID(), peerHex: incomingPeer, isOutgoing: false,
            body: String(decoding: m.content, as: UTF8.self), timestamp: now,
            status: MessageStatus.received, validated: validated, messageHash: seenHashHex,
            senderTimestamp: MessageMetadata.senderTimestamp(m.timestamp),
            arrivalMethod: MessageMetadata.arrivalMethod(method),
            wireSize: m.receivedBytes?.count, titleSize: m.title.count, contentSize: m.content.count,
            fieldKeys: MessageMetadata.fieldKeys(m.fields), stampState: MessageMetadata.stampState(m))
        return .run { [database] send in
            let (outcome, expiresAt) = try await database.write { db -> (GroupControlApply.Outcome, Date?) in
                let outcome: GroupControlApply.Outcome
                switch control {
                case let .roster(gid, name, members, revision):
                    outcome = try GroupControlApply.applyRoster(
                        groupHex: gid.hexString, name: name, members: members.map(\.hexString), revision: revision,
                        from: incomingPeer, names: names, validated: validated, now: now, db)
                case let .leave(gid):
                    outcome = try GroupControlApply.applyLeave(
                        groupHex: gid.hexString, from: incomingPeer, names: names, validated: validated, now: now, db)
                default:
                    outcome = .plainMessage
                }
                var expiresAt: Date? = nil
                if outcome == .plainMessage {
                    var row = plain
                    if let local = try ConversationSetting.expiry(for: incomingPeer, db) {
                        row.expirySeconds = local
                        row.expiresAt = viewedNow.map { $0.addingTimeInterval(TimeInterval(local)) }
                    }
                    try Message.insert { row }.execute(db)
                    expiresAt = row.expiresAt
                }
                try recordSeenHash(seenHashHex, at: now, db)
                return (outcome, expiresAt)
            }
            switch outcome {
            case .dropped:
                return
            case .plainMessage:
                try await reloadConversations(database, send)
                if incomingPeer == openPeer { try await reloadThread(database, incomingPeer, send) }
                if expiresAt != nil {
                    try await purgeAndReschedule(database, attachmentStore, attachmentCacheEvictor, now: now, send)
                }
            case let .applied(groupHex, creatorResends):
                if creatorResends { await send(.groupRosterChanged(groupHex: groupHex)) }
                try await reloadConversations(database, send)
                if groupHex == openPeer { try await reloadThread(database, groupHex, send) }
            }
        }
    }

    /// One local roster or membership change (spec §3 "Creating and editing"): `mutate` edits the
    /// group row and its members inside the write, `line` becomes an outgoing event row carrying
    /// `control` to `recipients` through waiting delivery rows, copies go to the reachable
    /// recipients at once and the rest get a path request.
    private func groupChange(_ state: State, groupHex: String, line: String, control: String,
                             recipients: Set<String>,
                             mutate: @escaping @Sendable (inout ChatGroup, GRDB.Database) throws -> Void) -> Effect<Action> {
        let me = state.myAddressHex
        let now = date.now
        let row = Self.groupEventRow(groupHex: groupHex, me: me, body: line, control: control, now: now)
        let deliveries = recipients.sorted().map { GroupDelivery.waiting(messageId: row.id, memberHex: $0) }
        let reachable = recipients.intersection(state.reachablePeers)
        let identity = state.identity
        let myName = state.myName
        let fallbackToPropagation = !state.effectivePropagationNodeHex.isEmpty
        let pathRequests = recipients.subtracting(reachable).map { state.pathRequestIfUnreachable($0) }
        // The roster/leave copy carries no photo, but a waiting post for the same member may go too.
        let myVersion = state.myPhotoVersion
        let imageAllowed = state.profilePhotoMayRide
        let avatarStore = self.avatarStore
        let write: Effect<Action> = .run { [database] send in
            try await database.write { db in
                guard var group = try ChatGroup.fetch(groupHex, db) else { return }
                try mutate(&group, db)
                group.updatedAt = now
                try ChatGroup.upsert(group, db)
                try Message.insert { row }.execute(db)
                for delivery in deliveries { try GroupDelivery.insert { delivery }.execute(db) }
                try GroupDelivery.refreshDerivedStatus(messageId: row.id, db)
            }
            _ = try await dispatchWaitingGroupCopies(database, members: reachable, identity: identity,
                                                     myName: myName, fallbackToPropagation: fallbackToPropagation,
                                                     now: now, myVersion: myVersion,
                                                     myPhoto: myVersion.isEmpty ? nil : avatarStore.mine(),
                                                     imageAllowed: imageAllowed, send)
            try await reloadThread(database, groupHex, send)
            try await reloadConversations(database, send)
        }
        return .merge(pathRequests + [write])
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

// MARK: - Node list → endpoint (spec 2026-10-10 §3)
//
// The endpoint is a STRUCT product: one shared `transport`/`linkPlane`, a SET of TCP client slots,
// and optional listener/BLE slots. Slots are mutated IN PLACE — never `state.node.client.endpoint =
// …`, which would rebuild the container and reset the shared router (learned paths, live links).

/// Runs the one-time migration from the old host/port/hex keys when the list has never been
/// written (it is empty only then: every written list holds the built-in entry).
private func migrateNodesIfNeeded(_ state: inout AppFeature.State, makeID: () -> UUID) {
    guard state.nodes.isEmpty else { return }
    let migrated = NodeMigration.migrate(legacyHost: state.legacyHost, legacyPort: state.legacyPort,
                                         legacyPushHex: state.push.hubHex, makeID: makeID)
    state.$nodes.withLock { $0 = migrated }
}

/// Makes the endpoint's TCP client set match the enabled entries: a slot per enabled entry's
/// `interfaceID` (built here, `reconnectOnDrop: true`), `removeTCPClient` for every slot whose
/// entry is gone, disabled or edited (an edit of host or port changes the id), and a slot that
/// still has an enabled entry kept as it is, so a re-dial never tears down a live socket. The
/// listener and BLE slots follow their settings exactly as before (a running BLE slot is stopped
/// before it is dropped). Returns the removal effects, including that BLE `.stop` (callers
/// `.concatenate` them before any dial), the ids of the slots added, and the radio
/// slot's effect (run with the removals).
private func syncEndpointNodes(_ state: inout AppFeature.State)
    -> (removals: Effect<AppFeature.Action>, added: [InterfaceID], meshtastic: Effect<AppFeature.Action>) {
    let wanted = state.enabledNodes
    var wantedIDs = Set(wanted.map(\.interfaceID))
    // The slot an in-flight `/unregister` runs over is kept until it settles (backlog item 1):
    // a foreground or a second edit meanwhile must not close the socket under it.
    if let pending = state.pendingUnregister { wantedIDs.insert(pending.interfaceID) }
    let stale = state.node.client.endpoint.tcpClients.ids.filter { !wantedIDs.contains($0) }
    var added: [InterfaceID] = []
    for entry in wanted where state.node.client.endpoint.tcpClients[id: entry.interfaceID] == nil {
        guard let port = UInt16(exactly: entry.port) else { continue }
        state.node.client.endpoint.tcpClients.append(
            TCPEndpoint.State(host: entry.host, port: port, reconnectOnDrop: true, interfaceID: entry.interfaceID))
        added.append(entry.interfaceID)
    }

    // Read the @Shared settings into locals first: mutating `state.node…` while reading a shared
    // value in the same statement is an exclusive-access violation.
    let listenEnabled = state.listenEnabled
    let listenPort = UInt16(exactly: state.listenPort)
    let bleEnabled = state.bleEnabled

    // Add or remove the listener slot to match the current setting. Preserve an already-running
    // listener on the same port rather than re-binding on every re-dial.
    if listenEnabled, let listenPort {
        if state.node.client.endpoint.tcpServer?.interface.port != listenPort {
            state.node.client.endpoint.tcpServer = TCPServerEndpoint.State(port: listenPort)
        }
    } else {
        state.node.client.endpoint.tcpServer = nil
    }

    // A fresh connect attempt clears any stale Bluetooth alert (A5): the user may have resolved
    // the permission and is retrying; the library re-emits if the adapter is still unavailable.
    state.bluetoothAlert = nil

    // Add or remove the BLE slot to match the current setting (A1). PRESERVE a running slot: a
    // fresh BLEEndpoint.State would reset `peerInterfaces` and drop every live BLE peer. Removing
    // a slot that is not idle is `.stop` first, drop once idle (`advanceBLESlotRemoval`): a direct
    // `= nil` cancels the interface's effects without running `driver.stop()`, so the adapter
    // keeps scanning and advertising, and its peers stay registered in Transport.
    var bleRemoval: Effect<AppFeature.Action> = .none
    if bleEnabled {
        // Back on before a removal finished: keep the slot. Its stop runs to completion, and a
        // `.start` sent meanwhile is deferred by the interface until that stop returns.
        state.bleSlotRemovalPending = false
        if state.node.client.endpoint.ble == nil {
            state.node.client.endpoint.ble = BLEEndpoint.State(localIdentity: state.identity.hash)
        }
    } else if state.node.client.endpoint.ble != nil {
        state.bleSlotRemovalPending = true
        bleRemoval = advanceBLESlotRemoval(&state)
    }

    // The Meshtastic radio slot follows `meshtasticEnabled` + `meshtasticRadioUUID` (spec 2026-10-16
    // §7 lane E). Dropping a running slot is the amended Contract 3 protocol — `.stop`, wait for
    // `.radioOffline`, then replace — so it is an effect the caller runs, never a direct `= nil`.
    let meshtastic = syncMeshtasticSlot(&state)

    let removals: Effect<AppFeature.Action> = .merge(stale.map {
        .send(.node(.client(.endpoint(.removeTCPClient($0)))))
    } + [bleRemoval])
    return (removals, added, meshtastic)
}

/// `.connect` for each of `ids` (slots `syncEndpointNodes` just added, or nodes found down).
private func connectEffects(_ ids: some Collection<InterfaceID>) -> Effect<AppFeature.Action> {
    .merge(ids.map { .send(.node(.client(.endpoint(.tcpClients(.element(id: $0, action: .connect)))))) })
}

/// Points the push feature at the push node (spec §3 "Push", amendment A7): host and port
/// always (`""`/`0` when there is no push node, so the extension never proves to a stale hub),
/// the hex only when it differs from what the push feature holds, because the push feature
/// treats every `setHubHex` as a hub change (it forgets the registration).
///
/// Amendment A14 (final-review F1): when the push node disappears while push is enabled, the
/// app turns push off itself — before the hex is cleared, so the push feature's best-effort
/// `/unregister` still has the old hub to address (it may not reach a removed node; the hub
/// expires registrations on its own, and the APNs unregistration stops wakes regardless), but
/// AFTER `hubChanged`: the push feature saves the extension's settings on `hubChanged` only while
/// enabled, so the host must change hands before the switch-off or the extension keeps proving
/// to the old hub (backlog item 2). Switching the push node to a DIFFERENT node (never nil in
/// between) must not turn push off.
private func pushSyncEffects(_ state: AppFeature.State) -> Effect<AppFeature.Action> {
    let node = state.pushNode
    let hex = node?.pushHubHex ?? ""
    var effects: [Effect<AppFeature.Action>] = [
        .send(.push(.hubChanged(host: node?.host ?? "", port: node?.port ?? 0))),
    ]
    if node == nil, state.push.enabled {
        effects.append(.send(.push(.setEnabled(false))))
    }
    // Case-insensitive: an uppercase hex persisted by an older build is the same hub (item 8).
    if state.push.hubHex.lowercased() != hex {
        effects.append(.send(.push(.setHubHex(hex))))
    }
    // Concatenated, not merged: the tests (and the push feature's own bookkeeping) rely on
    // `hubChanged` landing first and `setHubHex` landing last.
    return .concatenate(effects)
}

/// `pushSyncEffects`, unless an `/unregister` is in flight: its `setHubHex` would start the new
/// hub's registration and `.start`-cancel the unregister, so the re-point waits for
/// `.pushRegistrationSettled` (backlog item 1). Every caller that syncs outside a node edit
/// (foreground, push wake, Connect) goes through this.
private func heldPushSyncEffects(_ state: AppFeature.State) -> Effect<AppFeature.Action> {
    state.pendingUnregister == nil ? pushSyncEffects(state) : .none
}

/// After a node edit: slots removed, then new ones dialed, then push re-pointed, in that order
/// (`.concatenate`), so a departing slot is never dialed and the receives are deterministic.
private func nodeChangeEffects(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    let sync = syncEndpointNodes(&state)
    return .concatenate(sync.removals, sync.meshtastic, connectEffects(sync.added), heldPushSyncEffects(state))
}

/// After a node edit (backlog item 1). When push is on and the edit moved the push role off a hub
/// that is reachable right now, the app `/unregister`s from that hub FIRST, over its still-open
/// socket, and holds the slot sync and push re-point until the attempt settles
/// (`.pushRegistrationSettled`): a `setHubHex` would otherwise start the new hub's registration
/// and `.start`-cancel the unregister, and a removal would close the socket it needs. On a loss
/// (no push node left) the push feature's own switch-off carries the unregister (A14), with
/// `hubChanged` first so the extension forgets the host (item 2). Anything else applies at once —
/// with the awaited slot kept and the re-point held if an earlier edit's unregister is still in
/// flight (`syncEndpointNodes`, `heldPushSyncEffects`); a second qualifying edit replaces it, and
/// its `.start` cancels the earlier attempt, whose own finish then settles both.
private func nodeChangeEffects(_ state: inout AppFeature.State, from before: NodeEntry?) -> Effect<AppFeature.Action> {
    if state.push.enabled, let before, let oldHex = before.pushHubHex,
       oldHex != state.pushNode?.pushHubHex,
       let hub = Data(hexString: oldHex), hub.count == 16,
       state.node.client.endpoint.transport.reachableLearned(hub) != nil {
        state.pendingUnregister = PendingUnregister(hub: hub, interfaceID: before.interfaceID)
        if state.pushNode == nil {
            return .concatenate(.send(.push(.hubChanged(host: "", port: 0))), .send(.push(.setEnabled(false))))
        }
        return .send(.unregisterFromHub(hub))
    }
    return nodeChangeEffects(&state)
}

/// Re-points the router when the EFFECTIVE propagation node changed to a valid address. There is
/// no clear verb in the node layer: a change to "none" leaves the router on its current node
/// until relaunch, as the old `setPropagationNode("")` did.
private func propagationChangeEffects(_ state: AppFeature.State, from before: String) -> Effect<AppFeature.Action> {
    let after = state.effectivePropagationNodeHex
    guard after != before, let pn = Data(hexString: after), pn.count == 16 else { return .none }
    return .merge(
        .send(.node(.client(.setPropagationNode(destinationHash: pn)))),
        .send(.node(.client(.syncFromPropagationNode)))
    )
}

/// The TCP slots whose interface is not connected: what a re-dial dials, and what a foreground
/// sync leaves to `interfaceConnected`.
private func tcpDownIDs(_ state: AppFeature.State) -> [InterfaceID] {
    state.node.client.endpoint.tcpClients.ids.filter { !state.connectedInterfaces.contains($0) }
}

/// Fetch from the configured propagation node, if there is one (spec 2026-10-21 §3, A1: never
/// from a node the app was not told to use).
private func propagationSyncEffect(_ state: AppFeature.State) -> Effect<AppFeature.Action> {
    guard let pn = Data(hexString: state.effectivePropagationNodeHex), pn.count == 16 else { return .none }
    return .send(.node(.client(.syncFromPropagationNode)))
}

/// The `.foregrounded`/`.pushWake` re-dial (spec §3): iOS tears sockets down while suspended,
/// so every enabled node whose interface is not connected is dialed again; a live node is left
/// alone (re-dialling it would tear down its links on every app switch). The listener restarts
/// when it is STOPPED, or on the first foreground after a suspension (`restartListener`): backlog
/// item 3 — `.listen` is `cancelInFlight`, so re-starting a listening slot drops every accepted
/// direct connection, and with several nodes "one is down" is the normal state on an
/// interruption foreground or a push wake; but a listener the system cancelled while the app was
/// suspended never reports `.failed` (the actor only hears `.ready`/`.failed`), so a real resume
/// restarts it regardless, as every foreground used to. The BLE slot gets `.start` as before,
/// which `BLEInterface` itself ignores unless it is stopped or terminally unavailable. Both run
/// even when there are NO TCP client slots at all (every node disabled or the list empty): the
/// old code always had exactly one slot to find down, so it always reached the listener/BLE
/// restart; `down.isEmpty` alone would now skip it in that case, so `noClientSlots` keeps the
/// restart reachable. `connection` goes to connecting only when nothing is up (amendment A10).
/// The push re-point is held while an `/unregister` is in flight (`heldPushSyncEffects`).
/// Also restarts a stopped or unavailable Meshtastic radio slot (never one a swap is replacing).
private func redialDownNodes(_ state: inout AppFeature.State, restartListener: Bool) -> Effect<AppFeature.Action> {
    let sync = syncEndpointNodes(&state)
    // Restart a stopped or unavailable radio (spec 2026-10-16 §7 lane E). `.start` is ignored by a
    // connecting or online interface, and MeshtasticKit reconnects a dropped radio itself. Never
    // the slot a swap is replacing: a `.start` reaching it during its `driver.stop()` would restart
    // the old radio. Unlike BLE it is not deferred while the picker is open: a MeshtasticSession
    // connects by retrieval and never scans.
    let radioRestart: Effect<AppFeature.Action> =
        state.meshtasticSwap == nil && state.node.client.endpoint.meshtastic != nil
            ? .send(.node(.client(.endpoint(.meshtastic(.start))))) : .none
    let down = tcpDownIDs(state)
    let noClientSlots = state.node.client.endpoint.tcpClients.isEmpty
    guard !down.isEmpty || noClientSlots else { return .concatenate(sync.removals, sync.meshtastic, radioRestart) }
    // Final-review M1: "nothing is up" alone is not enough — with no enabled node, no listener, no
    // BLE and no Meshtastic radio, nothing here is going to dial, and `.connecting` would never
    // resolve.
    if state.connectedInterfaces.isEmpty, state.somethingWillDial {
        state.connection = .connecting
    }
    var dials: [Effect<AppFeature.Action>] = [connectEffects(down)]
    if let server = state.node.client.endpoint.tcpServer,
       restartListener || server.interface.status != .listening {
        dials.append(.send(.node(.client(.endpoint(.tcpServer(.start))))))
    }
    // Never while the radio picker is open (spec 2026-10-16 §7, Review Focus 1): a restart here
    // would take FCB's one scan from the picker, whether or not the picker itself paused BLE (a
    // Disconnect-stopped or unavailable BLE is not paused). The start is deferred, not dropped:
    // marking BLE paused makes the picker's `.radioPicker(.dismiss)` perform it. A slot being
    // removed may get this start too: `BLESlotReducer` stops it again at once.
    if state.node.client.endpoint.ble != nil {
        if state.radioPicker != nil {
            state.blePausedForRadioScan = true
        } else {
            dials.append(.send(.node(.client(.endpoint(.ble(.start))))))
        }
    }
    return .concatenate(sync.removals, sync.meshtastic, .merge(dials + [radioRestart]), heldPushSyncEffects(state))
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

/// Spec §3 "Deferred copies" (amendments A3, A12): every `waiting` delivery row addressed to one
/// of `members` gets its copy built and sent, and moves to `sending` with that copy's hash. A
/// `failed` control copy (roster or leave, amendment A16) for one of them is re-sent the same
/// way, since the control change is what that member is behind on; a failed post is not. With
/// `groupHex` set, only that group's rows are considered. Each row's message gets its derived
/// status refreshed. Returns how many copies went out. A post copy carries my profile photo per
/// member (spec 2026-10-19), planned against that member's delivery row and marked pending in the
/// same write; roster and leave copies never do.
private func dispatchWaitingGroupCopies(_ database: any DatabaseWriter, members: Set<String>,
                                        identity: Identity, myName: String, fallbackToPropagation: Bool,
                                        now: Date, groupHex onlyGroupHex: String? = nil,
                                        myVersion: String, myPhoto: Data?, imageAllowed: Bool,
                                        _ send: Send<AppFeature.Action>) async throws -> Int {
    guard !members.isEmpty else { return 0 }
    let memberList = Array(members)
    let copies: [LXMessage] = try await database.write { db in
        var copies: [LXMessage] = []
        let waiting = try GroupDelivery
            .where { $0.memberHex.in(memberList) && $0.status.eq(GroupDeliveryStatus.waiting) }
            .fetchAll(db)
        let failed = try GroupDelivery
            .where { $0.memberHex.in(memberList) && $0.status.eq(MessageStatus.failed) }
            .fetchAll(db)
        for delivery in waiting + failed {
            let fetched = try Message.where { $0.id.eq(delivery.messageId) }.fetchOne(db)
            guard let row = fetched,
                  let groupHex = row.groupHex,
                  let group = try ChatGroup.fetch(groupHex, db),
                  let member = Data(hexString: delivery.memberHex), member.count == GroupWire.idLength
            else { continue }
            if let onlyGroupHex, groupHex != onlyGroupHex { continue }
            if delivery.status == MessageStatus.failed, row.groupControl == nil { continue }
            let roster = try GroupMember.members(of: groupHex, db)
            var plan = ProfilePhotoOutbox.Plan()
            if row.groupControl == nil {
                plan = ProfilePhotoOutbox.plan(myVersion: myVersion, myPhoto: myPhoto,
                                               delivery: try ProfilePhotoDelivery.fetch(delivery.memberHex, db),
                                               imageAllowed: imageAllowed)
            }
            guard let copy = AppFeature.groupCopy(of: row, to: member, group: group, members: roster,
                                                  identity: identity, myName: myName,
                                                  timestamp: now.timeIntervalSince1970,
                                                  profileFields: plan.fields)
            else { continue }
            if let version = plan.pendingVersion {
                try ProfilePhotoDelivery.markPending(delivery.memberHex, version: version, hash: copy.hash.hexString, db)
            }
            let hashHex: String? = copy.hash.hexString
            try GroupDelivery
                .where { $0.messageId.eq(delivery.messageId) && $0.memberHex.eq(delivery.memberHex) }
                .update {
                    $0.messageHash = hashHex
                    $0.status = MessageStatus.sending
                }
                .execute(db)
            try GroupDelivery.refreshDerivedStatus(messageId: delivery.messageId, db)
            copies.append(copy)
        }
        return copies
    }
    for copy in copies {
        await send(.node(.client(.sendMessage(message: copy, fallbackToPropagation: fallbackToPropagation))))
    }
    return copies.count
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

/// The profile-photo plan for one outgoing one-to-one message (spec 2026-10-19): my bytes are read
/// only when I have a version, and the peer's delivery row decides image, tag or removal.
private func profilePhotoPlan(_ database: any DatabaseWriter, _ avatarStore: AvatarStore, peerHex: String,
                              myVersion: String, imageAllowed: Bool) async throws -> ProfilePhotoOutbox.Plan {
    let delivery = try await database.read { try ProfilePhotoDelivery.fetch(peerHex, $0) }
    return ProfilePhotoOutbox.plan(myVersion: myVersion, myPhoto: myVersion.isEmpty ? nil : avatarStore.mine(),
                                   delivery: delivery, imageAllowed: imageAllowed)
}

/// Applies a received profile photo and/or LXMF icon to the sender's `PeerProfile` (spec
/// 2026-10-19 "Receiving"). The caller has already dropped both for an unvalidated sender.
///
/// Final review 2, the expiry amendment A10 pattern: a photo or removal applies only when the
/// sender set it strictly later than the stored one (`PeerProfile.photoSetAt`), so a propagated
/// older message arriving after a direct newer one cannot roll the avatar back. Its time is the
/// sender's timestamp capped at arrival, so a future-dated clock cannot lock the avatar. The read
/// and the compare happen inside the write that applies it. A new version's file is written
/// first (the row never names a missing file); a refused one's file is deleted again. The
/// replaced (or removed) file is deleted after the write commits. A tag changes nothing; the icon
/// stays last-writer-wins. Nothing here throws: every failure is logged and the message it rode on
/// is still stored.
private func applyPeerProfile(_ profile: ProfileWire.Decoded?, _ icon: IconAppearance?, peerHex: String,
                              sentAt senderTime: Date?, at now: Date, _ database: any DatabaseWriter,
                              _ avatarStore: AvatarStore, _ send: Send<AppFeature.Action>) async {
    guard profile != nil || icon != nil else { return }
    let tag = String(peerHex.prefix(8))
    let setAt = min(senderTime ?? now, now)
    do {
        var staleFile: String? = nil
        var changed = false
        switch profile {
        case let .photo(version, jpeg)?:
            let versionHex = version.hexString
            // Only decides whether the file needs writing; the write below decides the row.
            let storedVersion = try await database.read { try PeerProfile.fetch(peerHex, $0)?.photoVersion }
            // nil when this version's file is already stored (the row's own path is reused).
            var written: String? = nil
            if storedVersion != versionHex {
                do {
                    written = try avatarStore.storePeer(jpeg, peerHex: peerHex, version: versionHex)
                } catch {
                    AppFeature.inbound.error("profile photo write failed for \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
                    break
                }
            }
            let newFile = written
            let outcome: (applied: Bool, versionChanged: Bool, replaced: String?, current: String?)
            do {
                outcome = try await database.write { db in
                    let existing = try PeerProfile.fetch(peerHex, db)
                    let versionChanged = existing?.photoVersion != versionHex
                    // A same-version row keeps its own file; a new version needs the one written.
                    let rowPath = versionChanged ? newFile : existing?.photoPath
                    guard PeerProfile.isNewer(setAt, than: existing), let rowPath
                    else { return (false, false, nil, existing?.photoPath) }
                    let replaced = try PeerProfile.setPhoto(peerHex, version: versionHex, path: rowPath,
                                                            setAt: setAt, at: now, db)
                    return (true, versionChanged, replaced, rowPath)
                }
            } catch {
                // The row still names the old file (a different version, so a different name):
                // the one just written is orphaned.
                if let newFile { try? avatarStore.delete(newFile) }
                throw error
            }
            staleFile = outcome.replaced
            changed = outcome.versionChanged
            if !outcome.applied, let newFile, outcome.current != newFile {
                // Refused as older: the file just written is named by no row.
                try? avatarStore.delete(newFile)
            }
        case .removed?:
            let outcome = try await database.write { db -> (changed: Bool, removed: String?) in
                let existing = try PeerProfile.fetch(peerHex, db)
                guard PeerProfile.isNewer(setAt, than: existing) else { return (false, nil) }
                let had = existing?.photoPath != nil || existing?.photoVersion != nil
                return (had, try PeerProfile.clearPhoto(peerHex, setAt: setAt, at: now, db))
            }
            staleFile = outcome.removed
            changed = outcome.changed
        case .tag?, nil:
            break
        }
        if let icon {
            let iconChanged = try await database.write { db -> Bool in
                let existing = try PeerProfile.fetch(peerHex, db)
                guard existing.map({ IconAppearance(name: $0.iconName ?? "", fg: $0.iconFg ?? "", bg: $0.iconBg ?? "") }) != icon
                else { return false }
                try PeerProfile.setIcon(peerHex, icon, at: now, db)
                return true
            }
            changed = changed || iconChanged
        }
        if let staleFile {
            do {
                try avatarStore.delete(staleFile)
            } catch {
                AppFeature.inbound.error("profile photo delete failed for \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if changed {
            let row = try await database.read { try PeerProfile.fetch(peerHex, $0) }
            await send(.peerProfileUpdated(peerHex: peerHex, row))
        }
    } catch {
        AppFeature.inbound.error("peer profile update failed for \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
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
