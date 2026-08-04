import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import GRDB
import ReTiCA
import ReTiCANode
import ReTiCATransport

@Reducer
public struct AppFeature {
    public enum Connection: Equatable { case disconnected, connecting, connected }

    @ObservableState
    public struct State: Equatable {
        public var node: LXMFServiceNode.State
        public var identity: Identity
        public var myAddressHex: String
        @Shared(.appStorage("host")) public var host: String = "127.0.0.1"
        @Shared(.appStorage("port")) public var port: Int = 4242
        public var connection: Connection = .disconnected
        public var draft = ""
        // Derived list of peers, reloaded after every write.
        public var conversations: [Conversation] = []
        // The peer whose thread is currently open (drives navigation), and its messages.
        public var openPeerHex: String? = nil
        public var threadMessages: [Message] = []
        // Peers with a known path (from pathLearned); gates Send in the UI. Session-only.
        public var reachablePeers: Set<String> = []
        @Shared(.appStorage("propagationNodeHex")) public var propagationNodeHex: String = ""
        @Shared(.appStorage("propagationNodeModeEnabled")) public var nodeModeEnabled: Bool = false

        public init(identity: Identity, host: String = "127.0.0.1", port: Int = 4242) {
            self.identity = identity
            self.myAddressHex = lxmfAddressHex(identity)
            self.node = LXMFServiceNode.State(
                identity: identity,
                endpoint: TCPEndpoint.State(host: host, port: UInt16(port), reconnectOnDrop: true),
                minStampCost: 4
            )
            _host = Shared(wrappedValue: host, .appStorage("host"))
            _port = Shared(wrappedValue: port, .appStorage("port"))
        }
    }

    public enum Action: Equatable, BindableAction {
        case onLaunch
        case connectTapped
        case disconnectTapped
        case openConversation(String)
        case closeConversation
        case startConversation(String)
        case setNodeMode(Bool)
        case setPropagationNode(String)
        case syncTapped
        case sendTapped
        case conversationsLoaded([Conversation])
        case threadLoaded([Message])
        case rehydratePropagationStore([Data])
        case node(LXMFServiceNode.Action)
        case binding(BindingAction<State>)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.node, action: \.node) { LXMFServiceNode() }
        Reduce { state, action in
            switch action {
            case .onLaunch:
                state.connection = .connecting
                return .merge(
                    .send(.node(.client(.endpoint(.start)))),
                    .run { [database] send in try await reloadConversations(database, send) },
                    .run { [database] send in
                        let rows = try await database.read { try PropagationEntryRow.all.fetchAll($0) }
                        await send(.rehydratePropagationStore(rows.map(\.lxmfData)))
                    }
                )

            case .connectTapped:
                state.connection = .connecting
                return .send(.node(.client(.endpoint(.start))))

            case .disconnectTapped:
                state.connection = .disconnected
                return .send(.node(.client(.endpoint(.stop))))

            case .node(.client(.endpoint(.tcp(.transport(.interfaceConnected(_)))))):
                state.connection = .connected
                var effects: [Effect<Action>] = [.send(.node(.client(.registerDelivery)))]
                if let pn = Data(hexString: state.propagationNodeHex), pn.count == 16 {
                    effects.append(.send(.node(.client(.setPropagationNode(destinationHash: pn)))))
                    effects.append(.send(.node(.client(.syncFromPropagationNode))))
                }
                if state.nodeModeEnabled {
                    effects.append(.send(.node(.setNodeMode(true))))
                }
                return .merge(effects)

            case .node(.client(.endpoint(.tcp(.transport(.interfaceDisconnected(_)))))):
                state.connection = .disconnected
                return .none

            case let .node(.client(.endpoint(.delegate(.pathLearned(h, _))))):
                state.reachablePeers.insert(h.hexString)
                return .none

            case let .openConversation(peerHex):
                state.openPeerHex = peerHex
                return .run { [database] send in try await reloadThread(database, peerHex, send) }

            case .closeConversation:
                state.openPeerHex = nil
                state.threadMessages = []
                state.draft = ""
                return .none

            case let .startConversation(hex):
                guard let data = Data(hexString: hex), data.count == 16 else { return .none }
                state.openPeerHex = hex
                return .run { [database] send in try await reloadThread(database, hex, send) }

            case .sendTapped:
                let text = state.draft
                guard !text.isEmpty,
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                let title = Data()
                let content = Data(text.utf8)
                let msg = LXMessage.create(
                    source: state.identity,
                    destinationHash: peer,
                    timestamp: date.now.timeIntervalSince1970,
                    title: title,
                    content: content
                )
                let row = Message(
                    id: UUID(),
                    peerHex: peerHex,
                    isOutgoing: true,
                    body: text,
                    timestamp: date.now,
                    status: MessageStatus.sending,
                    validated: false,
                    messageHash: msg.hash.hexString
                )
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                state.draft = ""
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                    .run { [database] send in
                        try await database.write { try Message.insert { row }.execute($0) }
                        try await reloadThread(database, peerHex, send)
                        try await reloadConversations(database, send)
                    }
                )

            case let .node(.client(.delegate(.messageReceived(m, validated)))):
                let incomingPeer = m.sourceHash.hexString
                let row = Message(
                    id: UUID(),
                    peerHex: incomingPeer,
                    isOutgoing: false,
                    body: String(decoding: m.content, as: UTF8.self),
                    timestamp: date.now,
                    status: MessageStatus.received,
                    validated: validated,
                    messageHash: ""
                )
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    try await reloadConversations(database, send)
                    if incomingPeer == openPeer {
                        try await reloadThread(database, incomingPeer, send)
                    }
                }

            case let .node(.client(.delegate(.deliveryFailed(hash)))):
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write {
                        try Message.where { $0.messageHash.eq(hex) }
                            .update { $0.status = MessageStatus.failed }
                            .execute($0)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }

            case let .conversationsLoaded(rows):
                state.conversations = rows
                return .none

            case let .threadLoaded(rows):
                state.threadMessages = rows
                return .none

            case let .setNodeMode(enabled):
                state.$nodeModeEnabled.withLock { $0 = enabled }
                return .send(.node(.setNodeMode(enabled)))

            case let .setPropagationNode(hex):
                state.$propagationNodeHex.withLock { $0 = hex }
                guard let pn = Data(hexString: hex), pn.count == 16 else { return .none }
                return .merge(
                    .send(.node(.client(.setPropagationNode(destinationHash: pn)))),
                    .send(.node(.client(.syncFromPropagationNode)))
                )

            case .syncTapped:
                return .send(.node(.client(.syncFromPropagationNode)))

            case let .node(.client(.delegate(.propagationAccepted(hash)))):
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write {
                        try Message.where { $0.messageHash.eq(hex) }
                            .update { $0.status = MessageStatus.propagated }
                            .execute($0)
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

            case .node, .binding:
                return .none
            }
        }
    }
}

// Reload helpers (file-scope free functions — no self capture in @Sendable effects).
private func reloadConversations(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let all = try await database.read { try Message.fetchAll($0) }
    await send(.conversationsLoaded(Conversation.list(from: all)))
}

private func reloadThread(_ database: any DatabaseWriter, _ peerHex: String, _ send: Send<AppFeature.Action>) async throws {
    let rows = try await database.read {
        try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll($0)
    }
    await send(.threadLoaded(rows))
}
