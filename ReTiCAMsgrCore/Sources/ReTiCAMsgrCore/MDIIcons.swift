import Foundation
import CoreText

/// Material Design Icons (Pictogrammers, Apache 2.0): the icon names that LXMF field 0x04
/// carries (`account`, ...) mapped to their glyph in the bundled webfont. The table is
/// `Resources/mdi-codepoints.tsv` (`name<TAB>hex`), generated from @mdi/font 7.4.47's CSS.
public enum MDIIcons {
    /// The font's real PostScript name (its family is "Material Design Icons").
    public static let fontName = "MaterialDesignIcons"

    private static let table: [String: Character] = {
        guard let url = Bundle.module.url(forResource: "mdi-codepoints", withExtension: "tsv"),
              let tsv = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var out: [String: Character] = [:]
        out.reserveCapacity(8000)
        for line in tsv.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2,
                  let value = UInt32(cols[1], radix: 16),
                  let scalar = UnicodeScalar(value)
            else { continue }
            out[String(cols[0])] = Character(scalar)
        }
        return out
    }()

    /// The glyph for an MDI icon name, or nil when the name is not in the set.
    public static func codepoint(for name: String) -> Character? { table[name] }

    private static let registration: Void = {
        guard let url = Bundle.module.url(forResource: "materialdesignicons-webfont", withExtension: "ttf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// Registers the bundled font for this process. Safe to call repeatedly.
    public static func registerFont() { _ = registration }
}
