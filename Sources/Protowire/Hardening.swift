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

    /// Maximum total input to one decode call, in bytes (64 MiB).
    public static let maxMessageSize: Int = 64 << 20

    /// Maximum decoded length of a PXF `b"…"` literal. Checked from the
    /// literal's length, before it is decoded.
    public static let maxBytesLiteralLength: Int = maxMessageSize

    /// Maximum element count of any repeated or map field, and of an SBE
    /// group's declared `numInGroup`.
    public static let maxRepeatedCount: Int = maxMessageSize

    /// Maximum magnitude of a `pxf.BigFloat`'s binary exponent: `exponent`
    /// plus the bit length of `mantissa`.
    public static let maxBigFloatExponent: Int = 16384

    /// The limits for one decode call (draft -01 § Mandatory Limits), the
    /// constants above being the defaults. Schema input, such as a
    /// `(pxf.default)` literal, stays under the constants: it is the schema
    /// author's, not the document's.
    public struct Limits: Equatable, Sendable {
        public var maxMessageSize: Int
        public var maxNestingDepth: Int
        public var maxNumericLiteralDigits: Int
        public var maxBytesLiteralLength: Int
        public var maxRepeatedCount: Int
        public var maxBigFloatExponent: Int

        public init(maxMessageSize: Int = Hardening.maxMessageSize,
                    maxNestingDepth: Int = Hardening.maxNestingDepth,
                    maxNumericLiteralDigits: Int = Hardening.maxNumericLiteralDigits,
                    maxBytesLiteralLength: Int = Hardening.maxBytesLiteralLength,
                    maxRepeatedCount: Int = Hardening.maxRepeatedCount,
                    maxBigFloatExponent: Int = Hardening.maxBigFloatExponent) {
            self.maxMessageSize = maxMessageSize
            self.maxNestingDepth = maxNestingDepth
            self.maxNumericLiteralDigits = maxNumericLiteralDigits
            self.maxBytesLiteralLength = maxBytesLiteralLength
            self.maxRepeatedCount = maxRepeatedCount
            self.maxBigFloatExponent = maxBigFloatExponent
        }

        /// Refuses an input of `size` bytes, before anything reads it.
        func checkMessageSize(_ size: Int) throws {
            if size > maxMessageSize {
                throw DecoderError.messageTooLarge(size: size, limit: maxMessageSize)
            }
        }

        /// The longest base64 body `checkBytesLiteral` lets through.
        var maxBase64Length: Int { (maxBytesLiteralLength / 3 + 1) * 4 - 1 }

        /// Refuses a `b"…"` literal from the length of its base64 body:
        /// three decoded bytes for every four characters.
        func checkBytesLiteral(base64Length n: Int) throws {
            let decoded = n / 4 * 3
            if decoded > maxBytesLiteralLength {
                throw DecoderError.bytesLiteralTooLong(decoded: decoded, limit: maxBytesLiteralLength)
            }
        }

        /// Refuses one more element past `maxRepeatedCount`, when `count`
        /// elements are already held.
        func checkRepeated(count: Int) throws {
            if count >= maxRepeatedCount {
                throw DecoderError.repeatedCountExceeded(limit: maxRepeatedCount)
            }
        }
    }

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
    case nestingDepthExceeded(Int, limit: Int)
    /// A PXF numeric literal has more significant digits than `Hardening.maxNumericLiteralDigits`.
    case numericLiteralTooLong(digits: Int, limit: Int)
    /// A length-prefixed field claimed more bytes than remain in the buffer.
    case truncatedLengthPrefix(declared: UInt64, remaining: Int)
    /// A length-prefix varint encodes a value that does not fit in `Int` on this platform.
    case lengthPrefixOverflow(UInt64)
    /// A `string`-typed field contained bytes that are not valid UTF-8.
    case invalidUTF8
    /// The input to one decode call is larger than `Limits.maxMessageSize`.
    case messageTooLarge(size: Int, limit: Int)
    /// A PXF `b"…"` literal decodes to more than `Limits.maxBytesLiteralLength`.
    case bytesLiteralTooLong(decoded: Int, limit: Int)
    /// A repeated field, map or SBE group holds more than `Limits.maxRepeatedCount` elements.
    case repeatedCountExceeded(limit: Int)
    /// A `pxf.BigFloat`'s binary exponent is past `Limits.maxBigFloatExponent` in magnitude.
    case bigFloatExponentExceeded(exponent: Int64, limit: Int)

    public var description: String {
        switch self {
        case .nestingDepthExceeded(let d, let limit):
            return "nesting depth \(d) exceeds maximum \(limit)"
        case .numericLiteralTooLong(let digits, let limit):
            return "numeric literal has \(digits) digits; MaxNumericLiteralDigits=\(limit)"
        case .truncatedLengthPrefix(let d, let r):
            return "length-prefix declares \(d) bytes but only \(r) remain"
        case .lengthPrefixOverflow(let v):
            return "length-prefix value \(v) exceeds platform Int range"
        case .invalidUTF8:
            return "invalid UTF-8 in string field"
        case .messageTooLarge(let size, let limit):
            return "input of \(size) bytes exceeds MaxMessageSize=\(limit)"
        case .bytesLiteralTooLong(let decoded, let limit):
            return "bytes literal decodes to \(decoded) bytes; MaxBytesLiteralLength=\(limit)"
        case .repeatedCountExceeded(let limit):
            return "repeated field exceeds MaxRepeatedCount=\(limit)"
        case .bigFloatExponentExceeded(let e, let limit):
            return "pxf.BigFloat binary exponent \(e) exceeds MaxBigFloatExponent=\(limit)"
        }
    }
}

extension PXF {
    /// Refuses a field whose lists or map entries, added up across every
    /// binding in one body, pass `limit`. The parser bounds each list and map
    /// as it reads it, so this only has to catch bindings that concatenate,
    /// and a keyed field once it has become a list.
    static func checkRepeatedCounts(_ entries: [Entry], limit: Int) throws {
        var counts: [String: Int] = [:]
        func add(_ key: String, _ n: Int) throws {
            let total = counts[key, default: 0] + n
            if total > limit { throw DecoderError.repeatedCountExceeded(limit: limit) }
            counts[key] = total
        }
        func body(_ key: String, _ sub: [Entry]) throws {
            try add(key, sub.reduce(0) { $0 + ($1 is MapEntry ? 1 : 0) })
            try checkRepeatedCounts(sub, limit: limit)
        }
        func value(_ key: String, _ v: Value) throws {
            if let list = v as? ListVal {
                try add(key, list.elements.count)
                for e in list.elements { try value(key + "[]", e) }
            } else if let block = v as? BlockVal {
                try body(key, block.entries)
            }
        }
        for entry in entries {
            if let a = entry as? Assignment { try value(a.key, a.value) }
            else if let b = entry as? Block { try body(b.name, b.entries) }
            else if let m = entry as? MapEntry { try value(m.key, m.value) }
        }
    }
}
