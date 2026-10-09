import Foundation

/// The pure group rules (spec 2026-10-09 §3): whether a roster applies, what changed between two
/// rosters, and a post's status derived from its per-member delivery rows (amendment A8).
public enum GroupRoster {
    public struct Diff: Equatable, Sendable {
        public var added: [String]
        public var removed: [String]
        /// The new name when it changed, else nil.
        public var renamed: String?
        /// The new roster is empty: the creator deleted the group.
        public var dissolved: Bool

        public init(added: [String], removed: [String], renamed: String?, dissolved: Bool) {
            self.added = added
            self.removed = removed
            self.renamed = renamed
            self.dissolved = dissolved
        }
    }

    /// Spec §1 receive rules. No stored group: the first roster establishes its creator. A stored
    /// group: only its creator, only a strictly higher revision, and never once dissolved.
    public static func applies(revision: Int, from senderHex: String, to stored: ChatGroup?) -> Bool {
        guard let stored else { return true }
        return stored.creatorHex == senderHex
            && revision > stored.revision
            && stored.state != GroupState.dissolved
    }

    public static func diff(oldMembers: [String], oldName: String, newMembers: [String], newName: String) -> Diff {
        let old = Set(oldMembers)
        let new = Set(newMembers)
        return Diff(added: new.subtracting(old).sorted(),
                    removed: old.subtracting(new).sorted(),
                    renamed: newName == oldName ? nil : newName,
                    dissolved: new.isEmpty)
    }

    /// Amendment A8, in order: `sending` while any copy is waiting or sending; `delivered` when
    /// every copy was proved; `stored` when every copy was proved or stored and at least one was
    /// stored; `failed` when every copy failed or was cancelled; otherwise `sent`. No copies at
    /// all (a group of one) is `sent`.
    public static func derivedStatus(_ rows: [GroupDelivery]) -> String {
        guard !rows.isEmpty else { return MessageStatus.sent }
        let statuses = rows.map(\.status)
        if statuses.contains(where: { $0 == GroupDeliveryStatus.waiting || $0 == MessageStatus.sending }) {
            return MessageStatus.sending
        }
        if statuses.allSatisfy({ $0 == MessageStatus.delivered }) { return MessageStatus.delivered }
        if statuses.allSatisfy({ $0 == MessageStatus.delivered || $0 == MessageStatus.propagated }) {
            return MessageStatus.propagated
        }
        if statuses.allSatisfy({ $0 == MessageStatus.failed || $0 == MessageStatus.cancelled }) {
            return MessageStatus.failed
        }
        return MessageStatus.sent
    }

    /// The bubble's status text (spec §4): "Delivered to d of n" while some but not all members
    /// proved receipt, else the derived status word.
    public static func statusLabel(_ rows: [GroupDelivery]) -> String {
        let delivered = rows.filter { $0.status == MessageStatus.delivered }.count
        if delivered > 0, delivered < rows.count {
            return "Delivered to \(delivered) of \(rows.count)"
        }
        return derivedStatus(rows)
    }
}
