import Foundation

/// The message Info sheet as data: titled sections of (label, display, copy) rows. Pure — all
/// formatting happens here so it can be unit-tested. The SwiftUI sheet only lays rows out.
public enum MessageInfo {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var rows: [Row]
        public var footer: String?

        public init(title: String, rows: [Row], footer: String? = nil) {
            self.title = title
            self.rows = rows
            self.footer = footer
        }
    }

    public struct Row: Equatable, Sendable {
        public var label: String
        public var display: String
        /// What a tap puts on the pasteboard. "" means there is nothing to copy.
        public var copy: String

        public init(label: String, display: String, copy: String) {
            self.label = label
            self.display = display
            self.copy = copy
        }

        /// A row whose copy value is its display text.
        public init(_ label: String, _ display: String) {
            self.init(label: label, display: display, copy: display)
        }
    }

    public static let missing = "—"
    public static let legacyFooter = "Some details weren't recorded for messages from before this feature."

    public static func sections(for message: Message, attachment: Attachment? = nil,
                                deliveries: [GroupDelivery] = [], memberNames: [String: String] = [:],
                                timeZone: TimeZone = .current) -> [Section] {
        // A Delivery section with nothing to say (a group post, see `delivery`) is left out.
        var sections = [timeline(message, timeZone), delivery(message), identity(message), payload(message)]
            .filter { !$0.rows.isEmpty }
        if let attachment {
            sections.append(attachmentSection(attachment))
        }
        if !deliveries.isEmpty {
            sections.append(members(deliveries, names: memberNames, sameDayAs: message.timestamp, timeZone))
        }
        return sections
    }

    // MARK: - Sections

    static func timeline(_ m: Message, _ tz: TimeZone) -> Section {
        var rows: [Row] = []
        if m.isOutgoing {
            rows.append(timeRow("Sent", m.timestamp, sameDayAs: m.timestamp, tz))
            let milestones: [(String, Date?)] = [
                ("Stored on node", m.storedAt),
                ("Delivered", m.deliveredAt),
                ("Failed", m.failedAt),
            ]
            for (label, at) in milestones {
                guard let at else { continue }   // a milestone that never happened is hidden
                let shown = time(at, sameDayAs: m.timestamp, timeZone: tz)
                rows.append(Row(label: label,
                                display: "\(shown) (\(gap(at.timeIntervalSince(m.timestamp))))",
                                copy: iso(at)))
            }
        } else {
            if let written = m.senderTimestamp {
                rows.append(timeRow("Written", written, sameDayAs: m.timestamp, tz))
            } else {
                rows.append(missingRow("Written"))
            }
            rows.append(timeRow("Received", m.timestamp, sameDayAs: m.timestamp, tz))
            if let written = m.senderTimestamp {
                rows.append(Row("Skew", gap(m.timestamp.timeIntervalSince(written))))
            } else {
                rows.append(missingRow("Skew"))
            }
        }
        rows.append(Row("Status", m.status))
        if let reason = m.failureReason {
            rows.append(Row("Reason", failureReasonName(reason)))
        }
        // Disappearing messages (spec §4): when the purge will take this row, or, for a received
        // row not viewed yet, how long after the first view.
        if let at = m.expiresAt {
            rows.append(timeRow("Expires", at, sameDayAs: m.timestamp, tz))
        } else if let seconds = m.expirySeconds {
            rows.append(Row("Disappears after", ExpiryPreset.label(forSeconds: seconds)))
        }
        return Section(title: "Timeline", rows: rows)
    }

    static func delivery(_ m: Message) -> Section {
        var rows: [Row] = []
        if !m.isOutgoing {
            rows.append(optionalRow("Arrival", m.arrivalMethod.map(arrivalName)))
        } else if let viaNode = m.sentViaPropagation {
            rows.append(Row("Propagation node copy", viaNode ? "Yes" : "No"))
        } else if m.fieldKeys == nil {
            // Not recorded before this feature. A recorded row with no value (a group post, whose
            // member copies have their own hashes) has no such row at all.
            rows.append(missingRow("Propagation node copy"))
        }
        if m.isOutgoing, let refusal = m.propagationRefused {
            rows.append(Row("Propagation refusal", "Refused: \(refusal)"))
        }
        return Section(title: "Delivery", rows: rows)
    }

    static func identity(_ m: Message) -> Section {
        let hash = m.messageHash.isEmpty ? missingRow("Message hash") : hashRow("Message hash", m.messageHash)
        let signature = m.isOutgoing ? "n/a" : (m.validated ? "Validated" : "Not validated")
        // Controller ruling P1: the legacy footer keys off `fieldKeys == nil`, not
        // `senderTimestamp == nil`. Every new row sets `fieldKeys`; `senderTimestamp` can still be
        // nil on a new incoming message whose sender clock was rejected, and that must not
        // resurrect the "before this feature" footer.
        return Section(title: "Identity",
                       rows: [hash, hashRow("Peer", m.peerHex), Row("Signature", signature)],
                       footer: m.fieldKeys == nil ? legacyFooter : nil)
    }

    static func payload(_ m: Message) -> Section {
        var rows = [
            optionalRow("Wire size", m.wireSize.map(bytes)),
            optionalRow("Title size", m.titleSize.map(bytes)),
            optionalRow("Content size", m.contentSize.map(bytes)),
        ]
        rows += fieldRows(m.fieldKeys)
        rows.append(m.isOutgoing ? missingRow("Stamp") : optionalRow("Stamp", m.stampState.map(stampName)))
        return Section(title: "Payload", rows: rows)
    }

    static func attachmentSection(_ a: Attachment) -> Section {
        var dimensions: String? = nil
        if let width = a.width, let height = a.height { dimensions = "\(width) × \(height)" }
        return Section(title: "Attachment", rows: [
            Row("Kind", a.isImage ? "Image" : "File"),
            Row("Name", a.name),
            optionalRow("Format", a.format.isEmpty ? nil : a.format.uppercased()),
            Row("Size", bytes(a.size)),
            optionalRow("Dimensions", dimensions),
            Row("Stored", a.hasBytes ? "Yes" : "No"),
        ])
    }

    /// Spec 2026-10-09 §4: one row per member copy of an outgoing group row, sorted by address.
    /// The label is the member's announce name or a short hex, the display the copy's status and
    /// its first proof time once proved, and the copy value the copy's LXMF hash.
    static func members(_ deliveries: [GroupDelivery], names: [String: String], sameDayAs reference: Date,
                        _ tz: TimeZone) -> Section {
        let rows = deliveries.sorted { $0.memberHex < $1.memberHex }.map { d -> Row in
            var display = d.status
            if let at = d.deliveredAt {
                display += " " + time(at, sameDayAs: reference, timeZone: tz)
            }
            return Row(label: names[d.memberHex] ?? shortHash(d.memberHex), display: display, copy: d.messageHash ?? "")
        }
        return Section(title: "Members", rows: rows)
    }

    // MARK: - Rows

    static func missingRow(_ label: String) -> Row {
        Row(label: label, display: missing, copy: "")
    }

    static func optionalRow(_ label: String, _ value: String?) -> Row {
        value.map { Row(label, $0) } ?? missingRow(label)
    }

    static func timeRow(_ label: String, _ date: Date, sameDayAs reference: Date, _ tz: TimeZone) -> Row {
        Row(label: label, display: time(date, sameDayAs: reference, timeZone: tz), copy: iso(date))
    }

    static func hashRow(_ label: String, _ hex: String) -> Row {
        Row(label: label, display: shortHash(hex), copy: hex)
    }

    static func fieldRows(_ keys: String?) -> [Row] {
        guard let keys else { return [missingRow("Fields")] }
        let tokens = keys.split(separator: ",").map(String.init)
        guard !tokens.isEmpty else { return [Row("Fields", "None")] }
        return tokens.map { Row("Field", fieldDisplay($0)) }
    }

    // MARK: - Formatting

    /// `HH:mm:ss` in `timeZone`, prefixed with `yyyy-MM-dd` when not on `reference`'s calendar day.
    static func time(_ date: Date, sameDayAs reference: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: reference) ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Unambiguous copy value for a time: ISO-8601 UTC with milliseconds.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Signed duration, truncated to whole seconds: `+4s`, `+1m 21s`, `+2h 03m`, `-3s`.
    static func gap(_ seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded(.down))
        let sign = seconds < 0 && total > 0 ? "-" : "+"
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(sign)\(h)h \(twoDigits(m))m" }
        if m > 0 { return "\(sign)\(m)m \(twoDigits(s))s" }
        return "\(sign)\(s)s"
    }

    static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    static func bytes(_ n: Int) -> String { "\(n) B" }

    /// `first4…last4`, or the whole string when shortening would hide nothing.
    static func shortHash(_ hex: String) -> String {
        guard hex.count > 9 else { return hex }
        return "\(hex.prefix(4))…\(hex.suffix(4))"
    }

    static func arrivalName(_ raw: String) -> String {
        switch raw {
        case ArrivalMethod.opportunistic: return "Opportunistic"
        case ArrivalMethod.direct: return "Direct link"
        case ArrivalMethod.propagated: return "Propagation node"
        default: return raw
        }
    }

    static func stampName(_ raw: String) -> String {
        switch raw {
        case StampState.none: return "None"
        case StampState.unchecked: return "Not checked"
        case StampState.valid: return "Valid"
        case StampState.invalid: return "Invalid"
        default: return raw
        }
    }

    static func failureReasonName(_ raw: String) -> String {
        switch raw {
        case FailureReason.rejected: return "Rejected by recipient"
        case FailureReason.cancelled: return "Cancelled"
        default: return raw
        }
    }

    /// A stored token ("0xfb") → "0xFB custom type". An unnamed key → its code alone ("0x2A").
    /// A token that is not `0x<hex>` is shown as-is rather than dropped.
    static func fieldDisplay(_ token: String) -> String {
        guard token.hasPrefix("0x"), let key = Int(token.dropFirst(2), radix: 16), key >= 0 else { return token }
        var hex = String(key, radix: 16, uppercase: true)
        if hex.count < 2 { hex = "0" + hex }
        let code = "0x" + hex
        guard let name = fieldNames[key] else { return code }
        return "\(code) \(name)"
    }

    /// FIELD_* names from reference LXMF 1.1.0 (`LXMF/LXMF.py:8-51`).
    static let fieldNames: [Int: String] = [
        0x01: "embedded LXMs", 0x02: "telemetry", 0x03: "telemetry stream", 0x04: "icon appearance", 0xA0: "profile photo",
        0x05: "file attachments", 0x06: "image", 0x07: "audio", 0x08: "thread", 0x09: "commands",
        0x0A: "results", 0x0B: "group", 0x0C: "ticket", 0x0D: "event", 0x0E: "RNR refs",
        0x0F: "renderer", 0x30: "reply to", 0x31: "reply quote", 0x40: "reaction", 0x41: "comment",
        0x42: "continuation", 0xFB: "custom type", 0xFC: "custom data", 0xFD: "custom meta",
        0xFE: "non-specific", 0xFF: "debug",
    ]
}
