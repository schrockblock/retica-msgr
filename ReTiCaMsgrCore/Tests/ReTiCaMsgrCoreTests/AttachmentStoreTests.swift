import Testing
import Foundation
import struct ReTiCaMsgrCore.Attachment
@testable import ReTiCaMsgrCore

private func tempStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "attachStoreTests-\(UUID().uuidString)"))
}

private let hash64 = String(repeating: "ab", count: 32)

/// Review Focus 2: the file name is the message hash plus the direction, never the peer's name,
/// so a hostile name cannot pick the path. An incoming and an outgoing row can share a hash.
@Test func attachStoreNamesFilesByHashAndDirection() {
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: true, ext: "jpeg") == "\(hash64)-out.jpeg")
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: false, ext: "pdf") == "\(hash64)-in.pdf")
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: false, ext: "") == "\(hash64)-in")
    // The extension is sanitised on the way in: no dots, no separators, no case, at most 8 chars.
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: true, ext: "../etc") == "\(hash64)-out")
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: true, ext: ".JPG") == "\(hash64)-out.jpg")
}

@Test func attachStoreSanitisesExtensions() {
    #expect(AttachmentStore.sanitizedExtension("jpeg") == "jpeg")
    #expect(AttachmentStore.sanitizedExtension(".PNG") == "png")
    #expect(AttachmentStore.sanitizedExtension("tar.gz") == "")
    #expect(AttachmentStore.sanitizedExtension("a/b") == "")
    #expect(AttachmentStore.sanitizedExtension("") == "")
    #expect(AttachmentStore.sanitizedExtension("toolongext") == "")   // 10 chars
    #expect(AttachmentStore.sanitizedExtension("mp4") == "mp4")
}

@Test func attachStoreWritesReadsAndDeletes() throws {
    let store = tempStore()
    let bytes = Data([1, 2, 3, 4])
    let path = try store.store(bytes, messageHash: hash64, outgoing: false, ext: "bin")
    #expect(path == "\(hash64)-in.bin")
    #expect(store.exists(path))
    #expect(try Data(contentsOf: store.url(forRelativePath: path)) == bytes)
    try store.delete(path)
    #expect(!store.exists(path))
    // Deleting again is not an error (idempotent cleanup).
    try store.delete(path)
}

@Test func attachStoreOverwritesTheSameNameAtomically() throws {
    let store = tempStore()
    _ = try store.store(Data([9]), messageHash: hash64, outgoing: true, ext: "jpeg")
    let path = try store.store(Data([7, 7]), messageHash: hash64, outgoing: true, ext: "jpeg")
    #expect(try Data(contentsOf: store.url(forRelativePath: path)) == Data([7, 7]))
    let listing = try FileManager.default.contentsOfDirectory(atPath: store.baseDirectory.path())
    #expect(listing == ["\(hash64)-out.jpeg"])   // no temp files left behind
}

@Test func attachStoreCreatesTheDirectoryAndExcludesItFromBackup() throws {
    let store = tempStore()
    #expect(!FileManager.default.fileExists(atPath: store.baseDirectory.path()))
    _ = try store.store(Data([1]), messageHash: hash64, outgoing: true, ext: "")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: store.baseDirectory.path(), isDirectory: &isDir))
    #expect(isDir.boolValue)
    let values = try store.baseDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
}

@Test func attachStoreURLForAttachmentIsNilWhenPathIsEmpty() {
    let store = tempStore()
    let withBytes = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a", format: "",
                               size: 1, width: nil, height: nil, path: "\(hash64)-in")
    let without = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a", format: "",
                             size: 1, width: nil, height: nil, path: "")
    #expect(store.url(for: withBytes) == store.baseDirectory.appending(path: "\(hash64)-in"))
    #expect(store.url(for: without) == nil)
}

/// Review Focus 4: a base directory that cannot be created (its parent is a regular file)
/// surfaces as a thrown error, which `AppFeature` turns into "attachment unavailable".
@Test func attachStoreWriteFailureThrows() throws {
    let blocker = FileManager.default.temporaryDirectory.appending(path: "attachStoreBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let store = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    #expect(throws: (any Error).self) {
        try store.store(Data([1]), messageHash: hash64, outgoing: false, ext: "")
    }
}

/// Each access to the test dependency is a fresh, isolated directory.
@Test func attachStoreTestValueIsIsolated() {
    let a = AttachmentStore.testValue
    let b = AttachmentStore.testValue
    #expect(a.baseDirectory != b.baseDirectory)
    #expect(a.baseDirectory.path().contains("ReTiCaMsgrTests-Attachments"))
}

/// The share sheet and QuickLook get the attachment's real name, not the hash-named stored file,
/// and a second export replaces the first copy instead of failing.
@Test func attachStoreExportURLUsesTheRealName() throws {
    let store = tempStore()
    let path = try store.store(Data([5, 6]), messageHash: hash64, outgoing: false, ext: "pdf")
    let a = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "Trail map.pdf",
                       format: "pdf", size: 2, width: nil, height: nil, path: path)
    let url = try store.exportURL(for: a)
    #expect(url.lastPathComponent == "Trail map.pdf")
    #expect(url.deletingLastPathComponent().lastPathComponent == a.id.uuidString)
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "AttachmentExports")
    #expect(try Data(contentsOf: url) == Data([5, 6]))
    // The stored file stays where it was.
    #expect(store.exists(path))
    let again = try store.exportURL(for: a)
    #expect(again == url)
    #expect(try Data(contentsOf: again) == Data([5, 6]))
}

/// A row with no bytes has nothing to export.
@Test func attachStoreExportURLThrowsWithoutBytes() {
    let store = tempStore()
    let without = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a.pdf", format: "pdf",
                             size: 1, width: nil, height: nil, path: "")
    #expect(throws: AttachmentStore.ExportError.noBytes) {
        try store.exportURL(for: without)
    }
}

/// Attachment names that attempt path escape are rejected.
@Test func attachStoreExportRefusesAPathEscapingName() throws {
    let store = tempStore()
    let path = try store.store(Data([1, 2]), messageHash: hash64, outgoing: false, ext: "pdf")

    let escapingNames = ["../../escaped.txt", "sub/evil.txt", "..", "."]
    for escapingName in escapingNames {
        let a = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: escapingName,
                          format: "pdf", size: 2, width: nil, height: nil, path: path)
        #expect(throws: AttachmentStore.ExportError.invalidName) {
            try store.exportURL(for: a)
        }
    }
}

/// Files with names containing special characters like spaces work correctly.
@Test func attachStoreDeleteAndExistsHandleNamesNeedingPercentEncoding() throws {
    let store = tempStore()
    // Create the directory first with a normal store call
    _ = try store.store(Data([1]), messageHash: hash64, outgoing: true, ext: "bin")

    // Write a file directly with a space in the name
    let fileURL = store.url(forRelativePath: "with space.bin")
    try Data([9, 8, 7]).write(to: fileURL)

    // Verify it exists
    #expect(store.exists("with space.bin"))

    // Delete it
    try store.delete("with space.bin")

    // Verify it's gone
    #expect(!store.exists("with space.bin"))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

/// Backup exclusion is set even for pre-existing directories.
@Test func attachStoreSetsBackupExclusionOnAnExistingDirectory() throws {
    let dirURL = FileManager.default.temporaryDirectory
        .appending(path: "attachStorePreExisting-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    // Verify the directory exists but isExcludedFromBackup is not yet set
    var values = try dirURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == false)

    // Create a store using the pre-existing directory
    let store = AttachmentStore(baseDirectory: dirURL)
    _ = try store.store(Data([5]), messageHash: hash64, outgoing: false, ext: "bin")

    // Now verify the flag is set
    values = try dirURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
}
