// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// The PXF decoder that holds one value rather than a list of entries. A
/// big-number type reads its literal through this: the `Decoder` protocol
/// has no way to ask for an integer of arbitrary length.
protocol _PXFValueHolder {
    var value: PXF.Value { get }
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

    /// Reads the message form only: PB, or a PXF block. The fields are
    /// stored and no value is computed. A PXF decimal literal is an error,
    /// not an empty message.
    public init(from decoder: Decoder) throws {
        self.init()
        if decoder is _PXFValueHolder {
            throw DecodingError.typeMismatch(Pxf_Decimal.self, .init(codingPath: decoder.codingPath,
                debugDescription: "PXF: pxf.Decimal literals are not implemented; use the block form"))
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

    /// Reads the message form only, as `Pxf_Decimal` does.
    public init(from decoder: Decoder) throws {
        self.init()
        if decoder is _PXFValueHolder {
            throw DecodingError.typeMismatch(Pxf_BigFloat.self, .init(codingPath: decoder.codingPath,
                debugDescription: "PXF: pxf.BigFloat literals are not implemented; use the block form"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mantissa = try c.decodeIfPresent(Data.self, forKey: .mantissa) ?? Data()
        exponent = Int32(truncatingIfNeeded: try c.decodeIfPresent(Int64.self, forKey: .exponent) ?? 0)
        prec = UInt32(truncatingIfNeeded: try c.decodeIfPresent(UInt64.self, forKey: .prec) ?? 0)
        negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
    }
}

extension PXF {
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
        let magnitude = bigEndianMagnitude(decimalDigits: digits.drop { $0 == 48 })
        return (magnitude, negative && !magnitude.isEmpty)
    }

    /// ASCII decimal digits to an unsigned big-endian magnitude, with no
    /// leading zero byte. Quadratic in the digit count, which is why the
    /// digit cap exists.
    private static func bigEndianMagnitude(decimalDigits digits: ArraySlice<UInt8>) -> Data {
        var limbs: [UInt32] = [] // base 2^32, least significant first
        var i = digits.startIndex
        while i < digits.endIndex {
            let end = min(i + 9, digits.endIndex) // 10^9 fits a limb
            var chunk: UInt64 = 0
            var multiplier: UInt64 = 1
            for d in digits[i..<end] {
                chunk = chunk * 10 + UInt64(d - 48)
                multiplier *= 10
            }
            var carry = chunk
            for j in limbs.indices {
                let product = UInt64(limbs[j]) * multiplier + carry
                limbs[j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            if carry != 0 { limbs.append(UInt32(carry)) }
            i = end
        }
        var out = Data()
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            for shift: UInt32 in [24, 16, 8, 0] {
                let byte = UInt8(truncatingIfNeeded: limb >> shift)
                if byte != 0 || !out.isEmpty { out.append(byte) }
            }
        }
        return out
    }
}
