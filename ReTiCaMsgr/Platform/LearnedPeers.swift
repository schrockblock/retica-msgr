import Foundation
import ComposableArchitecture
import ReTiCaMsgrCore
import ReTiCANode

/// The node's announce table, read from a view body.
///
/// ReTiCA builds for macOS 13, so its `@ObservableState` accessors are compiled against the
/// pre-Observation overload, which runs Perception's debug check: "accessed from a view but is not
/// being tracked". On macOS 14+ that check is a false alarm: the same access also registers with
/// native Observation, so SwiftUI does track it. Xcode stops on the warning, which looks like a
/// crash, so the check is skipped for this one read. iOS 17+ never reaches it.
func learnedPeers(_ store: StoreOf<AppFeature>) -> [Data: LXMFNode.LearnedPeer] {
    _PerceptionLocals.$skipPerceptionChecking.withValue(true) {
        store.state.node.client.learnedPeers
    }
}
