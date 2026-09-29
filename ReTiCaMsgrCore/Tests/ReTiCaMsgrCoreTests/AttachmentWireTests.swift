import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let imageBytes = Data([0x01, 0x02])
private let fileBytes = Data("hi".utf8)

private func imageField(_ format: MsgPackValue, _ data: MsgPackValue = .bin(imageBytes)) -> [MsgPackValue.IntPair] {
    [.init(0x06, .array([format, data]))]
}

private func fileField(_ entries: [MsgPackValue]) -> [MsgPackValue.IntPair] {
    [.init(0x05, .array(entries))]
}

@Test func attachWireConstantsMatchReferenceLXMF() {
    #expect(AttachmentWire.fieldFileAttachments == 0x05)
    #expect(AttachmentWire.fieldImage == 0x06)
    #expect(AttachmentWire.sentImageFormat == "jpeg")
    #expect(AttachmentWire.imageFormats == ["jpeg", "png", "webp", "heic"])
    #expect(AttachmentWire.maxNameBytes == 255)
}

/// umsgpack `packb({0x06: ["jpeg", b"\x01\x02"]})`: fixmap(1), 0x06, fixarray(2), fixstr "jpeg", bin8 2 bytes.
@Test func attachWireEncodeImageMatchesReferenceUmsgpackBytes() throws {
    let expected = try #require(Data(hexString: "810692a46a706567c4020102"))
    #expect(MsgPack.encode(.intMap(AttachmentWire.encodeImage(imageBytes))) == expected)
}

/// umsgpack `packb({0x05: [["a.txt", b"hi"]]})`: fixmap(1), 0x05, fixarray(1), fixarray(2), fixstr "a.txt", bin8 "hi".
@Test func attachWireEncodeFileMatchesReferenceUmsgpackBytes() throws {
    let expected = try #require(Data(hexString: "810591 92a5612e747874c4026869".replacingOccurrences(of: " ", with: "")))
    #expect(MsgPack.encode(.intMap(AttachmentWire.encodeFile(name: "a.txt", data: fileBytes))) == expected)
}

@Test func attachWireRoundTripsThroughRealLXMessage() throws {
    let replyTo = Data((0..<32).map { UInt8($0) })
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("caption".utf8),
        fields: AttachmentWire.encodeImage(imageBytes) + ReplyWire.encode(replyTo: replyTo, quote: "q")
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.fields.map(\.key) == [0x06, 0x30, 0x31])
    let decoded = try #require(AttachmentWire.decode(back.fields))
    #expect(decoded == AttachmentWire.Decoded(kind: "image", name: "image.jpeg", format: "jpeg", data: imageBytes))
    #expect(ReplyWire.decode(back.fields)?.replyTo == replyTo)

    let file = LXMessage.create(
        source: Identity(), destinationHash: Data(repeating: 0x11, count: 16), timestamp: 1700000001,
        title: Data(), content: Data(), fields: AttachmentWire.encodeFile(name: "notes.pdf", data: fileBytes))
    let fileBack = try #require(LXMessage.unpack(file.packed))
    #expect(AttachmentWire.decode(fileBack.fields)
            == AttachmentWire.Decoded(kind: "file", name: "notes.pdf", format: "pdf", data: fileBytes))
}

/// Review Focus 1: Sideband writes the format as the file extension it had (`jpg`, `webp`, `png`),
/// other clients may upper-case it, add a dot, say `heif`, or send it as bin.
@Test func attachWireDecodesSidebandFormatVariants() {
    let cases: [(MsgPackValue, String)] = [
        (.string("jpg"), "jpeg"), (.string("JPEG"), "jpeg"), (.string("webp"), "webp"),
        (.string(".png"), "png"), (.string("heif"), "heic"), (.string(" HEIC "), "heic"),
        (.bin(Data("webp".utf8)), "webp"),
    ]
    for (format, expected) in cases {
        let decoded = AttachmentWire.decode(imageField(format))
        #expect(decoded?.kind == "image", "\(format)")
        #expect(decoded?.format == expected, "\(format)")
        #expect(decoded?.name == "image.\(expected)", "\(format)")
        #expect(decoded?.data == imageBytes, "\(format)")
    }
}

/// A bin name for a file entry is accepted too (strict UTF-8); invalid UTF-8 is malformed.
@Test func attachWireAcceptsBinNamesAndRejectsInvalidUTF8() {
    let asBin = AttachmentWire.decode(fileField([.array([.bin(Data("r.txt".utf8)), .bin(fileBytes)])]))
    #expect(asBin == AttachmentWire.Decoded(kind: "file", name: "r.txt", format: "txt", data: fileBytes))
    #expect(AttachmentWire.decode(fileField([.array([.bin(Data([0xFF, 0xFE])), .bin(fileBytes)])])) == nil)
    #expect(AttachmentWire.decode(imageField(.bin(Data([0xFF, 0xFE])))) == nil)
}

/// Review Focus 1: an image we cannot name is kept as a file, never dropped.
@Test func attachWireUnknownImageFormatBecomesAFile() {
    let tiff = AttachmentWire.decode(imageField(.string("tiff")))
    #expect(tiff == AttachmentWire.Decoded(kind: "file", name: "image.tiff", format: "tiff", data: imageBytes))
    let hostile = AttachmentWire.decode(imageField(.string("../x")))
    #expect(hostile == AttachmentWire.Decoded(kind: "file", name: "image", format: "", data: imageBytes))
}

@Test func attachWireImageWinsOverFiles() {
    let fields = fileField([.array([.string("a.txt"), .bin(fileBytes)])]) + imageField(.string("png"))
    #expect(AttachmentWire.decode(fields)?.kind == "image")
    #expect(AttachmentWire.decode(fields)?.format == "png")
    // The file beside it is dropped, and counted so the receiver can log it.
    #expect(AttachmentWire.decode(fields)?.droppedFileCount == 1)
    #expect(AttachmentWire.decode(imageField(.string("png")))?.droppedFileCount == 0)
}

@Test func attachWireFirstFileEntryWins() {
    let fields = fileField([
        .array([.string("first.txt"), .bin(Data("1".utf8))]),
        .array([.string("second.txt"), .bin(Data("2".utf8))]),
    ])
    #expect(AttachmentWire.decode(fields)?.name == "first.txt")
    #expect(AttachmentWire.decode(fields)?.data == Data("1".utf8))
    #expect(AttachmentWire.decode(fields)?.droppedFileCount == 1)
}

/// Review Focus 2: a peer's file name never becomes a path and never breaks the row.
@Test func attachWireSanitisesFileNames() {
    #expect(AttachmentWire.sanitizedFileName("../../etc/passwd") == "_.._etc_passwd")
    #expect(AttachmentWire.sanitizedFileName("C:\\Users\\me\\a.doc") == "C__Users_me_a.doc")
    #expect(AttachmentWire.sanitizedFileName(".hidden") == "hidden")
    #expect(AttachmentWire.sanitizedFileName("   ") == "file")
    #expect(AttachmentWire.sanitizedFileName("") == "file")
    #expect(AttachmentWire.sanitizedFileName("nul\u{0}byte.txt") == "nul_byte.txt")
    // Bidi and zero-width format characters cannot disguise a name (U+202E, U+200B).
    #expect(AttachmentWire.sanitizedFileName("invoice\u{202E}fdp.exe") == "invoice_fdp.exe")
    #expect(AttachmentWire.sanitizedFileName("zero\u{200B}width.txt") == "zero_width.txt")
    let long = String(repeating: "a", count: 300) + ".pdf"
    let cut = AttachmentWire.sanitizedFileName(long)
    #expect(cut.utf8.count == 255)
    #expect(cut == String(repeating: "a", count: 255))
    // The extension comes from the SANITISED name: the cut one has none.
    #expect(AttachmentWire.fileExtension(cut) == "")
    #expect(AttachmentWire.fileExtension("notes.PDF") == "pdf")
    #expect(AttachmentWire.fileExtension("archive.tar.gz") == "gz")
    #expect(AttachmentWire.fileExtension("noext") == "")
    #expect(AttachmentWire.fileExtension(".bashrc") == "")
    // A wide-character name is cut on a Character boundary, under 255 bytes.
    let families = String(repeating: "👨‍👩‍👧‍👦", count: 12)   // 12 × 25 = 300 bytes
    let cutWide = AttachmentWire.sanitizedFileName(families)
    #expect(cutWide.utf8.count <= 255)
    #expect(cutWide == String(repeating: "👨‍👩‍👧‍👦", count: 10))
    // Decoding applies it.
    let decoded = AttachmentWire.decode(fileField([.array([.string("../evil.sh"), .bin(fileBytes)])]))
    #expect(decoded?.name == "_evil.sh")
    #expect(decoded?.format == "sh")
}

/// Review Focus 3 (codec half): every malformed shape is nil, so the message is stored as text.
@Test func attachWireMalformedShapesAreNil() {
    let cases: [(String, [MsgPackValue.IntPair])] = [
        ("no fields", []),
        ("0x06 not an array", [.init(0x06, .bin(imageBytes))]),
        ("0x06 one element", [.init(0x06, .array([.string("jpeg")]))]),
        ("0x06 three elements", [.init(0x06, .array([.string("jpeg"), .bin(imageBytes), .uint(1)]))]),
        ("0x06 data not bin", imageField(.string("jpeg"), .string("nope"))),
        ("0x06 format not text", imageField(.uint(6))),
        ("0x06 empty bytes", imageField(.string("jpeg"), .bin(Data()))),
        ("0x05 not an array", [.init(0x05, .bin(fileBytes))]),
        ("0x05 empty list", fileField([])),
        ("0x05 entry not a pair", fileField([.string("a.txt")])),
        ("0x05 pair of one", fileField([.array([.string("a.txt")])])),
        ("0x05 data not bin", fileField([.array([.string("a.txt"), .string("x")])])),
        ("0x05 name not text", fileField([.array([.uint(1), .bin(fileBytes)])])),
    ]
    for (name, fields) in cases {
        #expect(AttachmentWire.decode(fields) == nil, "\(name)")
    }
    // An empty FILE is allowed (a zero-byte document is a document).
    let empty = AttachmentWire.decode(fileField([.array([.string("empty.txt"), .bin(Data())])]))
    #expect(empty?.name == "empty.txt")
    #expect(empty?.data.isEmpty == true)
    // A malformed 0x06 beside a good 0x05 falls through to the file.
    let mixed = [MsgPackValue.IntPair(0x06, .bin(imageBytes))] + fileField([.array([.string("ok.txt"), .bin(fileBytes)])])
    #expect(AttachmentWire.decode(mixed)?.name == "ok.txt")
}
