// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

// The arbitrary-precision language values a struct field holds for
// pxf.BigInt, pxf.Decimal and pxf.BigFloat (#71). The generated messages
// (`Pxf_BigInt` and the others) stay what they are: a message is written as
// it is, while a language value is written in reduced form (draft -01
// § PXF Annotations). These are that language value. They live in the `PXF`
// namespace so that neither `Foundation.Decimal` nor a package's `BigInt` is
// shadowed for a module that imports this one.

extension PXF {
    /// A signed integer of any width: pxf.BigInt as a language value.
    ///
    /// A zero has no sign. `description` is its PXF literal.
    public struct BigInt: Hashable, Sendable, CustomStringConvertible {
        var magnitudeValue: BigUInt
        /// Whether the value is below zero. A zero is never negative.
        public private(set) var isNegative: Bool

        /// Zero.
        public init() {
            magnitudeValue = BigUInt()
            isNegative = false
        }

        init(negative: Bool, magnitude: BigUInt) {
            magnitudeValue = magnitude
            isNegative = negative && !magnitude.isZero
        }

        /// The value of a Swift integer.
        public init<T: BinaryInteger>(_ value: T) {
            self.init(negative: value < 0, magnitude: BigUInt(words: value.magnitude.words))
        }

        /// The value whose magnitude is `magnitude`, an unsigned big-endian
        /// integer (leading zero bytes allowed), negated when `negative`.
        public init(negative: Bool, magnitude: Data) {
            self.init(negative: negative, magnitude: BigUInt(bigEndian: magnitude))
        }

        /// The value a pxf.BigInt message holds.
        public init(_ message: Pxf_BigInt) {
            self.init(negative: message.negative, magnitude: message.abs)
        }

        /// Reads a PXF integer literal, such as `-12345678901234567890`. The
        /// digit cap is `limits.maxNumericLiteralDigits`.
        public init(pxfLiteral literal: String, limits: Hardening.Limits = Hardening.Limits()) throws {
            if let prec = PXF.splitPrecision(literal).precision {
                throw PXF.BigNumberError(message: "precision suffix p\(PXF.clip(prec)) is allowed only on a pxf.BigFloat")
            }
            let (abs, negative) = try PXF.parseBigInt(literal, maxDigits: limits.maxNumericLiteralDigits, codingPath: [])
            self.init(negative: negative, magnitude: abs)
        }

        /// The magnitude as an unsigned big-endian integer, empty for zero.
        public var magnitude: Data { magnitudeValue.bigEndianBytes }

        public var isZero: Bool { magnitudeValue.isZero }

        /// The pxf.BigInt message for this value, with no field set for zero.
        public var message: Pxf_BigInt {
            var m = Pxf_BigInt()
            m.abs = magnitude
            m.negative = isNegative
            return m
        }

        /// The PXF literal: the integer in decimal.
        public var description: String {
            (isNegative ? "-" : "") + magnitudeValue.decimalString
        }
    }

    /// An exact decimal: pxf.Decimal as a language value.
    ///
    /// The value is `unscaled × 10^(-scale)`. The scale is kept, so `1.00`
    /// reads and writes back as `1.00` in PXF, but it is not part of the
    /// value: `1.00 == 1.0`, as the draft defines a pxf.Decimal's value
    /// (§ PXF Annotations), and `PBEncoder` writes the reduced form. A zero has
    /// no sign. `|scale|` is at most `Hardening.maxNumericLiteralDigits`.
    public struct Decimal: Hashable, Sendable, CustomStringConvertible {
        var unscaledMagnitude: BigUInt
        /// Whether the value is below zero. A zero is never negative.
        public private(set) var isNegative: Bool
        /// The number of digits after the point. A negative scale means
        /// trailing zeros: unscaled 5 at scale -2 is 500.
        public private(set) var scale: Int

        /// Zero.
        public init() {
            unscaledMagnitude = BigUInt()
            isNegative = false
            scale = 0
        }

        init(negative: Bool, unscaled: BigUInt, scale: Int) {
            unscaledMagnitude = unscaled
            isNegative = negative && !unscaled.isZero
            self.scale = scale
        }

        /// The value of a Swift integer, at scale 0.
        public init<T: BinaryInteger>(_ value: T) {
            self.init(negative: value < 0, unscaled: BigUInt(words: value.magnitude.words), scale: 0)
        }

        /// `unscaled × 10^(-scale)`. A scale past
        /// `Hardening.maxNumericLiteralDigits` in magnitude is an error: no
        /// conformant reader accepts it.
        public init(unscaled: BigInt, scale: Int) throws {
            try Self.checkScale(scale, limit: Hardening.maxNumericLiteralDigits)
            self.init(negative: unscaled.isNegative, unscaled: unscaled.magnitudeValue, scale: scale)
        }

        /// The value a pxf.Decimal message holds, its scale kept. A scale past
        /// `limits.maxNumericLiteralDigits` in magnitude is refused before
        /// anything is computed (draft -01 § Mandatory Limits).
        public init(_ message: Pxf_Decimal, limits: Hardening.Limits = Hardening.Limits()) throws {
            try Self.checkScale(Int(message.scale), limit: limits.maxNumericLiteralDigits)
            self.init(negative: message.negative, unscaled: BigUInt(bigEndian: message.unscaled), scale: Int(message.scale))
        }

        /// Reads a PXF decimal literal, such as `-1.50`, keeping its scale.
        public init(pxfLiteral literal: String, limits: Hardening.Limits = Hardening.Limits()) throws {
            try self.init(PXF.parseDecimal(literal, limits: limits), limits: limits)
        }

        static func checkScale(_ scale: Int, limit: Int) throws {
            guard scale <= limit, scale >= -limit else {
                throw PXF.BigNumberError(message: "pxf.Decimal scale \(scale) exceeds MaxNumericLiteralDigits=\(limit)")
            }
        }

        /// The unscaled integer, signed.
        public var unscaled: BigInt { BigInt(negative: isNegative, magnitude: unscaledMagnitude) }

        public var isZero: Bool { unscaledMagnitude.isZero }

        /// The same value in reduced form: the smallest scale that is not
        /// negative and holds it exactly. `1.00` is 1 at scale 0, `5E+2`
        /// is 500 at scale 0, and zero is 0 at scale 0.
        public var reduced: Decimal {
            let (m, s) = reducedParts
            return Decimal(negative: isNegative, unscaled: m, scale: s)
        }

        var reducedParts: (BigUInt, Int) {
            if unscaledMagnitude.isZero { return (BigUInt(), 0) }
            var m = unscaledMagnitude
            var s = scale
            if s < 0 {
                m = m * BigUInt.power(10, -s)
                s = 0
            }
            let ten = BigUInt(10)
            while s > 0 {
                let (q, r) = m.quotientAndRemainder(dividingBy: ten)
                if !r.isZero { break }
                m = q
                s -= 1
            }
            return (m, s)
        }

        /// The pxf.Decimal message in reduced form, as the draft requires a
        /// producer writing a language value to write it: `1.00` is unscaled
        /// 1 with no scale, and a zero has no field set.
        public var message: Pxf_Decimal {
            let (m, s) = reducedParts
            var out = Pxf_Decimal()
            out.unscaled = m.bigEndianBytes
            out.scale = Int32(s) // s <= |scale| <= maxNumericLiteralDigits
            out.negative = isNegative
            return out
        }

        public static func == (a: Decimal, b: Decimal) -> Bool {
            a.isNegative == b.isNegative && a.reducedParts == b.reducedParts
        }

        public func hash(into hasher: inout Hasher) {
            let (m, s) = reducedParts
            hasher.combine(isNegative)
            hasher.combine(m)
            hasher.combine(s)
        }

        /// The PXF literal, at this value's scale: `1.00`, `-0.5`, `500`.
        /// PXF has no exponent form for a decimal, so a negative scale is
        /// written as trailing zeros.
        public var description: String {
            var digits = unscaledMagnitude.decimalString
            if scale < 0, !unscaledMagnitude.isZero { digits += String(repeating: "0", count: -scale) }
            let sign = isNegative ? "-" : ""
            guard scale > 0 else { return sign + digits }
            if digits.count <= scale {
                digits = String(repeating: "0", count: scale - digits.count + 1) + digits
            }
            let point = digits.index(digits.endIndex, offsetBy: -scale)
            return sign + digits[..<point] + "." + digits[point...]
        }
    }

    /// A binary floating-point number of any precision: pxf.BigFloat as a
    /// language value.
    ///
    /// The value is `±mantissa × 2^exponent`, rounded to `precision` bits
    /// with ties to even. A zero keeps its precision and its sign, as the
    /// draft keeps them (§ PXF Annotations); precision 0 holds only zero.
    /// Two values are equal when their value, precision and sign all are, so
    /// `0p53 != -0p53` and `1.5p53 != 1.5p64`: these are what PXF text and PB
    /// preserve for a BigFloat.
    public struct BigFloat: Hashable, Sendable, CustomStringConvertible {
        /// Odd, or zero: the value's bits with no trailing zero.
        var mantissa: BigUInt
        /// The value is `mantissa × 2^exponent`; 0 for a zero.
        var exponent: Int
        /// The precision in bits.
        public private(set) var precision: UInt32
        /// The sign, which a zero keeps.
        public private(set) var isNegative: Bool

        /// Zero at precision 0: the empty pxf.BigFloat message.
        public init() {
            mantissa = BigUInt()
            exponent = 0
            precision = 0
            isNegative = false
        }

        /// `±mantissa × 2^exponent` rounded to `precision` bits, ties to even.
        init(negative: Bool, mantissa m: BigUInt, exponent e: Int, precision: UInt32) {
            self.precision = precision
            isNegative = negative
            if m.isZero || precision == 0 {
                mantissa = BigUInt()
                exponent = 0
                return
            }
            let (kept, dropped) = m.rounded(toBits: Int(precision))
            let zeros = kept.trailingZeroBitCount
            mantissa = kept >> zeros
            exponent = e + dropped + zeros
        }

        /// A `Double`, rounded to `precision` bits (53, the default, holds
        /// every `Double` exactly). Nil for an infinity or a NaN, which
        /// pxf.BigFloat cannot hold, and for a non-zero value at precision 0.
        public init?(_ value: Double, precision: UInt32 = 53) {
            guard value.isFinite, value == 0 || precision > 0 else { return nil }
            var bits = UInt64(value.significandBitPattern)
            var e = Int(value.exponentBitPattern) - 1075
            if value.isNormal {
                bits |= 1 << 52
            } else {
                e += 1 // subnormal
            }
            self.init(negative: value.sign == .minus, mantissa: BigUInt(words: [UInt(bits)]), exponent: e, precision: precision)
        }

        /// A Swift integer, rounded to `precision` bits. Without one, the
        /// precision is the integer's bit length or 64, whichever is larger,
        /// so the value is exact, as Go's `big.Float.SetInt` chooses.
        public init<T: BinaryInteger>(_ value: T, precision: UInt32? = nil) {
            let m = BigUInt(words: value.magnitude.words)
            self.init(negative: value < 0, mantissa: m, exponent: 0, precision: precision ?? UInt32(max(64, m.bitWidth)))
        }

        /// The value a pxf.BigFloat message holds: its mantissa rounded to
        /// `prec` bits, as the draft defines it. A `prec` whose literal needs
        /// more than `limits.maxNumericLiteralDigits` digits, and a binary
        /// exponent past `limits.maxBigFloatExponent` in magnitude, are
        /// refused before anything is built (draft -01 § Mandatory Limits).
        public init(_ message: Pxf_BigFloat, limits: Hardening.Limits = Hardening.Limits()) throws {
            guard message.prec != 0 else {
                self.init()
                isNegative = message.negative
                return
            }
            let digits = PXF.bigFloatDigits(message.prec)
            guard digits <= limits.maxNumericLiteralDigits else {
                throw PXF.BigNumberError(message: "pxf.BigFloat prec \(message.prec) implies \(digits) digits; MaxNumericLiteralDigits=\(limits.maxNumericLiteralDigits)")
            }
            let m = BigUInt(bigEndian: message.mantissa)
            if !m.isZero {
                let e = Int64(message.exponent) + Int64(m.bitWidth)
                if e > Int64(limits.maxBigFloatExponent) || e < -Int64(limits.maxBigFloatExponent) {
                    throw DecoderError.bigFloatExponentExceeded(exponent: e, limit: limits.maxBigFloatExponent)
                }
            }
            self.init(negative: message.negative, mantissa: m, exponent: Int(message.exponent), precision: message.prec)
        }

        /// Reads a PXF float literal at the precision its `p<bits>` suffix
        /// states, or 256 bits without one, as `1.5p53`.
        public init(pxfLiteral literal: String, limits: Hardening.Limits = Hardening.Limits()) throws {
            try self.init(PXF.parseBigFloat(literal, limits: limits), limits: limits)
        }

        public var isZero: Bool { mantissa.isZero }

        /// The pxf.BigFloat message, as protowire-go writes a `*big.Float`:
        /// the mantissa widened to `precision` bits, and a zero with an
        /// empty mantissa and exponent 0, keeping its precision and sign. A
        /// precision whose literal would need more than
        /// `Hardening.maxNumericLiteralDigits` digits, or a binary exponent
        /// past `Hardening.maxBigFloatExponent`, is an error: no conformant
        /// reader accepts either.
        public var message: Pxf_BigFloat {
            get throws {
                var out = Pxf_BigFloat()
                out.negative = isNegative
                guard precision != 0 else { return out }
                let digits = PXF.bigFloatDigits(precision)
                guard digits <= Hardening.maxNumericLiteralDigits else {
                    throw PXF.BigNumberError(message: "pxf.BigFloat prec \(precision) implies \(digits) digits; MaxNumericLiteralDigits=\(Hardening.maxNumericLiteralDigits)")
                }
                out.prec = precision
                guard !mantissa.isZero else { return out }
                try checkExponent()
                let shift = Int(precision) - mantissa.bitWidth
                out.mantissa = (mantissa << shift).bigEndianBytes
                out.exponent = Int32(exponent - shift) // bounded by checkExponent and the prec bound
                return out
            }
        }

        /// The producer's half of `maxBigFloatExponent`.
        private func checkExponent() throws {
            let e = exponent + mantissa.bitWidth
            let bound = Hardening.maxBigFloatExponent
            guard e <= bound, e >= -bound else {
                throw PXF.BigNumberError(message: "pxf.BigFloat binary exponent \(e) exceeds MaxBigFloatExponent=\(bound)")
            }
        }

        /// The PXF literal: enough digits to read back at `precision` bits,
        /// then the precision (draft -01 § PXF Annotations), as `1.5p53` or
        /// `-0p64`. It fails where `message` does.
        var literal: String {
            get throws {
                var m = Pxf_BigFloat()
                m.negative = isNegative
                m.prec = precision
                if !mantissa.isZero {
                    try checkExponent()
                    m.mantissa = mantissa.bigEndianBytes
                    m.exponent = Int32(exponent)
                }
                return try m.pxfLiteral
            }
        }

        /// The PXF literal, or for a value that has none (a precision or
        /// exponent past the limits) a description of its parts.
        public var description: String {
            if let text = try? literal { return text }
            return "\(isNegative ? "-" : "")\(mantissa.decimalString)×2^\(exponent) at prec \(precision)"
        }
    }
}

// MARK: - Conversions

extension FixedWidthInteger {
    /// The value of `value`, or nil when this type cannot hold it.
    public init?(exactly value: PXF.BigInt) {
        guard let v: Self = exactInteger(negative: value.isNegative, magnitude: value.magnitudeValue) else { return nil }
        self = v
    }

    /// The value of `value`, or nil when it is not an integer or this type
    /// cannot hold it.
    public init?(exactly value: PXF.Decimal) {
        let (m, s) = value.reducedParts
        guard s == 0, let v: Self = exactInteger(negative: value.isNegative, magnitude: m) else { return nil }
        self = v
    }

    /// The value of `value`, or nil when it is not an integer or this type
    /// cannot hold it.
    public init?(exactly value: PXF.BigFloat) {
        guard value.exponent >= 0 || value.mantissa.isZero else { return nil }
        guard value.mantissa.bitWidth + value.exponent <= Self.bitWidth else { return nil }
        guard let v: Self = exactInteger(negative: value.isNegative, magnitude: value.mantissa << value.exponent) else { return nil }
        self = v
    }
}

/// `±magnitude` as `T`, or nil when `T` cannot hold it.
private func exactInteger<T: FixedWidthInteger>(negative: Bool, magnitude m: BigUInt) -> T? {
    guard m.bitWidth <= T.Magnitude.bitWidth else { return nil }
    var mag: T.Magnitude = 0
    for limb in m.limbs.reversed() {
        mag = mag << 32 | T.Magnitude(truncatingIfNeeded: limb)
    }
    if !negative || mag == 0 { return T(exactly: mag) }
    guard T.isSigned, mag <= T.Magnitude(T.max) + 1 else { return nil }
    return T(truncatingIfNeeded: 0 &- mag)
}

extension PXF.Decimal {
    /// The value of a `Foundation.Decimal`, which always fits. Nil for a NaN.
    public init?(_ value: Foundation.Decimal) {
        guard !value.isNaN else { return nil }
        let words = value._mantissa
        let all = [words.0, words.1, words.2, words.3, words.4, words.5, words.6, words.7]
        var m = BigUInt()
        for word in all.prefix(Int(value._length)).reversed() {
            m = m << 16
            m.multiplyAdd(by: 1, adding: UInt32(word))
        }
        self.init(negative: value._isNegative != 0, unscaled: m, scale: -Int(value._exponent))
    }
}

extension Foundation.Decimal {
    /// The value of `value`, or nil when a `Foundation.Decimal` cannot hold
    /// it exactly: its significand is 128 bits (38 digits, and some of 39),
    /// and its decimal exponent is between -128 and 127.
    public init?(exactly value: PXF.Decimal) {
        var (m, s) = value.reducedParts
        if m.isZero {
            self = 0
            return
        }
        // The trailing zeros a reduced value keeps at scale 0 go to the exponent.
        var e = -s
        let ten = BigUInt(10)
        while e < 127 {
            let (q, r) = m.quotientAndRemainder(dividingBy: ten)
            if !r.isZero { break }
            m = q
            e += 1
        }
        // An exponent past the range can come back by scaling the significand.
        while e > 127, m.bitWidth <= 128 {
            m.multiplyAdd(by: 10, adding: 0)
            e -= 1
        }
        guard e >= -128, e <= 127, m.bitWidth <= 128 else { return nil }
        var words = [UInt16](repeating: 0, count: 8)
        for i in 0..<8 {
            words[i] = UInt16(truncatingIfNeeded: (m >> (16 * i)).limbs.first ?? 0)
        }
        let length = (words.lastIndex { $0 != 0 } ?? -1) + 1
        self.init(_exponent: Int32(e), _length: UInt32(length), _isNegative: value.isNegative ? 1 : 0, _isCompact: 1, _reserved: 0,
                  _mantissa: (words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7]))
    }
}

// MARK: - BigUInt helpers

extension BigUInt {
    /// From an unsigned integer's words, least significant first.
    init<W: Collection>(words: W) where W.Element == UInt {
        self.init()
        for word in words.reversed() {
            for half in [UInt32(truncatingIfNeeded: UInt64(word) >> 32), UInt32(truncatingIfNeeded: word)] {
                self = self << 32
                multiplyAdd(by: 1, adding: half)
            }
        }
    }

    /// The number of zero bits below the lowest set bit; 0 for zero.
    var trailingZeroBitCount: Int {
        guard let i = limbs.firstIndex(where: { $0 != 0 }) else { return 0 }
        return i * 32 + limbs[i].trailingZeroBitCount
    }
}

// MARK: - Codable

// Each type reads and writes its PXF literal as a string for a coder this
// package does not own (JSON, a property list), and reads the message's
// fields too, which is the other form a PXF document may use.

extension PXF.BigInt: Codable {
    public init(from decoder: Decoder) throws {
        if let text = PXF.stringLiteral(decoder) {
            self = try PXF.BigInt(pxfLiteral: text)
            return
        }
        self.init(try Pxf_BigInt(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension PXF.Decimal: Codable {
    public init(from decoder: Decoder) throws {
        if let text = PXF.stringLiteral(decoder) {
            self = try PXF.Decimal(pxfLiteral: text)
            return
        }
        try self.init(try Pxf_Decimal(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension PXF.BigFloat: Codable {
    public init(from decoder: Decoder) throws {
        if let text = PXF.stringLiteral(decoder) {
            self = try PXF.BigFloat(pxfLiteral: text)
            return
        }
        try self.init(try Pxf_BigFloat(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(try literal)
    }
}

extension PXF {
    /// The string a decoder holds as a single value, if it holds one.
    static func stringLiteral(_ decoder: Decoder) -> String? {
        guard let c = try? decoder.singleValueContainer() else { return nil }
        return try? c.decode(String.self)
    }
}
