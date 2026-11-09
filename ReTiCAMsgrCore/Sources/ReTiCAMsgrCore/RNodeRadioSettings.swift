import Foundation

/// Why the RNode radio settings can't be used (spec 2026-11-08 §6). Declared in field order, which is
/// the order `RNodeRadioSettings.problems` and `AppFeature.State.rnodeSettingsProblems` report in.
/// The `…Unreadable` cases come from typed text the parser rejected; the rest from stored values.
public enum RNodeSettingsProblem: Equatable, Sendable, CaseIterable {
    case frequencyMissing, frequencyUnreadable, frequencyOutOfRange
    case bandwidthUnreadable, bandwidthOutOfRange
    case spreadingFactorOutOfRange, codingRateOutOfRange, txPowerOutOfRange
}

/// The user's RNode radio parameters, checked against RNS's input ranges (spec 2026-11-08 §6). Neither
/// ReTiCA nor the kit range-checks, so this is the only check before lane D dials.
public struct RNodeRadioSettings: Equatable, Sendable {
    public var frequencyHz: Int?
    public var bandwidthHz: Int
    public var spreadingFactor: Int
    public var codingRate: Int
    public var txPowerDBm: Int

    public static let frequencyRange: ClosedRange<Int> = 137_000_000...3_000_000_000
    public static let bandwidthRange: ClosedRange<Int> = 7_800...1_625_000
    public static let spreadingFactorRange: ClosedRange<Int> = 5...12
    public static let codingRateRange: ClosedRange<Int> = 5...8
    public static let txPowerRange: ClosedRange<Int> = 0...37

    public init(frequencyHz: Int?, bandwidthHz: Int, spreadingFactor: Int, codingRate: Int, txPowerDBm: Int) {
        self.frequencyHz = frequencyHz
        self.bandwidthHz = bandwidthHz
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.txPowerDBm = txPowerDBm
    }

    /// The range problems, in field order. A missing frequency is `.frequencyMissing`.
    public var problems: [RNodeSettingsProblem] {
        var result: [RNodeSettingsProblem] = []
        if let frequencyHz {
            if !Self.frequencyRange.contains(frequencyHz) { result.append(.frequencyOutOfRange) }
        } else {
            result.append(.frequencyMissing)
        }
        if !Self.bandwidthRange.contains(bandwidthHz) { result.append(.bandwidthOutOfRange) }
        if !Self.spreadingFactorRange.contains(spreadingFactor) { result.append(.spreadingFactorOutOfRange) }
        if !Self.codingRateRange.contains(codingRate) { result.append(.codingRateOutOfRange) }
        if !Self.txPowerRange.contains(txPowerDBm) { result.append(.txPowerOutOfRange) }
        return result
    }

    // MARK: - Text

    /// Megahertz text to hertz: surrounding whitespace is trimmed, then digits with an optional "."
    /// and at most 6 decimals. No sign, unit, exponent or comma. Nil when unreadable.
    public static func parseMegahertz(_ text: String) -> Int? {
        parseScaled(text.trimmingCharacters(in: .whitespacesAndNewlines),
                    scaleDigits: 6, maxDecimals: 6, maxWholeDigits: 10)
    }

    /// Kilohertz text to hertz: the same rules as `parseMegahertz`, with at most 3 decimals.
    public static func parseKilohertz(_ text: String) -> Int? {
        parseScaled(text.trimmingCharacters(in: .whitespacesAndNewlines),
                    scaleDigits: 3, maxDecimals: 3, maxWholeDigits: 7)
    }

    /// Hertz as megahertz text, trailing zeros dropped: 868_100_000 → "868.1", 915_000_000 → "915".
    public static func megahertzText(_ hz: Int) -> String {
        scaledText(hz, scaleDigits: 6)
    }

    /// Hertz as kilohertz text, trailing zeros dropped: 62_500 → "62.5", 125_000 → "125".
    public static func kilohertzText(_ hz: Int) -> String {
        scaledText(hz, scaleDigits: 3)
    }

    /// Exact decimal parsing in integers (no `Double`, which loses the last hertz). The whole part is
    /// capped so the multiplication can't overflow on a pasted run of digits.
    private static func parseScaled(_ text: String, scaleDigits: Int, maxDecimals: Int,
                                    maxWholeDigits: Int) -> Int? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let whole = parts[0]
        guard !whole.isEmpty, whole.count <= maxWholeDigits, isDigits(whole) else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        if parts.count == 2 {
            guard !fraction.isEmpty, fraction.count <= maxDecimals, isDigits(parts[1]) else { return nil }
        }
        fraction = String((fraction + String(repeating: "0", count: scaleDigits)).prefix(scaleDigits))
        var scale = 1
        for _ in 0..<scaleDigits { scale *= 10 }
        guard let wholeValue = Int(whole), let fractionValue = Int(fraction) else { return nil }
        return wholeValue * scale + fractionValue
    }

    private static func isDigits(_ text: Substring) -> Bool {
        text.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    private static func scaledText(_ hz: Int, scaleDigits: Int) -> String {
        var scale: UInt = 1
        for _ in 0..<scaleDigits { scale *= 10 }
        let magnitude = hz.magnitude
        let sign = hz < 0 ? "-" : ""
        let whole = magnitude / scale
        let fraction = magnitude % scale
        guard fraction != 0 else { return "\(sign)\(whole)" }
        var digits = String(fraction)
        digits = String(repeating: "0", count: scaleDigits - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(sign)\(whole).\(digits)"
    }
}
