import Foundation

/// Tappable links in a message body: what iOS's data detector finds (web, mail, phone) plus
/// LXMF addresses — `lxmf://<hex>`, `lxmf@<hex>` or a bare 32-hex-char address — each linked
/// as `lxmf://<lowercased hex>`, and `lxma://` contact URIs, linked as `lxma://<hex>` or, with a
/// key, `lxma://<hex>.<key>`. Foundation reads `lxma://<hex>:<key>` as host and port and returns no
/// URL for it, so the link uses the `.` separator, which `ContactURI.parse` also accepts.
public enum MessageLinks {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )
    private static let lxmaPattern = try? NSRegularExpression(
        pattern: "(?<![0-9A-Za-z])lxma://([0-9a-f]{32})(?:[:.]([0-9a-f]{128}))?(?![0-9A-Za-z])",
        options: .caseInsensitive
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

        // lxma:// goes first: the detector would otherwise take only part of the colon form, and
        // the plain-address pattern would link the address inside it on its own.
        for match in lxmaPattern?.matches(in: body, range: whole) ?? [] {
            guard let addressRange = Range(match.range(at: 1), in: body) else { continue }
            var link = "lxma://" + body[addressRange].lowercased()
            if let keyRange = Range(match.range(at: 2), in: body) {
                link += "." + body[keyRange].lowercased()
            }
            guard let url = URL(string: link) else { continue }
            add(url, at: match.range)
        }
        // The detector goes next, so hex inside a web address stays part of that link.
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

    /// True for the `lxmf` and `lxma` schemes: links that open a chat rather than leave the app.
    public static func isLxmf(_ url: URL) -> Bool {
        ["lxmf", "lxma"].contains(url.scheme?.lowercased())
    }

    /// The address a tapped LXMF link should open a chat with; nil for other links and for our own.
    public static func conversationTarget(for url: URL, ownAddress: String) -> String? {
        // Only an lxmf URL's absolute string parses: any other scheme leaves its prefix behind.
        guard let hex = ScannedAddress.parse(url.absoluteString),
              hex != ownAddress.lowercased() else { return nil }
        return hex
    }
}
