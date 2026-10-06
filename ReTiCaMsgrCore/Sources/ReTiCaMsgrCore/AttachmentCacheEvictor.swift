import Foundation
import ComposableArchitecture

/// Drops decoded images of purged attachments from whatever in-memory cache the app keeps
/// (amendment A17). The core package has no image cache of its own, so the live value is a no-op
/// and `AppRuntime` installs one that reaches the app's thumbnail cache. The purge calls it with
/// the ids of the attachment rows it deleted.
public struct AttachmentCacheEvictor: Sendable {
    public var evict: @Sendable ([UUID]) async -> Void

    public init(evict: @escaping @Sendable ([UUID]) async -> Void) {
        self.evict = evict
    }
}

extension AttachmentCacheEvictor: DependencyKey {
    public static let liveValue = AttachmentCacheEvictor { _ in }
    public static let testValue = AttachmentCacheEvictor { _ in }
}

extension DependencyValues {
    public var attachmentCacheEvictor: AttachmentCacheEvictor {
        get { self[AttachmentCacheEvictor.self] }
        set { self[AttachmentCacheEvictor.self] = newValue }
    }
}
