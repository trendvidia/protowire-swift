// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// The PXF decoder that holds one value rather than a list of entries. A
/// big-number type reads its literal through this: the `Decoder` protocol
/// has no way to ask for an integer of arbitrary length.
protocol _PXFValueHolder {
    var value: PXF.Value { get }
}

/// A value PXF writes as one literal rather than a block. `PXFEncoder` asks
/// for this before it looks at the value's fields.
protocol _PXFLiteral {
    var pxfLiteral: String { get throws }
}

extension Pxf_BigInt: Decodable {
    private enum CodingKeys: Int, CodingKey {
        case abs = 1, negative = 2
    }

    /// Reads a PXF integer literal, or the message form: PB, or a PXF block.
    /// A literal is bounded by `Hardening.maxNumericLiteralDigits`. The
    /// message form has no digit bound: `abs` costs only what the input's
    /// length already bounds (HARDENING.md § Mandatory limits).
    public init(from decoder: Decoder) throws {
        self.init()
        if let holder = decoder as? _PXFValueHolder {
            guard let literal = holder.value as? PXF.IntVal else {
                throw DecodingError.typeMismatch(Pxf_BigInt.self, .init(codingPath: decoder.codingPath,
                    debugDescription: "Expected integer literal for pxf.BigInt, got \(type(of: holder.value))"))
            }
            if let prec = PXF.splitPrecision(literal.raw).precision {
                throw PXF.BigNumberError(message: "precision suffix p\(PXF.clip(prec)) is allowed only on a pxf.BigFloat")
            }
            (abs, negative) = try PXF.parseBigInt(literal.raw, codingPath: decoder.codingPath)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        abs = try c.decodeIfPresent(Data.self, forKey: .abs) ?? Data()
        negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
    }
}

extension Pxf_Decimal: Decodable {
    private enum CodingKeys: Int, CodingKey {
        case unscaled = 1, scale = 2, negative = 3
    }

    /// Reads a PXF decimal literal, keeping its scale, or the message form:
    /// PB, or a PXF block. The message form stores the fields and computes no
    /// value.
    public init(from decoder: Decoder) throws {
        self.init()
        if let holder = decoder as? _PXFValueHolder {
            guard let raw = PXF.numericLiteral(holder.value) else {
                throw DecodingError.typeMismatch(Pxf_Decimal.self, .init(codingPath: decoder.codingPath,
                    debugDescription: "Expected a number for pxf.Decimal, got \(type(of: holder.value))"))
            }
            self = try PXF.parseDecimal(raw)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unscaled = try c.decodeIfPresent(Data.self, forKey: .unscaled) ?? Data()
        // A plain varint: its low 32 bits, read as signed, as in protowire-go.
        scale = Int32(truncatingIfNeeded: try c.decodeIfPresent(Int64.self, forKey: .scale) ?? 0)
        negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
    }
}

extension Pxf_BigFloat: Decodable {
    private enum CodingKeys: Int, CodingKey {
        case mantissa = 1, exponent = 2, prec = 3, negative = 4
    }

    /// Reads a PXF float literal at the precision it states, or the message
    /// form, as `Pxf_Decimal` does.
    public init(from decoder: Decoder) throws {
        self.init()
        if let holder = decoder as? _PXFValueHolder {
            guard let raw = PXF.numericLiteral(holder.value) else {
                throw DecodingError.typeMismatch(Pxf_BigFloat.self, .init(codingPath: decoder.codingPath,
                    debugDescription: "Expected a number for pxf.BigFloat, got \(type(of: holder.value))"))
            }
            self = try PXF.parseBigFloat(raw)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mantissa = try c.decodeIfPresent(Data.self, forKey: .mantissa) ?? Data()
        exponent = Int32(truncatingIfNeeded: try c.decodeIfPresent(Int64.self, forKey: .exponent) ?? 0)
        prec = UInt32(truncatingIfNeeded: try c.decodeIfPresent(UInt64.self, forKey: .prec) ?? 0)
        negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
    }
}

// Encodable writes the message form, zero fields left out as the reference's
// marshal does. PXFEncoder takes the literal instead, through _PXFLiteral.

extension Pxf_BigInt: Encodable, _PXFLiteral {
    private enum EncodingKeys: Int, CodingKey {
        case abs = 1, negative = 2
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        if !abs.isEmpty { try c.encode(abs, forKey: .abs) }
        if negative { try c.encode(negative, forKey: .negative) }
    }

    var pxfLiteral: String {
        get throws {
            let magnitude = BigUInt(bigEndian: abs)
            let text = (negative && !magnitude.isZero ? "-" : "") + magnitude.decimalString
            return try PXF.boundLiteral("pxf.BigInt", text)
        }
    }
}

extension Pxf_Decimal: Encodable, _PXFLiteral {
    private enum EncodingKeys: Int, CodingKey {
        case unscaled = 1, scale = 2, negative = 3
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        if !unscaled.isEmpty { try c.encode(unscaled, forKey: .unscaled) }
        if scale != 0 { try c.encode(scale, forKey: .scale) }
        if negative { try c.encode(negative, forKey: .negative) }
    }

    /// `unscaled × 10^(-scale)`. A negative scale means trailing zeros. The
    /// scale is bounded first: it is four bytes whoever wrote the message
    /// chose, and the work here is proportional to it.
    var pxfLiteral: String {
        get throws {
            let limit = Hardening.maxNumericLiteralDigits
            guard Int(scale) <= limit, Int(scale) >= -limit else {
                throw PXF.BigNumberError(message: "pxf.Decimal scale \(scale) exceeds MaxNumericLiteralDigits=\(limit)")
            }
            var magnitude = BigUInt(bigEndian: unscaled)
            var places = Int(scale)
            if places < 0 {
                magnitude = magnitude * BigUInt.power(10, -places)
                places = 0
            }
            var digits = magnitude.decimalString
            let sign = negative ? "-" : ""
            if places == 0 { return try PXF.boundLiteral("pxf.Decimal", sign + digits) }
            if digits.count <= places {
                digits = String(repeating: "0", count: places - digits.count + 1) + digits
            }
            let point = digits.index(digits.endIndex, offsetBy: -places)
            return try PXF.boundLiteral("pxf.Decimal", sign + digits[..<point] + "." + digits[point...])
        }
    }
}

extension Pxf_BigFloat: Encodable, _PXFLiteral {
    private enum EncodingKeys: Int, CodingKey {
        case mantissa = 1, exponent = 2, prec = 3, negative = 4
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        if !mantissa.isEmpty { try c.encode(mantissa, forKey: .mantissa) }
        if exponent != 0 { try c.encode(exponent, forKey: .exponent) }
        if prec != 0 { try c.encode(prec, forKey: .prec) }
        if negative { try c.encode(negative, forKey: .negative) }
    }

    /// The text form (draft -01 § PXF Annotations): enough digits that a
    /// reader at `prec` bits gets the value back, then the precision.
    var pxfLiteral: String {
        get throws {
            let sign = negative ? "-" : ""
            if prec == 0 { return sign + "0" }
            let magnitude = BigUInt(bigEndian: mantissa)
            if magnitude.isZero { return "\(sign)0p\(prec)" }
            // The exponent's bound comes first: rendering costs the square
            // of its magnitude.
            let binaryExponent = Int64(exponent) + Int64(magnitude.bitWidth)
            let bound = Int64(Hardening.maxBigFloatExponent)
            guard binaryExponent <= bound, binaryExponent >= -bound else {
                throw PXF.BigNumberError(message: "pxf.BigFloat binary exponent \(binaryExponent) exceeds MaxBigFloatExponent=\(bound)")
            }
            let digits = PXF.bigFloatDigits(prec)
            guard digits <= Hardening.maxNumericLiteralDigits else {
                throw PXF.BigNumberError(message: "pxf.BigFloat prec \(prec) bits renders to \(digits) digits; MaxNumericLiteralDigits=\(Hardening.maxNumericLiteralDigits)")
            }
            // A mantissa wider than prec is the value rounded to prec.
            let (kept, dropped) = magnitude.rounded(toBits: Int(prec))
            return sign + PXF.generalFormat(kept, binaryExponent: Int(exponent) + dropped, digits: digits) + "p\(prec)"
        }
    }
}

extension PXF {
    /// A big-number literal the reference refuses, in its wording.
    public struct BigNumberError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { message }
    }

    /// Precision a literal without a suffix is read at (protowire#406).
    static let bigFloatDefaultPrecision = 256

    /// A literal shortened for an error message.
    static func clip(_ s: String) -> String {
        s.utf8.count <= 24 ? s : String(s.prefix(24)) + "…"
    }

    /// The text of a numeric value, suffix included.
    static func numericLiteral(_ value: Value) -> String? {
        (value as? IntVal)?.raw ?? (value as? FloatVal)?.raw
    }

    /// A numeric literal's number and the digits of its `p<bits>` suffix.
    static func splitPrecision(_ raw: String) -> (number: String, precision: String?) {
        guard let p = raw.firstIndex(of: "p") else { return (raw, nil) }
        return (String(raw[..<p]), String(raw[raw.index(after: p)...]))
    }

    /// The marshaller's half of `maxNumericLiteralDigits`: a literal this
    /// port's decoder would refuse is an error, not a document nobody reads.
    static func boundLiteral(_ kind: String, _ text: String) throws -> String {
        let n = Hardening.significantDigits(text)
        guard n <= Hardening.maxNumericLiteralDigits else {
            throw BigNumberError(message: "\(kind) renders to \(n) digits; MaxNumericLiteralDigits=\(Hardening.maxNumericLiteralDigits)")
        }
        return text
    }

    /// Reads a decimal literal, keeping its scale: `1.00` has scale 2.
    static func parseDecimal(_ raw: String) throws -> Pxf_Decimal {
        let (number, precision) = splitPrecision(raw)
        if let precision {
            throw BigNumberError(message: "precision suffix p\(clip(precision)) is allowed only on a pxf.BigFloat")
        }
        let digitCount = Hardening.significantDigits(number)
        guard digitCount <= Hardening.maxNumericLiteralDigits else {
            throw DecoderError.numericLiteralTooLong(digits: digitCount)
        }
        var bytes = Array(number.utf8)[...]
        var out = Pxf_Decimal()
        if bytes.first == 45 {
            out.negative = true
            bytes = bytes.dropFirst()
        }
        var scale = 0
        if let dot = bytes.firstIndex(of: 46) {
            scale = bytes.endIndex - dot - 1
            bytes = bytes[..<dot] + bytes[(dot + 1)...]
        }
        guard scale <= Hardening.maxNumericLiteralDigits else {
            throw BigNumberError(message: "pxf.Decimal scale \(scale) exceeds MaxNumericLiteralDigits=\(Hardening.maxNumericLiteralDigits)")
        }
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw BigNumberError(message: "invalid decimal: \(clip(raw))")
        }
        out.unscaled = BigUInt(decimalDigits: bytes.drop { $0 == 48 }).bigEndianBytes
        out.scale = Int32(scale)
        return out
    }

    /// Reads a float literal at the precision its suffix states, or 256 bits
    /// without one, rounding to nearest with ties to even. The suffix is
    /// checked before anything is allocated for it. The stored mantissa is the
    /// significand as a `prec`-bit integer.
    static func parseBigFloat(_ raw: String) throws -> Pxf_BigFloat {
        let (number, suffix) = splitPrecision(raw)
        var precision = bigFloatDefaultPrecision
        if let suffix {
            guard suffix.utf8.count <= 10, let p = UInt32(suffix), p != 0 else {
                throw BigNumberError(message: "big float literal \(clip(number))p\(clip(suffix)): precision suffix p\(clip(suffix)) is not a positive bit count")
            }
            let n = bigFloatDigits(p)
            guard n <= Hardening.maxNumericLiteralDigits else {
                throw BigNumberError(message: "big float literal \(clip(number))p\(p): precision p\(p) renders to \(n) digits; MaxNumericLiteralDigits=\(Hardening.maxNumericLiteralDigits)")
            }
            precision = Int(p)
        }
        let digitCount = Hardening.significantDigits(number)
        guard digitCount <= Hardening.maxNumericLiteralDigits else {
            throw DecoderError.numericLiteralTooLong(digits: digitCount)
        }
        guard let parsed = DecimalFloat(number) else {
            throw BigNumberError(message: "invalid big float: \(clip(number))")
        }

        var out = Pxf_BigFloat()
        out.negative = parsed.negative
        if parsed.digits.isZero {
            if suffix != nil { out.prec = UInt32(precision) }
            return out
        }
        // Refused before 10^|e| is computed: the value lies in
        // [10^(d-1), 10^d), and a decimal exponent past the binary bound is
        // past it in binary too. The exact check is below.
        let bound = Hardening.maxBigFloatExponent
        let tooLarge = BigNumberError(message: "big float literal \(clip(number)) has a binary exponent past MaxBigFloatExponent=\(bound)")
        guard let power = parsed.exponent else { throw tooLarge }
        let decimalPoint = parsed.digits.decimalString.utf8.count + power
        if decimalPoint - 1 > bound || decimalPoint < -bound { throw tooLarge }

        var numerator = parsed.digits
        var denominator = BigUInt(1)
        if power >= 0 {
            numerator = numerator * BigUInt.power(10, power)
        } else {
            denominator = BigUInt.power(10, -power)
        }
        // Two guard bits and the remainder as a sticky bit decide the rounding.
        let shift = precision + 2 - (numerator.bitWidth - denominator.bitWidth)
        if shift >= 0 { numerator = numerator << shift } else { denominator = denominator << -shift }
        let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
        let (kept, dropped) = quotient.rounded(toBits: precision, sticky: !remainder.isZero)

        let exponent = dropped - shift
        let binaryExponent = exponent + kept.bitWidth
        guard binaryExponent <= bound, binaryExponent >= -bound else {
            throw BigNumberError(message: "big float literal \(clip(number)) has binary exponent \(binaryExponent), and MaxBigFloatExponent=\(bound) bounds its magnitude")
        }
        out.mantissa = kept.bigEndianBytes
        out.exponent = Int32(exponent)
        out.prec = UInt32(precision)
        return out
    }

    /// `[-] digits [. digits] [e [+-] digits]`, as digits × 10^exponent.
    private struct DecimalFloat {
        var negative = false
        var digits: BigUInt
        /// nil: too large to matter, which is an error unless `digits` is 0.
        var exponent: Int?

        init?(_ text: String) {
            var bytes = Array(text.utf8)[...]
            if bytes.first == 45 {
                negative = true
                bytes = bytes.dropFirst()
            }
            let marker = bytes.firstIndex { $0 == 101 || $0 == 69 }
            var mantissa = bytes[..<(marker ?? bytes.endIndex)]
            var power = 0
            if let dot = mantissa.firstIndex(of: 46) {
                power = dot + 1 - mantissa.endIndex
                mantissa = mantissa[..<dot] + mantissa[(dot + 1)...]
            }
            guard !mantissa.isEmpty, mantissa.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            digits = BigUInt(decimalDigits: mantissa.drop { $0 == 48 })
            exponent = power
            guard let marker else { return }
            var tail = bytes[(marker + 1)...]
            var sign = 1
            if tail.first == 43 || tail.first == 45 {
                sign = tail.first == 45 ? -1 : 1
                tail = tail.dropFirst()
            }
            guard !tail.isEmpty, tail.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            let significant = tail.drop { $0 == 48 }
            guard significant.count <= 9 else {
                exponent = nil
                return
            }
            let e = significant.reduce(0) { $0 * 10 + Int($1 - 48) }
            exponent = power + sign * e
        }
    }

    /// The significant digits of a BigFloat of `prec` bits: the decimal digits
    /// of 2^prec, plus one. `prec` comes off the wire or out of a document, so
    /// 2^prec is never computed.
    static func bigFloatDigits(_ prec: UInt32) -> Int {
        // floor(log10(2) × 2^128), in 128-bit fixed point. The product falls
        // short of prec·log10(2) by less than 2^-95, and for every UInt32 prec
        // it is further than that from an integer, so the floor is exact.
        let high: UInt64 = 0x4d10_4d42_7de7_fbcc, low: UInt64 = 0x47c4_acd6_05be_48bc
        let (hi, lo) = UInt64(prec).multipliedFullWidth(by: high)
        let (_, carry) = lo.addingReportingOverflow(UInt64(prec).multipliedFullWidth(by: low).high)
        return Int(hi) + (carry ? 1 : 0) + 1 + 1
    }

    /// `mantissa × 2^binaryExponent`, not zero, in C's `%g` form with `digits`
    /// significant digits, round half even on the exact decimal expansion and
    /// trailing zeros removed. This is what `big.Float.Text('g', digits)` writes.
    static func generalFormat(_ mantissa: BigUInt, binaryExponent: Int, digits: Int) -> String {
        var text: [UInt8]
        var point: Int // the value is 0.text × 10^point
        if binaryExponent >= 0 {
            text = Array((mantissa << binaryExponent).decimalString.utf8)
            point = text.count
        } else {
            text = Array((mantissa * BigUInt.power(5, -binaryExponent)).decimalString.utf8)
            point = text.count + binaryExponent
        }
        if text.count > digits {
            let exactHalf = text[digits] == 53 && digits + 1 == text.count
            let up = exactHalf ? (text[digits - 1] - 48) & 1 == 1 : text[digits] >= 53
            text.removeLast(text.count - digits)
            if up {
                var i = digits - 1
                while i >= 0, text[i] == 57 {
                    text[i] = 48
                    i -= 1
                }
                if i >= 0 {
                    text[i] += 1
                } else {
                    text = [49]
                    point += 1
                }
            }
        }
        while text.last == 48 { text.removeLast() }

        var threshold = digits
        if threshold > text.count && text.count >= point { threshold = text.count }
        let exponent = point - 1
        func digit(_ i: Int) -> UInt8 { i >= 0 && i < text.count ? text[i] : 48 }

        if exponent < -4 || exponent >= threshold {
            var out = [text[0]]
            if text.count > 1 {
                out.append(46)
                out += text[1...]
            }
            let magnitude = String(exponent < 0 ? -exponent : exponent)
            return String(decoding: out, as: UTF8.self) + "e" + (exponent < 0 ? "-" : "+")
                + (magnitude.utf8.count < 2 ? "0" : "") + magnitude
        }
        var out: [UInt8] = []
        if point > 0 {
            for i in 0..<point { out.append(digit(i)) }
        } else {
            out.append(48)
        }
        let places = max((digits > point ? text.count : digits) - point, 0)
        if places > 0 {
            out.append(46)
            for i in 0..<places { out.append(digit(point + i)) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses an integer literal into `pxf.BigInt`'s fields: an unsigned
    /// big-endian magnitude, empty for zero, and a sign. The digit cap is
    /// checked first, so past it nothing is converted.
    static func parseBigInt(_ raw: String, codingPath: [CodingKey]) throws -> (abs: Data, negative: Bool) {
        let digitCount = Hardening.significantDigits(raw)
        guard digitCount <= Hardening.maxNumericLiteralDigits else {
            throw DecoderError.numericLiteralTooLong(digits: digitCount)
        }
        var digits = Array(raw.utf8)[...]
        let negative = digits.first == 45 // -
        if negative { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
                debugDescription: "invalid big integer: \(raw.prefix(24))"))
        }
        // Leading zeros are not significant, so the cap does not bound them
        // and the conversion must not pay for them.
        let magnitude = BigUInt(decimalDigits: digits.drop { $0 == 48 }).bigEndianBytes
        return (magnitude, negative && !magnitude.isEmpty)
    }
}
