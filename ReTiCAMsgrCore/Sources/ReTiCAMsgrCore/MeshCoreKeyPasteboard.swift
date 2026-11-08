import Foundation
import Dependencies

/// Puts the MeshCore channel key on the pasteboard (Settings' Copy button). The key arrives inside a
/// `MeshCoreKeyText` and is revealed only by the app's live implementation, which `AppRuntime` installs:
/// the package can't reach UIKit or AppKit. On iOS that copy is local-only and expires (ruling R8).
public struct MeshCoreKeyPasteboard: Sendable {
    public var copy: @Sendable (MeshCoreKeyText) -> Void

    public init(copy: @escaping @Sendable (MeshCoreKeyText) -> Void) {
        self.copy = copy
    }
}

extension MeshCoreKeyPasteboard: DependencyKey {
    /// Does nothing: the app installs the real pasteboard in `AppRuntime`.
    public static var liveValue: MeshCoreKeyPasteboard { MeshCoreKeyPasteboard { _ in } }
    /// Does nothing, so a test that never sets it can't fail on a copy.
    public static var testValue: MeshCoreKeyPasteboard { MeshCoreKeyPasteboard { _ in } }
}

public extension DependencyValues {
    var meshCoreKeyPasteboard: MeshCoreKeyPasteboard {
        get { self[MeshCoreKeyPasteboard.self] }
        set { self[MeshCoreKeyPasteboard.self] = newValue }
    }
}
