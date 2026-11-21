// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import XCTest
@testable import Protowire

/// `SInt32` and `SInt64` mark a field `sint32` / `sint64`: zigzag on the
/// protobuf wire, a plain integer everywhere else (#70). Each expected hex
/// string is what protowire-go writes for the same field tagged `zigzag`.
final class PBSIntTests: XCTestCase {
    struct Pair: Codable, Equatable {
        var d: SInt64, e: SInt32
        enum CodingKeys: Int, CodingKey { case d = 1, e }
    }
    struct Optionals: Codable, Equatable {
        var d: SInt64?, e: SInt32?
        enum CodingKeys: Int, CodingKey { case d = 1, e }
    }
    struct Lists: Codable, Equatable {
        var ds: [SInt64], es: [SInt32]
        enum CodingKeys: Int, CodingKey { case ds = 1, es }
    }
    struct Maps: Codable, Equatable {
        var byKey: [SInt32: String], byValue: [String: SInt64], both: [SInt64: SInt32]
        enum CodingKeys: Int, CodingKey { case byKey = 1, byValue, both }
    }

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ h: String) -> Data {
        var out = Data()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            out.append(UInt8(h[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testValueType() {
        let a: SInt64 = -3
        XCTAssertEqual(a.value, -3)
        XCTAssertEqual(a, SInt64(-3))
        XCTAssertLessThan(SInt32(-1), SInt32(0))
        XCTAssertEqual("\(SInt32(-7))", "-7")
        XCTAssertEqual(Set([SInt64(1), 1, 2]).count, 2)
        // Any other coder sees a plain integer.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([SInt64(-1)]), as: UTF8.self), "[-1]")
    }

    func testSingular() throws {
        let v = Pair(d: -1, e: -2)
        let data = try PBEncoder().encode(v)
        XCTAssertEqual(hex(data), "08011003")
        XCTAssertEqual(try PBDecoder().decode(Pair.self, from: data), v)
        // Positive values double: 1 -> 2, 64 -> 128.
        XCTAssertEqual(hex(try PBEncoder().encode(Pair(d: 64, e: 1))), "088001" + "1002")
    }

    /// The zero rule of #52: a non-optional zero is not written, an Optional
    /// zero is, and an absent field reads as zero or nil.
    func testZeroAndOptionalZero() throws {
        XCTAssertEqual(try PBEncoder().encode(Pair(d: 0, e: 0)), Data())
        XCTAssertEqual(try PBDecoder().decode(Pair.self, from: Data()), Pair(d: 0, e: 0))

        let zeros = Optionals(d: 0, e: 0)
        let data = try PBEncoder().encode(zeros)
        XCTAssertEqual(hex(data), "08001000")
        XCTAssertEqual(try PBDecoder().decode(Optionals.self, from: data), zeros)

        XCTAssertEqual(try PBEncoder().encode(Optionals(d: nil, e: nil)), Data())
        XCTAssertEqual(try PBDecoder().decode(Optionals.self, from: Data()), Optionals(d: nil, e: nil))
        XCTAssertEqual(try PBDecoder().decode(Optionals.self, from: bytes("1003")), Optionals(d: nil, e: -2))
    }

    func testBounds() throws {
        let v = Pair(d: SInt64(.min), e: SInt32(.max))
        let data = try PBEncoder().encode(v)
        XCTAssertEqual(hex(data), "08ffffffffffffffffff01" + "10feffffff0f")
        XCTAssertEqual(try PBDecoder().decode(Pair.self, from: data), v)

        let w = Pair(d: SInt64(.max), e: SInt32(.min))
        let wdata = try PBEncoder().encode(w)
        XCTAssertEqual(hex(wdata), "08feffffffffffffffff01" + "10ffffffff0f")
        XCTAssertEqual(try PBDecoder().decode(Pair.self, from: wdata), w)
    }

    /// A zigzag value past 32 bits does not fit sint32, and is an error as an
    /// over-wide int32 is, not a truncation.
    func testSInt32OutOfRangeThrows() {
        // zigzag(2^31) = 2^32: 80 80 80 80 10.
        XCTAssertThrowsError(try PBDecoder().decode(Pair.self, from: bytes("108080808010")))
    }

    func testPackedRepeated() throws {
        let v = Lists(ds: [1, 0, -1, -64, 64], es: [-2, 0, SInt32(.min)])
        let data = try PBEncoder().encode(v)
        // zigzag: 2 00 01 7f 8001 | 03 00 ffffffff0f
        XCTAssertEqual(hex(data), "0a060200017f8001" + "120703" + "00ffffffff0f")
        XCTAssertEqual(try PBDecoder().decode(Lists.self, from: data), v)
        XCTAssertEqual(try PBEncoder().encode(Lists(ds: [], es: [])), Data())
    }

    /// A reader takes the unpacked form too: one record per element.
    func testUnpackedRepeatedDecodes() throws {
        let got = try PBDecoder().decode(Lists.self, from: bytes("0801" + "0802" + "1003"))
        XCTAssertEqual(got, Lists(ds: [-1, 1], es: [-2]))
    }

    func testMapKeyAndValue() throws {
        let v = Maps(byKey: [-1: "a"], byValue: ["k": -2], both: [-3: 0])
        let data = try PBEncoder().encode(v)
        // Entries keep both fields, zero or not (protowire#295).
        XCTAssertEqual(hex(data),
                       "0a05" + "0801" + "1201" + "61"     // {-1: "a"}
                       + "1205" + "0a01" + "6b" + "1003"   // {"k": -2}
                       + "1a04" + "0805" + "1000")         // {-3: 0}
        XCTAssertEqual(try PBDecoder().decode(Maps.self, from: data), v)
    }

    func testPXFRoundTrip() throws {
        struct Doc: Codable, Equatable {
            var d: SInt64, e: SInt32, o: SInt32?, ds: [SInt64], m: [SInt32: SInt64]
        }
        let v = Doc(d: SInt64(.min), e: SInt32(.max), o: -1, ds: [-1, 2], m: [-5: 7])
        let text = try PXFEncoder().encode(v)
        XCTAssertTrue(text.contains("d = -9223372036854775808\n"), text)
        XCTAssertTrue(text.contains("e = 2147483647\n"), text)
        XCTAssertTrue(text.contains("o = -1\n"), text)
        XCTAssertTrue(text.contains("-5: 7"), text)
        XCTAssertEqual(try PXFDecoder().decode(Doc.self, from: text), v)
    }

    func testPXFRangeErrorsThrow() {
        struct Doc: Decodable { var e: SInt32 }
        struct Wide: Decodable { var d: SInt64 }
        struct Keyed: Decodable { var m: [SInt32: String] }
        XCTAssertThrowsError(try PXFDecoder().decode(Doc.self, from: "e = 2147483648\n"))
        XCTAssertThrowsError(try PXFDecoder().decode(Doc.self, from: "e = -2147483649\n"))
        XCTAssertThrowsError(try PXFDecoder().decode(Wide.self, from: "d = 9223372036854775808\n"))
        XCTAssertThrowsError(try PXFDecoder().decode(Keyed.self, from: "m = { 2147483648: \"x\" }\n"))
        XCTAssertNoThrow(try PXFDecoder().decode(Doc.self, from: "e = -2147483648\n"))
    }
}
