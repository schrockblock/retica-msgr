import Foundation
import ReTiCA

/// Wire codec for group chats (spec 2026-10-09 §1). Everything rides in `FIELD_CUSTOM_META` (0xFD),
/// the string-keyed msgpack map `ExpiryWire` already uses, under two keys: `reticamsgr.group` is an
/// array of one or two 16-byte ids (`[group id, post id]` on a post, `[group id]` on a reaction or
/// control message), and `reticamsgr.group.ctl` is the control map `{a, n, m, r}` on a roster or
/// `{a}` on a leave. Other clients ignore the map and see an ordinary message.
///
/// Received leniently: no 0xFD, a 0xFD that is not a map, no group key, an id of the wrong length,
/// a roster over the caps, an unknown action, all decode as nil ("not a group message"). A
/// malformed field never drops the message. Group sends never carry the expiry key (amendment A9),
/// so the two codecs never have to merge one map.
public enum GroupWire {
    public static let fieldCustomMeta = 0xFD
    public static let groupKey = "reticamsgr.group"
    public static let controlKey = "reticamsgr.group.ctl"
    public static let idLength = 16
    public static let maxNameBytes = 32
    public static let maxMembers = 12
    public static let actionRoster = "roster"
    public static let actionLeave = "leave"
    static let actionKey = "a"
    static let nameKey = "n"
    static let membersKey = "m"
    static let revisionKey = "r"

    public enum Decoded: Equatable, Sendable {
        case post(groupId: Data, postId: Data)
        /// A reaction (or any non-post, non-control message) tagged with its group.
        case marker(groupId: Data)
        case roster(groupId: Data, name: String, members: [Data], revision: Int)
        case leave(groupId: Data)
    }

    /// 16 random bytes: a group id at creation, a post id at send.
    public static func randomId() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<idLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Whitespace trimmed, then at most `maxNameBytes` of UTF-8, dropping whole Characters from the
    /// end so an emoji sequence is never split.
    public static func trimName(_ name: String) -> String {
        var kept = Substring(name.trimmingCharacters(in: .whitespacesAndNewlines))
        while !kept.isEmpty, kept.utf8.count > maxNameBytes {
            kept = kept.dropLast()
        }
        return String(kept)
    }

    public static func encodePost(groupId: Data, postId: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([.init(groupKey, .array([.bin(groupId), .bin(postId)]))]))]
    }

    public static func encodeMarker(groupId: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([.init(groupKey, .array([.bin(groupId)]))]))]
    }

    /// The full roster every time, the creator included, at most `maxMembers` entries.
    public static func encodeRoster(groupId: Data, name: String, members: [Data], revision: Int) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([
            .init(groupKey, .array([.bin(groupId)])),
            .init(controlKey, .map([
                .init(actionKey, .string(actionRoster)),
                .init(nameKey, .string(trimName(name))),
                .init(membersKey, .array(members.prefix(maxMembers).map { .bin($0) })),
                .init(revisionKey, .uint(UInt64(max(0, revision)))),
            ])),
        ]))]
    }

    public static func encodeLeave(groupId: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([
            .init(groupKey, .array([.bin(groupId)])),
            .init(controlKey, .map([.init(actionKey, .string(actionLeave))])),
        ]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        guard case let .map(pairs)? = fields.first(where: { $0.key == fieldCustomMeta })?.value,
              case let .array(ids)? = pairs.first(where: { $0.key == groupKey })?.value,
              (1...2).contains(ids.count),
              let groupId = id(ids[0])
        else { return nil }
        if ids.count == 2 {
            guard let postId = id(ids[1]) else { return nil }
            return .post(groupId: groupId, postId: postId)
        }
        guard case let .map(control)? = pairs.first(where: { $0.key == controlKey })?.value else {
            return .marker(groupId: groupId)
        }
        guard case let .string(action)? = control.first(where: { $0.key == actionKey })?.value else { return nil }
        switch action {
        case actionLeave:
            return .leave(groupId: groupId)
        case actionRoster:
            guard let name = name(control.first(where: { $0.key == nameKey })?.value),
                  case let .array(rawMembers)? = control.first(where: { $0.key == membersKey })?.value,
                  rawMembers.count <= maxMembers,
                  let revision = revision(control.first(where: { $0.key == revisionKey })?.value)
            else { return nil }
            var members: [Data] = []
            for raw in rawMembers {
                guard let member = id(raw) else { return nil }
                members.append(member)
            }
            return .roster(groupId: groupId, name: name, members: members, revision: revision)
        default:
            return nil
        }
    }

    /// A 16-byte bin, else nil.
    private static func id(_ value: MsgPackValue) -> Data? {
        guard case let .bin(bytes) = value, bytes.count == idLength else { return nil }
        return bytes
    }

    /// `str` or strict-UTF-8 `bin`, within the byte cap.
    private static func name(_ value: MsgPackValue?) -> String? {
        switch value {
        case let .string(s):
            return s.utf8.count <= maxNameBytes ? s : nil
        case let .bin(bytes):
            guard bytes.count <= maxNameBytes else { return nil }
            let text = String(decoding: bytes, as: UTF8.self)
            return Data(text.utf8) == bytes ? text : nil
        default:
            return nil
        }
    }

    /// `uint` or a non-negative `int` tag, within `Int`.
    private static func revision(_ value: MsgPackValue?) -> Int? {
        switch value {
        case let .uint(u): return u <= UInt64(Int.max) ? Int(u) : nil
        case let .int(i): return i >= 0 ? Int(i) : nil
        default: return nil
        }
    }
}
