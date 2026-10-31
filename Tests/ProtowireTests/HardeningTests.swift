// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// Regression tests for the HARDENING.md decoder-safety contract. These are
/// the inputs the cross-port adversarial corpus surfaces; once the conformance
/// gate flips to required this file plus the corpus run together.
final class HardeningTests: XCTestCase {

    // Mirrors the corpus's adversarial.v1.Tree.
    final class Tree: Codable {
        var child: Tree?
        var label: String?
        var children: [Tree]?
        var branches: [String: Tree]?
        var tags: [String: String]?
        enum CodingKeys: Int, CodingKey { case child = 1, label = 2, children = 3, branches = 4, tags = 5 }
    }

    struct StringHolder: Codable {
        var value: String?
        enum CodingKeys: Int, CodingKey { case value = 1 }
    }

    // Mirrors the corpus's adversarial.v1.BigNumHolder.
    struct BigNumHolder: Decodable {
        var big_int: Pxf_BigInt?
        var decimal: Pxf_Decimal?
        var big_float: Pxf_BigFloat?
        enum CodingKeys: Int, CodingKey { case big_int = 1, decimal = 2, big_float = 3 }
    }

    struct BigIntList: Decodable {
        var values: [Pxf_BigInt]
        enum CodingKeys: Int, CodingKey { case values = 1 }
    }

    // MARK: - PXF nesting depth

    func testPXFRejectsNestingOverLimit() throws {
        // 200 levels of `child{...}` exceeds MaxNestingDepth=100.
        var s = "@type adversarial.v1.Tree\n"
        for _ in 0..<200 { s += "child{" }
        for _ in 0..<200 { s += "}" }

        let dec = PXFDecoder()
        XCTAssertThrowsError(try dec.decode(Tree.self, from: Data(s.utf8))) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    func testPXFAcceptsNestingAtBaseline() throws {
        // 10 levels is well below the limit and must round-trip.
        var s = "@type adversarial.v1.Tree\n"
        for _ in 0..<10 { s += "child{" }
        for _ in 0..<10 { s += "}" }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: Data(s.utf8)))
    }

    /// A map's `{` is a descent and so is its value's, so 50 `branches` levels
    /// are exactly the bound (protowire#449).
    func testPXFCountsAMapsBraceAtTheBound() {
        func doc(pairs: Int, extra: Int) -> String {
            String(repeating: "branches = { k: { ", count: pairs) + String(repeating: "child { ", count: extra)
                + "label = \"x\"" + String(repeating: " }", count: extra) + String(repeating: " } }", count: pairs)
        }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: doc(pairs: 50, extra: 0)))
        assertDepthExceeded(try PXFDecoder().decode(Tree.self, from: doc(pairs: 50, extra: 1)))
    }

    /// A scalar-valued map has no message under it, and its `{` still counts.
    func testPXFCountsAScalarMapsBraceAtTheBound() {
        func doc(blocks: Int) -> String {
            String(repeating: "child { ", count: blocks) + "tags = { k: \"v\" }" + String(repeating: " }", count: blocks)
        }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: doc(blocks: 99)))
        assertDepthExceeded(try PXFDecoder().decode(Tree.self, from: doc(blocks: 100)))
    }

    // MARK: - PXF UTF-8 strictness

    func testPXFRejectsInvalidUTF8InStringLiteral() {
        // \xFF\xFE is not valid UTF-8; per HARDENING.md § UTF-8 the lossy
        // U+FFFD substitution path is forbidden.
        let s = "@type adversarial.v1.StringHolder\nvalue = \"\\xFF\\xFE\"\n"
        XCTAssertThrowsError(try PXFDecoder().decode(StringHolder.self, from: Data(s.utf8)))
    }

    // MARK: - PXF numeric literal digit cap

    func testPXFBigIntAtDigitCapDecodesToValue() throws {
        let literal = digits(Hardening.maxNumericLiteralDigits)
        let big = try bigInt(literal)
        XCTAssertEqual(decimalString(big.abs), literal)
        XCTAssertFalse(big.negative)
    }

    func testPXFBigIntOneDigitPastCapIsRejectedNamingTheLimit() {
        let literal = digits(Hardening.maxNumericLiteralDigits + 1)
        XCTAssertThrowsError(try bigInt(literal)) { err in
            guard case DecoderError.numericLiteralTooLong(let n) = err else {
                return XCTFail("expected numericLiteralTooLong, got \(err)")
            }
            XCTAssertEqual(n, 4097)
            XCTAssertEqual(String(describing: err),
                           "numeric literal has 4097 digits; MaxNumericLiteralDigits=4096")
        }
    }

    func testPXFBigIntSignIsNotADigit() throws {
        let literal = digits(Hardening.maxNumericLiteralDigits)
        let big = try bigInt("-" + literal)
        XCTAssertEqual(decimalString(big.abs), literal)
        XCTAssertTrue(big.negative)
        XCTAssertThrowsError(try bigInt("-" + digits(Hardening.maxNumericLiteralDigits + 1)))
    }

    func testPXFBigIntLeadingZerosAreNotSignificant() throws {
        let literal = digits(Hardening.maxNumericLiteralDigits)
        let big = try bigInt(String(repeating: "0", count: 5000) + literal)
        XCTAssertEqual(decimalString(big.abs), literal)
        XCTAssertThrowsError(try bigInt("0" + digits(Hardening.maxNumericLiteralDigits + 1)))
    }

    func testPXFBigIntMagnitudeVectors() throws {
        XCTAssertEqual(try bigInt("0").abs, Data())
        XCTAssertEqual(try bigInt("000").abs, Data())
        XCTAssertEqual(try bigInt("255").abs, Data([0xff]))
        XCTAssertEqual(try bigInt("256").abs, Data([0x01, 0x00]))
        XCTAssertEqual(try bigInt("1000000000").abs, Data([0x3b, 0x9a, 0xca, 0x00]))
        // 2^64: a magnitude no fixed-width integer here holds.
        XCTAssertEqual(try bigInt("18446744073709551616").abs,
                       Data([0x01, 0, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testPXFBigIntNegativeZeroIsNotNegative() throws {
        XCTAssertFalse(try bigInt("-0").negative)
    }

    func testPXFBigIntCapAppliesToListElements() throws {
        let at = "@type t\nvalues = [ \(digits(Hardening.maxNumericLiteralDigits)) ]\n"
        XCTAssertEqual(try PXFDecoder().decode(BigIntList.self, from: at).values.count, 1)
        let past = "@type t\nvalues = [ \(digits(Hardening.maxNumericLiteralDigits + 1)) ]\n"
        XCTAssertThrowsError(try PXFDecoder().decode(BigIntList.self, from: past)) { err in
            guard case DecoderError.numericLiteralTooLong = err else {
                return XCTFail("expected numericLiteralTooLong, got \(err)")
            }
        }
    }

    func testPXFBigIntRejectsANonIntegerValue() {
        for value in ["1.5", "\"12\"", "true"] {
            XCTAssertThrowsError(try PXFDecoder().decode(BigNumHolder.self, from: "big_int = \(value)\n"), value)
        }
    }

    func testPXFBigIntBlockFormHasNoDigitCap() throws {
        let holder = try PXFDecoder().decode(BigNumHolder.self, from: "big_int { abs = b\"AQA=\" negative = true }\n")
        XCTAssertEqual(holder.big_int?.abs, Data([0x01, 0x00]))
        XCTAssertEqual(holder.big_int?.negative, true)
    }

    func testPXFDecimalAndBigFloatLiteralsAreNotSilentlyEmpty() {
        XCTAssertThrowsError(try PXFDecoder().decode(BigNumHolder.self, from: "decimal = 1.50\n"))
        XCTAssertThrowsError(try PXFDecoder().decode(BigNumHolder.self, from: "big_float = 1.5\n"))
    }

    func testSignificantDigitsCountsTheMantissaOnly() {
        XCTAssertEqual(Hardening.significantDigits("0"), 0)
        XCTAssertEqual(Hardening.significantDigits("-007"), 1)
        XCTAssertEqual(Hardening.significantDigits("100"), 3)
        XCTAssertEqual(Hardening.significantDigits("0.00120e45"), 3)
        XCTAssertEqual(Hardening.significantDigits("1.5E+10"), 2)
        XCTAssertEqual(Hardening.significantDigits("12p53"), 2)
    }

    func testPBBigIntOverTheCapIsAccepted() throws {
        // BigInt.abs is bounded on the wire only by MaxMessageSize: 5000
        // digits is valid PB with no PXF spelling (HARDENING.md § Mandatory limits).
        let abs = Data(repeating: 0xff, count: 2100)
        let wire = encodeLenDelim(field: 1, payload: encodeLenDelim(field: 1, payload: abs))
        XCTAssertEqual(try PBDecoder().decode(BigNumHolder.self, from: wire).big_int?.abs, abs)
    }

    // MARK: - PB nesting depth

    func testPBRejectsSubmessageNestingOverLimit() throws {
        // Build N nested length-delimited Tree submessages: tag=1 wire=2.
        var data = Data()
        for _ in 0..<200 {
            // length placeholder filled below
            data = encodeLenDelim(field: 1, payload: data)
        }
        XCTAssertThrowsError(try PBDecoder().decode(Tree.self, from: data)) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    /// A map entry is a descent and so is a message value inside it, so 50
    /// `branches` levels are exactly the bound (protowire#449).
    func testPBCountsAMapEntryAndItsMessageValueAtTheBound() {
        func message(pairs: Int, extra: Int) -> Data {
            var data = Data()
            for _ in 0..<extra { data = encodeLenDelim(field: 1, payload: data) }
            for _ in 0..<pairs { data = encodeLenDelim(field: 4, payload: mapEntry(value: data)) }
            return data
        }
        XCTAssertNoThrow(try PBDecoder().decode(Tree.self, from: message(pairs: 50, extra: 0)))
        assertDepthExceeded(try PBDecoder().decode(Tree.self, from: message(pairs: 50, extra: 1)))
    }

    /// A scalar-valued entry recurses into nothing, and it is still a descent.
    func testPBCountsAScalarMapEntryAtTheBound() {
        func message(submessages: Int) -> Data {
            var data = encodeLenDelim(field: 5, payload: mapEntry(value: Data("v".utf8)))
            for _ in 0..<submessages { data = encodeLenDelim(field: 1, payload: data) }
            return data
        }
        XCTAssertNoThrow(try PBDecoder().decode(Tree.self, from: message(submessages: 99)))
        assertDepthExceeded(try PBDecoder().decode(Tree.self, from: message(submessages: 100)))
    }

    // MARK: - PB length-prefix bounds

    func testPBRejectsTruncatedLengthPrefix() {
        // tag=1 (string), declared length = 100, no payload.
        let data = Data([0x0a, 0x64])
        XCTAssertThrowsError(try PBDecoder().decode(StringHolder.self, from: data))
    }

    func testPBRejectsLengthPrefixOverflow() {
        // tag=1, length = 2^64-1 (max 10-byte varint). Pre-fix this trapped
        // on the `Int(_:)` conversion; post-fix it must surface as a clean error.
        let data = Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
        XCTAssertThrowsError(try PBDecoder().decode(StringHolder.self, from: data))
    }

    // MARK: - helpers

    private func assertDepthExceeded<T>(_ expression: @autoclosure () throws -> T, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)", line: line)
            }
        }
    }

    /// A `map<string, _>` entry with key "k" and the given length-delimited value.
    private func mapEntry(value: Data) -> Data {
        encodeLenDelim(field: 1, payload: Data("k".utf8)) + encodeLenDelim(field: 2, payload: value)
    }

    /// `count` decimal digits with no leading zero, varied so a limb bug shows.
    private func digits(_ count: Int) -> String {
        var ascii = [UInt8]()
        ascii.reserveCapacity(count)
        for i in 0..<count {
            let digit: Int = (1 + i * i + i / 7) % 9
            ascii.append(UInt8(48 + digit))
        }
        return String(decoding: ascii, as: UTF8.self)
    }

    private func bigInt(_ literal: String) throws -> Pxf_BigInt {
        let doc = "@type adversarial.v1.BigNumHolder\n\nbig_int = \(literal)\n"
        // Outside XCTUnwrap, which would record a throw as a test failure.
        let holder = try PXFDecoder().decode(BigNumHolder.self, from: doc)
        return try XCTUnwrap(holder.big_int)
    }

    /// The other direction of the conversion, by repeated division, so a
    /// magnitude is checked by an algorithm that shares nothing with the parser.
    private func decimalString(_ magnitude: Data) -> String {
        var bytes = Array(magnitude)
        var out: [UInt8] = []
        while !bytes.isEmpty {
            var remainder = 0
            var quotient: [UInt8] = []
            for b in bytes {
                let v = remainder * 256 + Int(b)
                if !quotient.isEmpty || v / 10 != 0 { quotient.append(UInt8(v / 10)) }
                remainder = v % 10
            }
            out.append(UInt8(48 + remainder))
            bytes = quotient
        }
        return out.isEmpty ? "0" : String(decoding: out.reversed(), as: UTF8.self)
    }

    /// Wraps `payload` as a length-delimited field with tag=`field` (wire=2).
    private func encodeLenDelim(field: Int, payload: Data) -> Data {
        var out = Data()
        Protowire.appendTag(&out, number: Int32(field), type: .bytes)
        Protowire.appendBytes(&out, payload)
        return out
    }
}
