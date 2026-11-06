import Foundation
import ComposableArchitecture

/// The JPEG files behind profile pictures: mine (`me.jpg`) and each peer's (`<peerHex>-<version>.jpg`).
/// File names are built from validated hex and versions, never from peer-supplied names.
public struct AvatarStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public var myPhotoURL: URL { baseDirectory.appending(path: "me.jpg") }

    public func storeMine(_ jpeg: Data) throws {
        try ensureDirectory()
        try write(jpeg, to: myPhotoURL)
    }

    /// nil when I have no photo.
    public func mine() -> Data? {
        try? Data(contentsOf: myPhotoURL)
    }

    public func deleteMine() throws {
        try remove(myPhotoURL)
    }

    /// Writes the peer's JPEG and returns the RELATIVE path to store in `PeerProfile.photoPath`.
    public func storePeer(_ jpeg: Data, peerHex: String, version: String) throws -> String {
        try ensureDirectory()
        let name = "\(peerHex)-\(version).jpg"
        try write(jpeg, to: url(forRelativePath: name))
        return name
    }

    public func url(forRelativePath path: String) -> URL {
        baseDirectory.appending(path: path)
    }

    /// Whether the file at a stored relative path is on disk.
    public func hasFile(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path)
    }

    /// Removes the file; a missing file is not an error.
    public func delete(_ relativePath: String) throws {
        try remove(url(forRelativePath: relativePath))
    }

    private func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: baseDirectory.path, isDirectory: &isDir) || !isDir.boolValue {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = baseDirectory
        try dir.setResourceValues(values)
    }
}

extension AvatarStore: DependencyKey {
    /// `<Application Support>/Avatars`.
    public static var liveValue: AvatarStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AvatarStore(baseDirectory: support.appending(path: "Avatars"))
    }

    /// A fresh temporary directory on every access, so tests never share files.
    public static var testValue: AvatarStore {
        AvatarStore(baseDirectory: FileManager.default.temporaryDirectory
            .appending(path: "ReTiCAMsgrTests-Avatars-\(UUID().uuidString)"))
    }
}

extension DependencyValues {
    public var avatarStore: AvatarStore {
        get { self[AvatarStore.self] }
        set { self[AvatarStore.self] = newValue }
    }
}
