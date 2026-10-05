import Foundation
import SQLiteData

/// A single chat message row. `peerHex` is the other party's lxmf.delivery hash (hex);
/// `messageHash` is the LXMessage.hash (hex) — correlates deliveryFailed for outgoing rows and is
/// the reaction target for all rows.
///
/// The optional fields after `messageHash` are debugging metadata for the Info sheet, added by the
/// `addMessageInfo` migration, then the reply fields, added by `addReplies`, then the disappearing
/// messages fields, added by `addDisappearingMessages`. Rows stored before a migration read back
/// `nil` for its fields.
@Table
public struct Message: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var peerHex: String
    public var isOutgoing: Bool
    public var body: String
    public var timestamp: Date
    public var status: String        // MessageStatus.*
    public var validated: Bool       // incoming: signature validated
    public var messageHash: String   // LXMessage.hash hex ("" for incoming rows stored before reactions shipped)

    /// The LXMF timestamp: the sender's clock for incoming rows, the send time for outgoing rows.
    public var senderTimestamp: Date?
    /// Incoming only: ArrivalMethod.*
    public var arrivalMethod: String?
    /// Outgoing only: a propagation node was configured at send, so a PN copy was also sent.
    public var sentViaPropagation: Bool?
    /// Outgoing only: the FIRST time each milestone happened. Never overwritten.
    public var storedAt: Date?
    public var deliveredAt: Date?
    public var failedAt: Date?
    /// Bytes on the wire (incoming: as received; outgoing: as packed before stamping).
    public var wireSize: Int?
    public var titleSize: Int?
    public var contentSize: Int?
    /// Lowercase two-digit hex LXMF field keys in wire order, e.g. "0x02,0xfb". "" when none.
    public var fieldKeys: String?
    /// Incoming only: StampState.*
    public var stampState: String?
    /// Replies (LXMF FIELD_REPLY_TO 0x30): lowercase hex of the original's full LXMF hash.
    /// nil when this message is not a reply.
    public var replyToHash: String?
    /// Replies (LXMF FIELD_REPLY_QUOTE 0x31): the quote as sent or received, already trimmed.
    /// nil when not a reply, or when a received quote was missing or unusable.
    public var replyQuote: String?
    /// Outgoing only: why the message will not go out, beside `status` — `FailureReason.*`.
    /// nil for an ordinary failure (retries exhausted) and for every non-failed row.
    public var failureReason: String?
    /// Outgoing only: the propagated copy was refused up front — `PropagationRefusal.*`.
    /// nil when it was not refused (or no propagation node was configured).
    public var propagationRefused: String?
    /// Disappearing messages: the duration in seconds carried in FIELD_CUSTOM_META (0xFD).
    /// nil when this message never disappears.
    public var expirySeconds: Int?
    /// When the purge deletes this row. Outgoing: set at send. Incoming: set on first view in the
    /// open thread, so nil with a non-nil `expirySeconds` means "not viewed yet".
    public var expiresAt: Date?
    /// A timer-change announcement ("Disappearing messages set to 1 day"): rendered as a system
    /// line, never carries an attachment or reactions, never expires.
    public var isTimerChange: Bool

    public init(
        id: UUID,
        peerHex: String,
        isOutgoing: Bool,
        body: String,
        timestamp: Date,
        status: String,
        validated: Bool,
        messageHash: String,
        senderTimestamp: Date? = nil,
        arrivalMethod: String? = nil,
        sentViaPropagation: Bool? = nil,
        storedAt: Date? = nil,
        deliveredAt: Date? = nil,
        failedAt: Date? = nil,
        wireSize: Int? = nil,
        titleSize: Int? = nil,
        contentSize: Int? = nil,
        fieldKeys: String? = nil,
        stampState: String? = nil,
        replyToHash: String? = nil,
        replyQuote: String? = nil,
        failureReason: String? = nil,
        propagationRefused: String? = nil,
        expirySeconds: Int? = nil,
        expiresAt: Date? = nil,
        isTimerChange: Bool = false
    ) {
        self.id = id
        self.peerHex = peerHex
        self.isOutgoing = isOutgoing
        self.body = body
        self.timestamp = timestamp
        self.status = status
        self.validated = validated
        self.messageHash = messageHash
        self.senderTimestamp = senderTimestamp
        self.arrivalMethod = arrivalMethod
        self.sentViaPropagation = sentViaPropagation
        self.storedAt = storedAt
        self.deliveredAt = deliveredAt
        self.failedAt = failedAt
        self.wireSize = wireSize
        self.titleSize = titleSize
        self.contentSize = contentSize
        self.fieldKeys = fieldKeys
        self.stampState = stampState
        self.replyToHash = replyToHash
        self.replyQuote = replyQuote
        self.failureReason = failureReason
        self.propagationRefused = propagationRefused
        self.expirySeconds = expirySeconds
        self.expiresAt = expiresAt
        self.isTimerChange = isTimerChange
    }
}

public enum MessageStatus {
    public static let sending = "sending"
    public static let sent = "sent"
    public static let failed = "failed"
    public static let received = "received"
    public static let propagated = "stored"
    /// The recipient proved receipt (`deliveryConfirmed`). Beats "stored": a delivered row is
    /// never downgraded by a later `propagationAccepted` or `deliveryFailed`.
    public static let delivered = "delivered"
    /// The user stopped the send (`deliveryCancelled`). Terminal, like `failed`; a cancelled
    /// message is never retried (ReTiCA forbids re-sending a hash — re-attach and send again).
    public static let cancelled = "cancelled"
}

/// How an incoming message reached us (`Message.arrivalMethod`), from ReTiCA's
/// `LXMFRouter.DeliveryMethod`.
public enum ArrivalMethod {
    public static let opportunistic = "opportunistic"
    public static let direct = "direct"
    public static let propagated = "propagated"
}

/// The delivery-stamp state of an incoming message (`Message.stampState`), from `LXMessage`'s
/// `stamp` / `stampChecked` / `stampValid`.
public enum StampState {
    /// No stamp was attached.
    public static let none = "none"
    /// A stamp was attached but no stamp cost is configured, so it was never checked.
    public static let unchecked = "unchecked"
    public static let valid = "valid"
    public static let invalid = "invalid"
}

/// Why an outgoing message ended as `failed`/`cancelled` (`Message.failureReason`).
public enum FailureReason {
    /// The recipient refused the transfer (`deliveryRejected`).
    public static let rejected = "rejected"
    /// The user cancelled the send (`deliveryCancelled`).
    public static let cancelled = "cancelled"
}

/// Why the propagated copy was never sent (`Message.propagationRefused`), from ReTiCA's
/// `LXMFRouter.RefusalReason`.
public enum PropagationRefusal {
    public static let tooLargeForNode = "too large for node"
}
