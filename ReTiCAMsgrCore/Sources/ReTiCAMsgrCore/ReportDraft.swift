import Foundation

/// Where reports go (spec 2026-10-15, decisions). Filled in by hand before launch; must match the
/// support contact published in App Store Connect. While empty the Report actions stay hidden.
public enum SupportContact {
    public static let reportAddress = ""
}

/// First 4 + … + last 2 of a hex address, the view's `shortHex` for Core's use.
public func shortHexForReport(_ hex: String) -> String {
    guard hex.count > 8 else { return hex }
    return "\(hex.prefix(4))…\(hex.suffix(2))"
}

/// What the mail composer is handed (spec §3 "Report flow"). Built by `compose` from the database,
/// shown in full to the user, who edits and sends it, or not. The app never sends it itself.
public struct ReportDraft: Equatable, Sendable, Identifiable {
    public static let maxMessages = 20

    public var peerHex: String
    public var recipient: String
    public var subject: String
    public var body: String
    public var id: String { peerHex }

    public init(peerHex: String, recipient: String, subject: String, body: String) {
        self.peerHex = peerHex
        self.recipient = recipient
        self.subject = subject
        self.body = body
    }

    /// `messages`: rows for `peerHex` in any order; outgoing rows are dropped here so callers
    /// can hand over a whole thread. `attachmentNames`: message id → attachment filename.
    public static func compose(peerHex: String, announcedName: String?, messages: [Message],
                               attachmentNames: [UUID: String], composedAt: Date) -> ReportDraft {
        let iso = ISO8601DateFormatter()
        let recent = messages
            .filter { !$0.isOutgoing }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxMessages)
        var lines: [String] = []
        lines.append("Reported address: \(peerHex)")
        lines.append("Announced name: \(announcedName ?? "(none)")")
        lines.append("Reported from ReTiCAMsgr on \(iso.string(from: composedAt)).")
        lines.append("")
        lines.append("Recent messages from this address (newest first, up to \(maxMessages)):")
        lines.append("")
        if recent.isEmpty {
            lines.append("(no messages stored)")
        }
        for m in recent {
            var text = m.body
            if let name = attachmentNames[m.id] {
                text = text.isEmpty ? "(attachment: \(name))" : "(attachment: \(name)) \(text)"
            }
            lines.append("[\(iso.string(from: m.timestamp))] \(text)")
        }
        lines.append("")
        lines.append("This report was composed by the app from messages stored on this device. "
                     + "Edit it before sending if you wish.")
        return ReportDraft(peerHex: peerHex, recipient: SupportContact.reportAddress,
                           subject: "Report: \(shortHexForReport(peerHex))",
                           body: lines.joined(separator: "\n"))
    }
}
