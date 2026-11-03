// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// The big-number literals through the Codable bridge, which `ConformanceTests`
/// does not reach: it compares the schema-bound pass, and `H` here is what a
/// user declares.
final class PXFBigNumberTests: XCTestCase {
    struct H: Codable {
        var bf: Pxf_BigFloat?
        var count: Int32?
        enum CodingKeys: Int, CodingKey { case bf = 1, count = 2 }
    }

    private static let corpus = Bundle.module.resourceURL!.appendingPathComponent("testdata/conformance/corpus/bigfloat")

    private func encCases() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Self.corpus.path)
            .filter { $0.hasPrefix("enc-") && $0.hasSuffix(".binpb") }
            .map { String($0.dropLast(".binpb".count)) }
            .sorted()
    }

    /// Message bytes → the PXF text the corpus says an encoder writes.
    func testEveryEncoderCaseWritesItsText() throws {
        let cases = try encCases()
        XCTAssertEqual(cases.count, 13)
        for name in cases {
            let bytes = try Data(contentsOf: Self.corpus.appendingPathComponent(name + ".binpb"))
            let want = try String(contentsOf: Self.corpus.appendingPathComponent(name + ".pxf"), encoding: .utf8)
            let h = try PBDecoder().decode(H.self, from: bytes)
            XCTAssertEqual(try PXFEncoder().encode(h), want, name)
        }
    }

    /// The written text reads back as the value, through the Codable decoder.
    /// Each case's mantissa may be shorter than prec on the wire, so the
    /// comparison is of the literal, which is what the value is.
    func testEveryEncoderCaseReadsBack() throws {
        for name in try encCases() {
            let text = try String(contentsOf: Self.corpus.appendingPathComponent(name + ".pxf"), encoding: .utf8)
            let h = try PXFDecoder().decode(H.self, from: text)
            XCTAssertEqual(try PXFEncoder().encode(h), text, name)
        }
    }

    /// A literal → the bytes the reference marshalled, through the type a
    /// user declares and `PBEncoder`, not the schema-bound pass.
    func testTheReferenceBytesMatchThroughCodable() throws {
        let record = Self.corpus.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("reference.jsonl")
        var compared = 0
        for line in try String(contentsOf: record, encoding: .utf8).split(separator: "\n") {
            let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard r["suite"] as? String == "bigfloat", r["input"] as? String == "pxf", r["decode"] as? String == "accept",
                  let want = (r["pb"] as? [String])?.first, let file = r["file"] as? String else { continue }
            let text = try String(contentsOf: Self.corpus.appendingPathComponent(file), encoding: .utf8)
            let h = try PXFDecoder().decode(H.self, from: text.replacingOccurrences(of: "@type bf.v1.H", with: ""))
            let got = try PBEncoder().encode(h).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(got, want, file)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 30)
    }

    func testRoundingIsHalfEven() throws {
        // 1.5 at one bit is a tie between 1 and 2, and goes to 2. 2.5 at two
        // bits goes to 2.
        XCTAssertEqual(try PXF.parseBigFloat("1.5p1").pxfLiteral, "2p1")
        XCTAssertEqual(try PXF.parseBigFloat("2.5p2").pxfLiteral, "2p2")
        XCTAssertEqual(try PXF.parseBigFloat("3.5p2").pxfLiteral, "4p2")
        // Just above a tie is not a tie: the remainder has to count.
        XCTAssertEqual(try PXF.parseBigFloat("2.50000000000000000001p2").pxfLiteral, "3p2")
    }

    func testAnAbsurdExponentIsRefusedWithoutBeingComputed() {
        XCTAssertThrowsError(try PXF.parseBigFloat("1e999999999999"))
        XCTAssertThrowsError(try PXF.parseBigFloat("1e-999999999999"))
        XCTAssertThrowsError(try PXF.parseBigFloat("1e4933"))
        XCTAssertNoThrow(try PXF.parseBigFloat("0e999999999999"))
    }

    func testPrecisionDigits() {
        XCTAssertEqual(PXF.bigFloatDigits(53), 17)
        XCTAssertEqual(PXF.bigFloatDigits(64), 21)
        XCTAssertEqual(PXF.bigFloatDigits(13603), 4096)
        XCTAssertEqual(PXF.bigFloatDigits(13604), 4097)
        // One digit high in float64, the reference's own trap (pow2Digits).
        XCTAssertEqual(PXF.bigFloatDigits(146_964_308), 44_240_666)
    }

    func testBigIntAndDecimalLiterals() throws {
        struct N: Codable { var i: Pxf_BigInt?; var d: Pxf_Decimal? }
        let n = try PXFDecoder().decode(N.self, from: "i = -340282366920938463463374607431768211456\nd = -1.50")
        XCTAssertEqual(n.d?.scale, 2)
        XCTAssertEqual(n.d?.negative, true)
        XCTAssertEqual(try PXFEncoder().encode(n), "i = -340282366920938463463374607431768211456\nd = -1.50\n")
    }

    func testDecimalLiteralForms() throws {
        func text(_ unscaled: UInt8, _ scale: Int32) throws -> String {
            var d = Pxf_Decimal()
            d.unscaled = Data([unscaled])
            d.scale = scale
            return try d.pxfLiteral
        }
        XCTAssertEqual(try text(5, 2), "0.05")
        XCTAssertEqual(try text(5, -2), "500")
        XCTAssertThrowsError(try text(5, 5000))
        XCTAssertThrowsError(try text(5, -5000))
        XCTAssertThrowsError(try PXF.parseDecimal("1e5"), "a decimal has no exponent form")
    }

    func testBigUIntDivision() {
        let a = BigUInt(decimalDigits: Array("123456789012345678901234567890123456789012345678901234567890".utf8))
        let b = BigUInt(decimalDigits: Array("987654321098765432109876543210".utf8))
        let (q, r) = a.quotientAndRemainder(dividingBy: b)
        XCTAssertTrue(r.bitWidth <= b.bitWidth)
        // q × b + r = a, added in decimal so the check doesn't use what it checks.
        XCTAssertEqual(Self.add((q * b).decimalString, r.decimalString), a.decimalString)
        XCTAssertEqual((BigUInt.power(3, 1000) * BigUInt.power(7, 500)).quotientAndRemainder(dividingBy: BigUInt.power(7, 500)).quotient,
                       BigUInt.power(3, 1000))
    }

    func testASuffixElsewhereIsRefused() {
        struct F: Codable { var f: Double?; var i: Pxf_BigInt?; var d: Pxf_Decimal? }
        XCTAssertThrowsError(try PXFDecoder().decode(F.self, from: "f = 1.5p53"), "not read as 0")
        XCTAssertThrowsError(try PXFDecoder().decode(F.self, from: "i = 5p64"))
        XCTAssertThrowsError(try PXFDecoder().decode(F.self, from: "d = 1.5p64"))
    }

    private static func add(_ a: String, _ b: String) -> String {
        var x = Array(a.utf8.reversed()), y = Array(b.utf8.reversed())
        while x.count < y.count { x.append(48) }
        while y.count < x.count { y.append(48) }
        var out: [UInt8] = []
        var carry: UInt8 = 0
        for (p, q) in zip(x, y) {
            let v = p - 48 + q - 48 + carry
            out.append(v % 10 + 48)
            carry = v / 10
        }
        if carry != 0 { out.append(49) }
        return String(decoding: out.reversed(), as: UTF8.self)
    }
}
