import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
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
        @Shared(.appStorage("peerAddressHex")) public var peerAddressHex: String = ""
        @Shared(.appStorage("host")) public var host: String = "127.0.0.1"
        @Shared(.appStorage("port")) public var port: Int = 4242
        public var peerReachable = false
        public var connection: Connection = .disconnected
        public var draft = ""
        // Fallback: plain array; reloaded after each DB write via .messagesLoaded.
        public var messages: [Message] = []

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
        case setPeer(String)
        case sendTapped
        case messagesLoaded([Message])
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
                return .send(.node(.endpoint(.connect)))

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
                if let peer = Data(hexString: state.peerAddressHex), h == peer {
                    state.peerReachable = true
                }
                return .none

            case let .setPeer(hex):
                state.$peerAddressHex.withLock { $0 = hex }
                state.peerReachable = false
                return .none

            case .sendTapped:
                let text = state.draft
                guard !text.isEmpty, let peer = Data(hexString: state.peerAddressHex) else { return .none }
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
                    peerHex: state.peerAddressHex,
                    isOutgoing: true,
                    body: text,
                    timestamp: date.now,
                    status: MessageStatus.sending,
                    validated: false,
                    messageHash: msg.hash.hexString
                )
                let peerHex = state.peerAddressHex
                state.draft = ""
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    let rows = try await database.read {
                        try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll($0)
                    }
                    await send(.messagesLoaded(rows))
                    await send(.node(.send(
                        destinationHash: peer,
                        title: title,
                        content: content,
                        method: .opportunistic
                    )))
                }

            case let .node(.delegate(.messageReceived(m, validated))):
                let row = Message(
                    id: UUID(),
                    peerHex: m.sourceHash.hexString,
                    isOutgoing: false,
                    body: String(decoding: m.content, as: UTF8.self),
                    timestamp: date.now,
                    status: MessageStatus.received,
                    validated: validated,
                    messageHash: ""
                )
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    let rows = try await database.read { try Message.fetchAll($0) }
                    await send(.messagesLoaded(rows))
                }

            case let .node(.delegate(.deliveryFailed(hash))):
                let hex = hash.hexString
                let peerHex = state.peerAddressHex
                return .run { [database] send in
                    try await database.write {
                        try Message.where { $0.messageHash.eq(hex) }
                            .update { $0.status = MessageStatus.failed }
                            .execute($0)
                    }
                    let rows = try await database.read {
                        try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll($0)
                    }
                    await send(.messagesLoaded(rows))
                }

            case let .messagesLoaded(rows):
                state.messages = rows
                return .none

            case .node, .binding:
                return .none
            }
        }
    }
}
