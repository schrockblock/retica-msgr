import ReTiCANode

/// What Settings says about the last propagation sync. Failures and a finished sync have text;
/// every in-progress state says nothing.
public enum PropagationSyncText {
    public static func describe(_ state: LXMFRouter.PropagationTransferState, lastResult: Int?) -> String? {
        switch state {
        case .noAccess:
            return "This propagation node only serves approved users. Ask its operator to add your address."
        case .noIdentityReceived:
            return "The propagation node did not receive your identity. Try syncing again."
        case .noPath:
            return "Couldn't find a route to the propagation node."
        case .linkFailed:
            return "Couldn't connect to the propagation node."
        case .transferFailed:
            return "The download from the propagation node was interrupted."
        case .complete:
            let n = lastResult ?? 0
            return n == 1 ? "Last sync: 1 new message." : "Last sync: \(n) new messages."
        case .idle, .pathRequested, .linkEstablishing, .linkEstablished, .requestSent,
             .receiving, .responseReceived, .failed:
            return nil
        }
    }
}
