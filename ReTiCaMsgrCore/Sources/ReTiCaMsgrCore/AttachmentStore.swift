import Foundation
import ComposableArchitecture

/// The bytes of every attachment (spec 2026-09-28 §1). One directory, one file per attachment,
/// named by the message hash and the direction — never by anything a peer sent — so a hostile
/// file name cannot choose a path. Everything else in the app goes through this type; nothing
/// else touches `FileManager` for attachments.
public struct AttachmentStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// `<hash>-<in|out>[.<ext>]`. The extension is sanitised (`sanitizedExtension`) so a
    /// separator or a dot in it cannot turn the name into a path.
    public static func fileName(messageHash: String, outgoing: Bool, ext: String) -> String {
        let clean = sanitizedExtension(ext)
        let stem = "\(messageHash)-\(outgoing ? "out" : "in")"
        return clean.isEmpty ? stem : "\(stem).\(clean)"
    }

    /// Lowercase, without a leading dot, `[a-z0-9]{1,8}`; anything else is `""` (no extension).
    public static func sanitizedExtension(_ ext: String) -> String {
        var s = ext.lowercased()
        if s.hasPrefix(".") { s.removeFirst() }
        guard (1...8).contains(s.count),
              s.allSatisfy({ ($0.isASCII && $0.isLetter) || ($0.isASCII && $0.isNumber) })
        else { return "" }
        return s
    }

    /// Writes the bytes and returns the RELATIVE path (the file name) to store in the row.
    /// Creates the directory on first use, marks it excluded from backup, writes atomically, and
    /// on iOS with the same file protection class as the SQLite file
    /// (`completeUntilFirstUserAuthentication`): BLE runs in the background, and an attachment
    /// received while the phone is locked must still be writable.
    public func store(_ bytes: Data, messageHash: String, outgoing: Bool, ext: String) throws -> String {
        try ensureDirectory()
        let name = Self.fileName(messageHash: messageHash, outgoing: outgoing, ext: ext)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try bytes.write(to: baseDirectory.appending(path: name), options: options)
        return name
    }

    public func url(forRelativePath path: String) -> URL {
        baseDirectory.appending(path: path)
    }

    /// nil when the row has no bytes (`path == ""`).
    public func url(for attachment: Attachment) -> URL? {
        attachment.hasBytes ? url(forRelativePath: attachment.path) : nil
    }

    public func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path())
    }

    /// Removes the file; a missing file is not an error.
    public func delete(_ relativePath: String) throws {
        let url = url(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path()) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public enum ExportError: Error, Equatable {
        /// The row has no bytes (`path == ""`).
        case noBytes
    }

    /// Where shareable copies go. The system purges the temporary directory on its own.
    public var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "AttachmentExports")
    }

    /// A copy of the bytes under the attachment's own name, for the share sheet and QuickLook:
    /// the stored file is named by hash, so sharing it directly would hand the recipient
    /// `<hash>-in.pdf` (and a file with no extension would preview as unknown). The name is safe
    /// to use as a path component: `AttachmentWire` and `AttachmentPreparation` sanitise every
    /// name before a row exists. An earlier copy is replaced.
    public func exportURL(for attachment: Attachment) throws -> URL {
        guard let source = url(for: attachment) else { throw ExportError.noBytes }
        let directory = exportDirectory.appending(path: attachment.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: attachment.name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: baseDirectory.path(), isDirectory: &isDir), isDir.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = baseDirectory
        try dir.setResourceValues(values)
    }
}

extension AttachmentStore: DependencyKey {
    /// `<Application Support>/Attachments`, beside nothing else the app writes there today.
    public static var liveValue: AttachmentStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AttachmentStore(baseDirectory: support.appending(path: "Attachments"))
    }

    /// A fresh temporary directory on every access, so tests never share files. A test that must
    /// read back what a reducer wrote builds one store, injects it, and keeps the reference.
    public static var testValue: AttachmentStore {
        AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
            .appending(path: "ReTiCaMsgrTests-Attachments-\(UUID().uuidString)"))
    }
}

extension DependencyValues {
    public var attachmentStore: AttachmentStore {
        get { self[AttachmentStore.self] }
        set { self[AttachmentStore.self] = newValue }
    }
}
