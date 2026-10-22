import Foundation
import ComposableArchitecture

/// Posts a local notification (brief 2026-10-21). The core package has no UserNotifications
/// wiring, so the live value posts nothing and `AppRuntime` installs one over
/// `UNUserNotificationCenter`, which does nothing while notifications aren't authorized and
/// never asks for permission.
public struct LocalNotificationClient: Sendable {
    public var postNotification: @Sendable (_ id: String, _ title: String, _ body: String,
                                            _ threadID: String, _ userInfo: [String: String]) async -> Void

    public init(post: @escaping @Sendable (_ id: String, _ title: String, _ body: String,
                                           _ threadID: String, _ userInfo: [String: String]) async -> Void) {
        self.postNotification = post
    }

    public func post(id: String, title: String, body: String, threadID: String, userInfo: [String: String]) async {
        await postNotification(id, title, body, threadID, userInfo)
    }

    /// One posted notification, as a test records it.
    public struct Posted: Equatable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var threadID: String
        public var userInfo: [String: String]

        public init(id: String, title: String, body: String, threadID: String, userInfo: [String: String]) {
            self.id = id
            self.title = title
            self.body = body
            self.threadID = threadID
            self.userInfo = userInfo
        }
    }

    /// Appends every post to `log`.
    public static func recording(into log: LockIsolated<[Posted]>) -> LocalNotificationClient {
        LocalNotificationClient { id, title, body, threadID, userInfo in
            log.withValue { $0.append(Posted(id: id, title: title, body: body, threadID: threadID, userInfo: userInfo)) }
        }
    }
}

extension LocalNotificationClient: DependencyKey {
    public static let liveValue = LocalNotificationClient { _, _, _, _, _ in }
    /// Records into a log nobody reads, so the many tests that fail a send don't have to say so;
    /// a test that checks posts installs `recording(into:)`.
    public static let testValue = LocalNotificationClient.recording(into: LockIsolated([]))
}

extension DependencyValues {
    public var localNotifications: LocalNotificationClient {
        get { self[LocalNotificationClient.self] }
        set { self[LocalNotificationClient.self] = newValue }
    }
}

/// The local notification for a send that failed while the user wasn't looking at its chat.
/// Privacy first: no name and no message text, and the same id for one conversation, so repeat
/// failures replace one notification instead of stacking.
public enum SendFailedNotification {
    public static let kind = "sendFailed"
    public static let title = "Message not sent"
    public static let body = "Tap to retry."

    /// The request id and thread id for `peerHex` (a peer's address or a group's id).
    public static func id(peerHex: String) -> String { "send-failed-\(peerHex)" }

    public static func userInfo(peerHex: String) -> [String: String] {
        ["kind": kind, "peerHex": peerHex]
    }

    /// The conversation a tapped notification names, or nil when it isn't one of these.
    public static func peerHex(from userInfo: [AnyHashable: Any]) -> String? {
        guard userInfo["kind"] as? String == kind else { return nil }
        return userInfo["peerHex"] as? String
    }
}
