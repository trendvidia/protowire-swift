// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf
import XCTest
@testable import Protowire

/// `PXF.BigInt`, `PXF.Decimal` and `PXF.BigFloat`, the language values for the
/// pxf big-number messages (#71).
final class PXFNumbersTests: XCTestCase {
    struct Numbers: Codable, Equatable {
        var i: PXF.BigInt?
        var d: PXF.Decimal?
        var f: PXF.BigFloat?
        enum CodingKeys: Int, CodingKey { case i = 1, d, f }
    }
    struct Plain: Codable, Equatable {
        var d: PXF.Decimal
        enum CodingKeys: Int, CodingKey { case d = 1 }
    }
    struct Lists: Codable, Equatable {
        var ds: [PXF.Decimal]
        var fs: [String: PXF.BigFloat]
        enum CodingKeys: Int, CodingKey { case ds = 1, fs }
    }

    private func dec(_ unscaled: Int, _ scale: Int) throws -> PXF.Decimal {
        try PXF.Decimal(unscaled: PXF.BigInt(unscaled), scale: scale)
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    private func pb<T: Encodable>(_ v: T) throws -> String { hex(try PBEncoder().encode(v)) }

    // MARK: - Reduction and equality

    func testReducedForm() throws {
        let cases: [(PXF.Decimal, Int, Int)] = [
            (try dec(100, 2), 1, 0), (try dec(1500, 2), 15, 0), (try dec(-150, 2), -15, 1),
            (try dec(5, -2), 500, 0), (try dec(0, 2), 0, 0), (try dec(31415, 4), 31415, 4),
            (try dec(120, -1), 1200, 0),
        ]
        for (value, unscaled, scale) in cases {
            let r = value.reduced
            XCTAssertEqual(Int(exactly: r.unscaled), unscaled, "\(value)")
            XCTAssertEqual(r.scale, scale, "\(value)")
        }
    }

    func testDecimalEqualityIsByValue() throws {
        XCTAssertEqual(try dec(100, 2), try dec(10, 1))
        XCTAssertEqual(try dec(100, 2), PXF.Decimal(1))
        XCTAssertEqual(try dec(5, -2), PXF.Decimal(500))
        XCTAssertEqual(Set([try dec(100, 2), try dec(1, 0), try dec(10, 1)]).count, 1)
        XCTAssertNotEqual(try dec(15, 1), try dec(-15, 1))
        XCTAssertEqual(try dec(0, 3), PXF.Decimal())
        // The scale is kept for the literal.
        XCTAssertEqual(try dec(100, 2).description, "1.00")
        XCTAssertEqual(try dec(-5, 1).description, "-0.5")
        XCTAssertEqual(try dec(5, -2).description, "500")
        XCTAssertEqual(try dec(0, 2).description, "0.00")
        XCTAssertEqual(try dec(7, 3).description, "0.007")
    }

    func testAZeroHasNoSign() throws {
        let negativeZero = try PXF.Decimal(pxfLiteral: "-0.00")
        XCTAssertFalse(negativeZero.isNegative)
        XCTAssertEqual(negativeZero.description, "0.00")
        XCTAssertFalse(try PXF.BigInt(pxfLiteral: "-0").isNegative)
        // A BigFloat zero keeps its sign and precision, as the draft says.
        let f = try PXF.BigFloat(pxfLiteral: "-0p53")
        XCTAssertTrue(f.isNegative)
        XCTAssertEqual(f.precision, 53)
        XCTAssertNotEqual(f, try PXF.BigFloat(pxfLiteral: "0p53"))
    }

    func testBigFloatEqualityIncludesPrecision() throws {
        XCTAssertEqual(PXF.BigFloat(1.5)!, try PXF.BigFloat(pxfLiteral: "1.5p53"))
        XCTAssertNotEqual(PXF.BigFloat(1.5)!, PXF.BigFloat(1.5, precision: 64)!)
        XCTAssertEqual(PXF.BigFloat(1.5, precision: 64)!.description, "1.5p64")
        // Rounded to the precision, ties to even: 0.1 at 4 bits is 0.1015625.
        XCTAssertEqual(PXF.BigFloat(0.1, precision: 4)!, PXF.BigFloat(0.1015625, precision: 4)!)
        XCTAssertNil(PXF.BigFloat(Double.infinity))
        XCTAssertNil(PXF.BigFloat(Double.nan))
        XCTAssertNil(PXF.BigFloat(1.0, precision: 0))
        XCTAssertEqual(PXF.BigFloat(0.0, precision: 0), PXF.BigFloat())
    }

    // MARK: - PBEncoder

    func testPBWritesTheReducedForm() throws {
        XCTAssertEqual(try pb(Numbers(d: try dec(100, 2))), "12030a0101")
        XCTAssertEqual(try pb(Numbers(d: try dec(5, -2))), "12040a0201f4")
        XCTAssertEqual(try pb(Numbers(d: try dec(-150, 2))), "12070a010f10011801")
        // Top level: the message itself.
        XCTAssertEqual(try pb(try dec(1500, 2)), "0a010f")
        XCTAssertEqual(try pb(PXF.BigInt(-1)), "0a01011001")
    }

    func testPBLeavesAZeroFieldOutAndWritesAZeroElement() throws {
        XCTAssertEqual(try pb(Numbers(i: PXF.BigInt(0), d: try dec(0, 2), f: PXF.BigFloat())), "")
        XCTAssertEqual(try pb(Plain(d: PXF.Decimal())), "")
        XCTAssertEqual(try pb(Lists(ds: [PXF.Decimal(), PXF.Decimal(1)], fs: ["k": PXF.BigFloat()])),
                       "0a000a030a0101" + "12050a016b1200")
        // A BigFloat field is left out only at +0 and precision 0: -0 there
        // is {negative: true}, and a zero at a precision keeps it.
        XCTAssertEqual(try pb(Numbers(f: try PXF.BigFloat(pxfLiteral: "-0"))), "1a022001")
        XCTAssertEqual(try pb(Numbers(f: try PXF.BigFloat(pxfLiteral: "0p53"))), "1a021835")
    }

    func testPBWritesTheBigFloatMantissaAtItsPrecision() throws {
        let m = try PXF.BigFloat(1.5, precision: 64)!.message
        XCTAssertEqual(hex(m.mantissa), "c000000000000000")
        XCTAssertEqual(m.exponent, -63)
        XCTAssertEqual(m.prec, 64)
    }

    func testPBRefusesABigFloatNoReaderAccepts() throws {
        XCTAssertThrowsError(try PBEncoder().encode(Numbers(f: PXF.BigFloat(1, precision: 13604))))
        XCTAssertNoThrow(try PBEncoder().encode(Numbers(f: PXF.BigFloat(1, precision: 13603))))
        let past = try PXF.BigFloat(Pxf_BigFloat.with { $0.mantissa = Data([1]); $0.exponent = 16383; $0.prec = 8 })
        XCTAssertNoThrow(try past.message)
        XCTAssertThrowsError(try PBEncoder().encode(Numbers(f: try PXF.BigFloat(
            Pxf_BigFloat.with { $0.mantissa = Data([1]); $0.exponent = 16384; $0.prec = 8 }, limits: .init(maxBigFloatExponent: 1 << 20)))))
    }

    /// The generated message is a message: written as it is, scale and all.
    func testTheGeneratedMessageIsWrittenAsItIs() throws {
        struct Message: Encodable {
            var d: Pxf_Decimal
            enum CodingKeys: Int, CodingKey { case d = 1 }
        }
        var d = Pxf_Decimal()
        d.unscaled = Data([100])
        d.scale = 2
        XCTAssertEqual(try pb(Message(d: d)), "0a050a01641002")
    }

    // MARK: - PBDecoder

    func testPBReadsEveryForm() throws {
        let decoder = PBDecoder()
        // Unscaled 100 at scale 2 reads as 1.00, the same number as 1.
        let n = try decoder.decode(Numbers.self, from: bytes("12050a01641002"))
        XCTAssertEqual(n.d, PXF.Decimal(1))
        XCTAssertEqual(n.d?.description, "1.00")
        XCTAssertEqual(try decoder.decode(Plain.self, from: Data()).d, PXF.Decimal())
        for v in [Numbers(i: PXF.BigInt(-12345), d: try dec(-150, 2), f: PXF.BigFloat(-1.5)),
                  Numbers(f: try PXF.BigFloat(pxfLiteral: "-0")), Numbers(f: try PXF.BigFloat(pxfLiteral: "0p53"))] {
            XCTAssertEqual(try decoder.decode(Numbers.self, from: try PBEncoder().encode(v)), v)
        }
        let lists = Lists(ds: [PXF.Decimal(), try dec(25, 1)], fs: ["a": PXF.BigFloat(2.5)!, "z": PXF.BigFloat()])
        XCTAssertEqual(try decoder.decode(Lists.self, from: try PBEncoder().encode(lists)), lists)
    }

    func testPBDecodeLimits() throws {
        func decimal(scale: Int32) -> Data {
            var inner = Data([0x0A, 0x01, 0x01, 0x10])
            Protowire.appendVarint(&inner, UInt64(bitPattern: Int64(scale)))
            var out = Data([0x12])
            Protowire.appendVarint(&out, UInt64(inner.count))
            return out + inner
        }
        XCTAssertNoThrow(try PBDecoder().decode(Numbers.self, from: decimal(scale: 4096)))
        XCTAssertNoThrow(try PBDecoder().decode(Numbers.self, from: decimal(scale: -4096)))
        for scale: Int32 in [4097, -4097, .max, .min] {
            XCTAssertThrowsError(try PBDecoder().decode(Numbers.self, from: decimal(scale: scale)), "\(scale)")
        }
        let lowered = PBDecoder()
        lowered.limits.maxNumericLiteralDigits = 3
        XCTAssertNoThrow(try lowered.decode(Numbers.self, from: decimal(scale: 3)))
        XCTAssertThrowsError(try lowered.decode(Numbers.self, from: decimal(scale: 4)))

        func bigFloat(exponent: Int32, prec: UInt32) -> Data {
            var inner = Data([0x0A, 0x01, 0x01, 0x10])
            Protowire.appendVarint(&inner, UInt64(bitPattern: Int64(exponent)))
            inner.append(0x18)
            Protowire.appendVarint(&inner, UInt64(prec))
            var out = Data([0x1A])
            Protowire.appendVarint(&out, UInt64(inner.count))
            return out + inner
        }
        XCTAssertNoThrow(try PBDecoder().decode(Numbers.self, from: bigFloat(exponent: 16383, prec: 8)))
        XCTAssertThrowsError(try PBDecoder().decode(Numbers.self, from: bigFloat(exponent: 16384, prec: 8))) { err in
            guard case DecoderError.bigFloatExponentExceeded = err else { return XCTFail("got \(err)") }
        }
        XCTAssertNoThrow(try PBDecoder().decode(Numbers.self, from: bigFloat(exponent: 0, prec: 13603)))
        XCTAssertThrowsError(try PBDecoder().decode(Numbers.self, from: bigFloat(exponent: 0, prec: 13604)))
        XCTAssertThrowsError(try PBDecoder().decode(Numbers.self, from: bigFloat(exponent: 0, prec: .max)))
        lowered.limits.maxBigFloatExponent = 10
        XCTAssertThrowsError(try lowered.decode(Numbers.self, from: bigFloat(exponent: 10, prec: 8)))
    }

    // MARK: - PXF

    func testPXFRoundTrip() throws {
        let doc = "i = -12345678901234567890\nd = 1.00\nf = 1.5p64\n"
        let v = try PXFDecoder().decode(Numbers.self, from: doc)
        XCTAssertEqual(v.i?.description, "-12345678901234567890")
        XCTAssertEqual(v.d?.scale, 2)
        XCTAssertEqual(v.f, PXF.BigFloat(1.5, precision: 64))
        let text = try PXFEncoder().encode(v)
        XCTAssertTrue(text.contains("d = 1.00"), text)
        XCTAssertTrue(text.contains("f = 1.5p64"), text)
        XCTAssertTrue(text.contains("i = -12345678901234567890"), text)
        XCTAssertEqual(try PXFDecoder().decode(Numbers.self, from: text), v)

        let lists = Lists(ds: [try dec(0, 2), try dec(-25, 1)], fs: ["z": try PXF.BigFloat(pxfLiteral: "-0p53")])
        let listText = try PXFEncoder().encode(lists)
        XCTAssertEqual(try PXFDecoder().decode(Lists.self, from: listText), lists)
        XCTAssertEqual(try PXFDecoder().decode(Lists.self, from: listText).ds.map(\.description), ["0.00", "-2.5"])
    }

    func testPXFReadsTheBlockForm() throws {
        let v = try PXFDecoder().decode(Numbers.self, from: "d { unscaled = b\"ZA==\" scale = 2 }\ni { abs = b\"Bw==\" negative = true }\n")
        XCTAssertEqual(v.d?.description, "1.00")
        XCTAssertEqual(v.i, PXF.BigInt(-7))
    }

    func testPXFRefusesWhatIsNotANumber() throws {
        XCTAssertThrowsError(try PXFDecoder().decode(Numbers.self, from: "d = \"1.5\""))
        XCTAssertThrowsError(try PXFDecoder().decode(Numbers.self, from: "i = 1.5"))
        XCTAssertThrowsError(try PXFDecoder().decode(Numbers.self, from: "d = 1.5p53"))
        XCTAssertThrowsError(try PXFDecoder().decode(Numbers.self, from: "i = 1p53"))
    }

    func testPXFLiteralsFollowTheCallsLimits() throws {
        let lowered = PXFDecoder()
        lowered.limits.maxNumericLiteralDigits = 5
        for doc in ["i = 123456", "d = 1.23456", "f = 1.23456"] {
            XCTAssertNoThrow(try PXFDecoder().decode(Numbers.self, from: doc), doc)
            XCTAssertThrowsError(try lowered.decode(Numbers.self, from: doc), doc) { err in
                guard case DecoderError.numericLiteralTooLong(6, 5) = err else { return XCTFail("\(doc): got \(err)") }
            }
        }
        lowered.limits.maxBigFloatExponent = 8
        XCTAssertThrowsError(try lowered.decode(Numbers.self, from: "f = 1e3"))
    }

    func testPXFRefusesALiteralNoReaderAccepts() throws {
        // A BigInt whose digits are past the cap, from PB, where its bytes
        // have no digit bound.
        let wide = PXF.BigInt(negative: false, magnitude: Data(repeating: 0xFF, count: 1800)) // 4335 digits
        XCTAssertThrowsError(try PXFEncoder().encode(Numbers(i: wide)))
    }

    // MARK: - Conversions

    func testIntegerConversions() throws {
        XCTAssertEqual(Int64(exactly: PXF.BigInt(Int64.min)), .min)
        XCTAssertEqual(UInt64(exactly: PXF.BigInt(UInt64.max)), .max)
        XCTAssertEqual(Int8(exactly: PXF.BigInt(-128)), -128)
        XCTAssertNil(Int8(exactly: PXF.BigInt(128)))
        XCTAssertNil(UInt8(exactly: PXF.BigInt(-1)))
        XCTAssertNil(Int64(exactly: PXF.BigInt(UInt64.max)))
        XCTAssertEqual(PXF.BigInt(UInt64.max).description, "18446744073709551615")
        XCTAssertEqual(Int(exactly: try dec(100, 2)), 1)
        XCTAssertEqual(Int(exactly: try dec(5, -2)), 500)
        XCTAssertNil(Int(exactly: try dec(150, 2)))
        XCTAssertEqual(Int(exactly: PXF.BigFloat(3.0)!), 3)
        XCTAssertEqual(Int(exactly: PXF.BigFloat(Int(-1024))), -1024)
        XCTAssertNil(Int(exactly: PXF.BigFloat(1.5)!))
        XCTAssertNil(Int8(exactly: PXF.BigFloat(Int(256))))
        XCTAssertEqual(Int8(exactly: PXF.BigFloat(Int(-128))), -128)
        XCTAssertEqual(PXF.BigFloat(Int(-1024)).precision, 64)
        XCTAssertEqual(PXF.BigFloat(UInt64.max, precision: 8), PXF.BigFloat(Double(UInt64.max), precision: 8))
    }

    func testFoundationDecimal() throws {
        let nines38 = String(repeating: "9", count: 38)
        let max128 = "340282366920938463463374607431768211455" // 2^128 - 1, 39 digits
        for text in [nines38, "-" + nines38, max128, "0.\(nines38)", "-1.25", "0", "1.00"] {
            let v = try PXF.Decimal(pxfLiteral: text)
            let f = try XCTUnwrap(Foundation.Decimal(exactly: v), text)
            XCTAssertEqual(PXF.Decimal(exactly: f), v, text)
            if text != max128 { // Foundation's parser stops at 38 digits
                XCTAssertEqual(f, Foundation.Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), text)
            }
        }
        for text in [String(repeating: "9", count: 39), "340282366920938463463374607431768211456",
                     "1." + String(repeating: "0", count: 128) + "1"] {
            XCTAssertNil(Foundation.Decimal(exactly: try PXF.Decimal(pxfLiteral: text)), text)
        }
        // An exponent past 127 comes back by scaling the significand.
        let big = try PXF.Decimal(unscaled: PXF.BigInt(5), scale: -130)
        let f = try XCTUnwrap(Foundation.Decimal(exactly: big))
        XCTAssertEqual(PXF.Decimal(exactly: f), big)
        XCTAssertNil(PXF.Decimal(exactly: Foundation.Decimal.nan))
        XCTAssertEqual(PXF.Decimal(exactly: Foundation.Decimal(string: "-12.50")!), try dec(-125, 1))
    }

    func testConstructionBounds() throws {
        XCTAssertNoThrow(try dec(1, 4096))
        XCTAssertNoThrow(try dec(1, -4096))
        XCTAssertThrowsError(try dec(1, 4097))
        XCTAssertThrowsError(try dec(1, -4097))
    }

    // MARK: - Other coders

    func testJSONUsesTheLiteral() throws {
        let v = Numbers(i: PXF.BigInt(-3), d: try dec(100, 2), f: PXF.BigFloat(1.5)!)
        let json = try JSONEncoder().encode(v)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"1.00\""), text)
        XCTAssertTrue(text.contains("\"1.5p53\""), text)
        XCTAssertEqual(try JSONDecoder().decode(Numbers.self, from: json), v)
    }
}
