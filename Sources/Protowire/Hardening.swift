// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// Decoder hardening limits, mandated by HARDENING.md across all `protowire-*` ports.
public enum Hardening {
    /// Maximum allowed nesting depth for recursive decoders (PXF blocks/lists,
    /// PB submessages). Exceeding this is a decode error, not a stack overflow.
    public static let maxNestingDepth: Int = 100

    /// Maximum significant digits of a PXF numeric literal's mantissa, before
    /// a big-number parser sees it. A literal of exactly this many digits is
    /// within the limit. Fixed-width targets need no cap: they fail on range.
    public static let maxNumericLiteralDigits: Int = 4096

    /// What `maxNumericLiteralDigits` counts: the digits of a literal's
    /// mantissa, either side of the point, leading zeros excluded. An exponent
    /// and a precision suffix are bounded on their own, so the count stops at
    /// either marker (draft -01 § Mandatory Limits).
    static func significantDigits(_ literal: String) -> Int {
        var count = 0
        var leading = true
        for c in literal.utf8 {
            if c == 101 || c == 69 || c == 112 { break } // e, E, p
            if c < 48 || c > 57 || (leading && c == 48) { continue }
            leading = false
            count += 1
        }
        return count
    }
}

/// Errors surfaced by the decoder when attacker-supplied input violates the
/// hardening contract. These are distinct from format-level parse errors so
/// callers can differentiate adversarial input from ordinary malformed data.
public enum DecoderError: Error, CustomStringConvertible {
    /// Nesting (PXF block/list, PB submessage) exceeds `Hardening.maxNestingDepth`.
    case nestingDepthExceeded(Int)
    /// A PXF numeric literal has more significant digits than `Hardening.maxNumericLiteralDigits`.
    case numericLiteralTooLong(digits: Int)
    /// A length-prefixed field claimed more bytes than remain in the buffer.
    case truncatedLengthPrefix(declared: UInt64, remaining: Int)
    /// A length-prefix varint encodes a value that does not fit in `Int` on this platform.
    case lengthPrefixOverflow(UInt64)
    /// A `string`-typed field contained bytes that are not valid UTF-8.
    case invalidUTF8

    public var description: String {
        switch self {
        case .nestingDepthExceeded(let d):
            return "nesting depth \(d) exceeds maximum \(Hardening.maxNestingDepth)"
        case .numericLiteralTooLong(let digits):
            return "numeric literal has \(digits) digits; MaxNumericLiteralDigits=\(Hardening.maxNumericLiteralDigits)"
        case .truncatedLengthPrefix(let d, let r):
            return "length-prefix declares \(d) bytes but only \(r) remain"
        case .lengthPrefixOverflow(let v):
            return "length-prefix value \(v) exceeds platform Int range"
        case .invalidUTF8:
            return "invalid UTF-8 in string field"
        }
    }
}
