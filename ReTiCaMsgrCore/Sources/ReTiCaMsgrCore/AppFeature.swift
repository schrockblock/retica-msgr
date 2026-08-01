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
        public var node: LXMFNode.State
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

        public init(identity: Identity, host: String = "127.0.0.1", port: Int = 4242) {
            self.identity = identity
            self.myAddressHex = lxmfAddressHex(identity)
            self.node = LXMFNode.State(
                identity: identity,
                endpoint: Endpoint.State(host: host, port: UInt16(port), reconnectOnDrop: true)
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
        case sendTapped
        case conversationsLoaded([Conversation])
        case threadLoaded([Message])
        case node(LXMFNode.Action)
        case binding(BindingAction<State>)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.node, action: \.node) { LXMFNode() }
        Reduce { state, action in
            switch action {
            case .onLaunch:
                state.connection = .connecting
                return .merge(
                    .send(.node(.endpoint(.connect))),
                    .run { [database] send in try await reloadConversations(database, send) }
                )

            case .connectTapped:
                state.connection = .connecting
                return .send(.node(.endpoint(.connect)))

            case .disconnectTapped:
                state.connection = .disconnected
                return .send(.node(.endpoint(.disconnect)))

            case .node(.endpoint(.transport(.interfaceConnected(_)))):
                state.connection = .connected
                return .send(.node(.registerDelivery))

            case .node(.endpoint(.transport(.interfaceDisconnected(_)))):
                state.connection = .disconnected
                return .none

            case let .node(.endpoint(.delegate(.pathLearned(h, _)))):
                state.reachablePeers.insert(h.hexString)
                return .none

            case let .openConversation(peerHex):
                state.openPeerHex = peerHex
                return .run { [database] send in try await reloadThread(database, peerHex, send) }

            case .closeConversation:
                state.openPeerHex = nil
                state.threadMessages = []
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
                state.draft = ""
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    try await reloadThread(database, peerHex, send)
                    try await reloadConversations(database, send)
                    await send(.node(.send(
                        destinationHash: peer,
                        title: title,
                        content: content,
                        method: .opportunistic
                    )))
                }

            case let .node(.delegate(.messageReceived(m, validated))):
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

            case let .node(.delegate(.deliveryFailed(hash))):
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
