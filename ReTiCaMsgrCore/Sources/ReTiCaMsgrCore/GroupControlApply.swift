import Foundation
import GRDB
import SQLiteData

/// The database rules for incoming control messages (spec 2026-10-09 §3 "Receiving", amendments
/// A5, A7): what an applied roster or leave writes, and when a message must instead be stored as
/// the plain one-to-one message its body is, or dropped. Runs inside the reducer's write.
public enum GroupControlApply {
    public enum Outcome: Equatable, Sendable {
        /// Rows were written for `groupHex`. `creatorResends` is true when I am the creator and a
        /// member left, so the reducer fans the new roster out (amendment A7).
        case applied(groupHex: String, creatorResends: Bool)
        /// Not applicable but harmless (a stale roster from the real creator): seen hash only.
        case dropped
        /// Not a valid control message for this device: store it as a plain message.
        case plainMessage
    }

    /// Who is who, resolved by the reducer before the write (display names live in state).
    public struct Names: Equatable, Sendable {
        public var me: String
        /// The sender's name as a line should show it.
        public var sender: String
        /// Announce display names of the roster's members, by address.
        public var byHex: [String: String]

        public init(me: String, sender: String, byHex: [String: String]) {
            self.me = me
            self.sender = sender
            self.byHex = byHex
        }

        public func name(_ hex: String) -> String {
            if hex == me { return GroupEventText.you }
            return byHex[hex] ?? GroupEventText.fallbackName(hex)
        }
    }

    /// A roster from `senderHex`. The first roster for an id establishes its creator (spec §1);
    /// later ones must come from that creator with a higher revision; one that does not list its
    /// sender, or that does not list me for a group I do not have, is a plain message; a stale
    /// one from the real creator is dropped (amendment A5).
    public static func applyRoster(groupHex: String, name: String, members: [String], revision: Int,
                                   from senderHex: String, names: Names, validated: Bool, now: Date,
                                   _ db: GRDB.Database) throws -> Outcome {
        guard members.isEmpty || members.contains(senderHex) else { return .plainMessage }   // Review Focus 2
        let stored = try ChatGroup.fetch(groupHex, db)
        let iAmListed = members.contains(names.me)
        if stored == nil, !iAmListed { return .plainMessage }
        guard GroupRoster.applies(revision: revision, from: senderHex, to: stored) else {
            return stored?.creatorHex == senderHex ? .dropped : .plainMessage
        }
        let oldMembers = stored == nil ? [] : try GroupMember.members(of: groupHex, db)
        let diff = GroupRoster.diff(oldMembers: oldMembers, oldName: stored?.name ?? name,
                                    newMembers: members, newName: name)
        let wasOut = stored == nil || stored?.state == GroupState.left
        let newState: String
        if diff.dissolved {
            newState = GroupState.dissolved
        } else if !iAmListed {
            newState = GroupState.left
        } else if wasOut {
            newState = GroupState.invited
        } else {
            newState = stored?.state ?? GroupState.invited
        }
        var lines: [String] = []
        if diff.dissolved {
            lines = [GroupEventText.deleted(by: names.sender)]
        } else if wasOut && iAmListed {
            lines = [GroupEventText.invited(by: names.sender, name: name)]
        } else {
            for hex in diff.added where hex != names.me {
                lines.append(GroupEventText.added(by: names.sender, who: names.name(hex)))
            }
            for hex in diff.removed {
                lines.append(hex == names.me
                    ? GroupEventText.removedYou(by: names.sender)
                    : GroupEventText.removed(by: names.sender, who: names.name(hex)))
            }
            if let newName = diff.renamed {
                lines.append(GroupEventText.renamed(by: names.sender, to: newName))
            }
        }
        let group = ChatGroup(groupHex: groupHex, name: name, creatorHex: stored?.creatorHex ?? senderHex,
                              revision: revision, state: newState, updatedAt: now)
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHex, with: diff.dissolved ? [] : members, db)
        // 1 ms apart so the lines sort in the order the diff names them.
        for (offset, line) in lines.enumerated() {
            try Message.insert {
                Message(id: UUID(), peerHex: senderHex, isOutgoing: false, body: line,
                        timestamp: now.addingTimeInterval(Double(offset) * 0.001),
                        status: MessageStatus.received, validated: validated, messageHash: "",
                        fieldKeys: "", groupHex: groupHex, isGroupEvent: true)
            }.execute(db)
        }
        return .applied(groupHex: groupHex, creatorResends: false)
    }

    /// A leave from `senderHex`: a current member of a known open group is removed with a line.
    /// When I am the creator, the line is mine and carries the bumped roster to the remaining
    /// members through waiting delivery rows (amendment A7).
    public static func applyLeave(groupHex: String, from senderHex: String, names: Names, validated: Bool,
                                  now: Date, _ db: GRDB.Database) throws -> Outcome {
        guard let stored = try ChatGroup.fetch(groupHex, db), stored.isOpen, senderHex != names.me,
              try GroupMember.contains(groupHex, senderHex, db)
        else { return .plainMessage }
        try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(senderHex) }.delete().execute(db)
        guard stored.creatorHex == names.me else {
            try Message.insert {
                Message(id: UUID(), peerHex: senderHex, isOutgoing: false, body: GroupEventText.left(who: names.sender),
                        timestamp: now, status: MessageStatus.received, validated: validated, messageHash: "",
                        fieldKeys: "", groupHex: groupHex, isGroupEvent: true)
            }.execute(db)
            return .applied(groupHex: groupHex, creatorResends: false)
        }
        var group = stored
        group.revision += 1
        group.updatedAt = now
        try ChatGroup.upsert(group, db)
        let line = AppFeature.groupEventRow(groupHex: groupHex, me: names.me, body: GroupEventText.left(who: names.sender),
                                            control: GroupControl.roster, now: now)
        try Message.insert { line }.execute(db)
        for member in try GroupMember.members(of: groupHex, db) where member != names.me {
            try GroupDelivery.insert { GroupDelivery.waiting(messageId: line.id, memberHex: member) }.execute(db)
        }
        try GroupDelivery.refreshDerivedStatus(messageId: line.id, db)
        return .applied(groupHex: groupHex, creatorResends: true)
    }
}
