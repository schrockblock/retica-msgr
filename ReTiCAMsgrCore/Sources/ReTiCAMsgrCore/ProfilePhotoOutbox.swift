import Foundation
import ReTiCA

/// The outbound rule for my profile photo, per outgoing message to one peer. Pure: the caller
/// supplies my version/bytes, the peer's delivery row and whether an image may ride, and writes
/// `pendingVersion` (with the message hash) back through `ProfilePhotoDelivery.markPending`.
public enum ProfilePhotoOutbox {
    public struct Plan: Equatable, Sendable {
        /// Fields to merge into the message; empty when nothing rides.
        public var fields: [MsgPackValue.IntPair]
        /// Set when this message carries the image (or a removal) whose delivery must be tracked.
        /// `""` means a removal is in flight.
        public var pendingVersion: String?

        public init(fields: [MsgPackValue.IntPair] = [], pendingVersion: String? = nil) {
            self.fields = fields
            self.pendingVersion = pendingVersion
        }
    }

    public static func plan(
        myVersion: String, myPhoto: Data?, delivery: ProfilePhotoDelivery?, imageAllowed: Bool
    ) -> Plan {
        if myVersion.isEmpty {
            guard let delivered = delivery?.deliveredVersion, !delivered.isEmpty else { return Plan() }
            return Plan(fields: ProfileWire.encodeRemoved(), pendingVersion: "")
        }
        guard let version = Data(hexString: myVersion) else { return Plan() }
        // The version is captured in the reducer and the bytes read later: a send racing a new
        // pick can read the new bytes. Bytes that are not this version never ride (tag only).
        let matching = myPhoto.flatMap { ProfileWire.version(of: $0) == version ? $0 : nil }
        if imageAllowed, let jpeg = matching,
           delivery?.deliveredVersion != myVersion, delivery?.pendingVersion != myVersion {
            return Plan(
                fields: ProfileWire.encodePhoto(version: version, jpeg: jpeg),
                pendingVersion: myVersion)
        }
        return Plan(fields: ProfileWire.encodeTag(version: version))
    }
}
