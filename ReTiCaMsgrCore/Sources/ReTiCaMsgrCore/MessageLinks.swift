import Foundation

/// Tappable links in a message body: what iOS's data detector finds (web, mail, phone) plus
/// LXMF addresses — `lxmf://<hex>`, `lxmf@<hex>` or a bare 32-hex-char address — each linked
/// as `lxmf://<lowercased hex>`.
public enum MessageLinks {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )
    private static let lxmfPattern = try? NSRegularExpression(
        pattern: "(?<![0-9A-Za-z])(?:lxmf://|lxmf@)?([0-9a-f]{32})(?![0-9A-Za-z])",
        options: .caseInsensitive
    )

    public static func attributed(_ body: String) -> AttributedString {
        var attributed = AttributedString(body)
        let whole = NSRange(body.startIndex..., in: body)
        var taken: [NSRange] = []

        func add(_ url: URL, at range: NSRange) {
            guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let span = Range(range, in: attributed) else { return }
            taken.append(range)
            attributed[span].link = url
            attributed[span].underlineStyle = .single
        }

        // The detector goes first, so hex inside a web address stays part of that link.
        for match in detector?.matches(in: body, range: whole) ?? [] {
            if let url = match.url {
                add(url, at: match.range)
            } else if let number = match.phoneNumber,
                      let url = URL(string: "tel:" + number.filter { $0.isNumber || $0 == "+" }) {
                add(url, at: match.range)
            }
        }
        for match in lxmfPattern?.matches(in: body, range: whole) ?? [] {
            guard let hexRange = Range(match.range(at: 1), in: body),
                  let url = URL(string: "lxmf://" + body[hexRange].lowercased()) else { continue }
            add(url, at: match.range)
        }
        return attributed
    }

    public static func isLxmf(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "lxmf"
    }

    /// The address a tapped LXMF link should open a chat with; nil for other links and for our own.
    public static func conversationTarget(for url: URL, ownAddress: String) -> String? {
        // Only an lxmf URL's absolute string parses: any other scheme leaves its prefix behind.
        guard let hex = ScannedAddress.parse(url.absoluteString),
              hex != ownAddress.lowercased() else { return nil }
        return hex
    }
}
