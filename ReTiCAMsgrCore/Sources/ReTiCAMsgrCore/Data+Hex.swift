import Foundation

// ReTiCA's Data+Hex extensions are internal to the ReTiCA module.
// Provide package-wide equivalents here (both directions).
private let lowercaseHexDigits = Array("0123456789abcdef".utf8)

extension Data {
    /// Lowercase, non-delimited hex representation (matches Python `bytes.hex()`).
    ///
    /// Written into the string's storage directly. `String(format: "%02x")` per byte was the bulk of
    /// what the Diagnostics and Announces screens cost once they formatted a network-sized table.
    var hexString: String {
        String(unsafeUninitializedCapacity: count * 2) { buffer in
            var index = 0
            for byte in self {
                buffer[index] = lowercaseHexDigits[Int(byte >> 4)]
                buffer[index + 1] = lowercaseHexDigits[Int(byte & 0x0F)]
                index += 2
            }
            return index
        }
    }

    /// Parse a non-delimited hex string (even length, [0-9a-fA-F]) into bytes.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = chars.startIndex
        while index < chars.endIndex {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self = Data(bytes)
    }
}
