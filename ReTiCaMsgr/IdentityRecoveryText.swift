import Foundation
import ReTiCaMsgrCore

/// Plain wording per identity state and restore outcome (spec §5.5). Public facts only.
enum IdentityRecoveryText {
    struct Screen: Equatable {
        var title: String
        var message: String
        var detail: String?          // behind the "Details" disclosure
        var showsRestore: Bool
        var showsAccept: Bool
    }

    static func screen(for state: IdentityState) -> Screen {
        switch state {
        case .loading, .ready:
            return Screen(title: "", message: "", detail: nil, showsRestore: false, showsAccept: false)
        case let .unavailable(reason):
            return unavailable(reason)
        case let .missing(expected):
            if let expected {
                return Screen(
                    title: "Identity key missing",
                    message: "Your conversations are here, but your identity key isn't. This happens after restoring from an unencrypted backup. Restore it from an identity backup.",
                    detail: "Expected ID: \(shortID(expected))",
                    showsRestore: true, showsAccept: false)
            }
            return Screen(
                title: "Identity key missing",
                message: "Your conversations are here, but your identity key isn't. Restore isn't possible: this device has no record of which identity your conversations used.",
                detail: nil, showsRestore: false, showsAccept: false)
        case let .identityChanged(expected, got):
            return Screen(
                title: "Identity changed",
                message: "The identity on this device is different from the one your conversations used.",
                detail: "Expected \(shortID(expected)), found \(shortID(got)).",
                showsRestore: false, showsAccept: true)
        }
    }

    static func unavailable(_ reason: IdentityFailureReason) -> Screen {
        switch reason {
        case .locked:
            return Screen(title: "Identity locked", message: "Your identity is locked. Unlock your device, then tap Retry.", detail: nil, showsRestore: false, showsAccept: false)
        case let .strayItem(detail):
            return Screen(title: "Unexpected identity item", message: "Another Reticulum identity item is in an unexpected place on this device. ReTiCaMsgr won't guess which one to use.", detail: detail, showsRestore: false, showsAccept: false)
        case .corrupt:
            return Screen(title: "Identity unreadable", message: "The identity stored on this device can't be read.", detail: "The stored item is not a 64-byte identity.", showsRestore: false, showsAccept: false)
        case .accessDenied:
            return Screen(title: "Identity access denied", message: "ReTiCaMsgr isn't allowed to read the identity. This is a signing or configuration problem, not your data.", detail: "errSecMissingEntitlement (-34018): check the keychain-access-groups entitlement and the team prefix.", showsRestore: false, showsAccept: false)
        case let .other(status):
            return Screen(title: "Identity unavailable", message: "Your identity couldn't be loaded.", detail: status.map { "OSStatus \($0)" } ?? "No status was reported.", showsRestore: false, showsAccept: false)
        }
    }

    static let acceptConfirmation = "Your existing conversations were sent from the old identity. Peers will see you as a new address."

    static func restore(_ result: RestoreResult) -> String? {
        switch result {
        case .restored:
            return nil
        case let .rejected(rejection):
            switch rejection {
            case .badEncoding: return "That isn't an identity backup. Paste the text form or choose the identity file."
            case let .wrongLength(n): return "That file is \(n) bytes; an identity is 64."
            case .invalidKey: return "That key can't form an identity."
            case let .mismatch(got, expected): return "That backup is identity \(shortID(got)), but your conversations belong to \(shortID(expected))."
            case .noExpectedIdentity: return "Restore isn't possible: this device has no record of which identity your conversations used."
            }
        case .refused(.identityPresent):
            return "Another Reticulum identity already exists on this device, so ReTiCaMsgr won't replace it. Nothing was changed."
        case .refused(.notMissing):
            return nil
        case let .failed(reason):
            return unavailable(reason).message
        }
    }
}
