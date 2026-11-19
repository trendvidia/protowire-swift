// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf
import XCTest
@testable import Protowire

/// A tag's wire type, against protobuf-go (#97, trendvidia/protowire#614).
///
/// A PB decoder does what protobuf does with a tag's wire type: it rejects
/// wire type 6 or 7 on any field, and handles a known field whose wire type
/// does not match its type as an unknown field, skipped by its wire type with
/// the field left as it was. `PBDecoder` used to read a field by its Swift
/// type whatever the wire type said, so `0801` on a string looped until the
/// depth limit refused it, and `0a0101` on an int64 read the length byte as
/// the value 1.
///
/// The oracle is protobuf-go, through `testdata/wiretype/table.tsv`, which
/// `conformance/wiretype` writes. Its inputs are protowire-go's
/// `TestUnmarshal_WireTypeMatchesProtobuf`: every field of conf.All gets one
/// record of every wire type, well formed and cut short, alone and inside
/// each message and map field. Each input must get protobuf-go's verdict, and
/// on accept the same values: the message protobuf-go read, without its
/// unknown fields and re-encoded, must decode here to what the input decoded
/// to. On reject, a skip's error must read as protowire-go's.
final class PBWireTypeTests: XCTestCase {
    struct ConfInner: Codable, Equatable {
        var name = ""
        var n: Int64 = 0
        enum CodingKeys: Int, CodingKey { case name = 1, n = 2 }
    }

    /// conf.All, as protowire-go's `confAll` mirrors it. The oneof's members
    /// are plain fields, as there.
    struct ConfAll: Codable, Equatable {
        var s = ""
        var i64: Int64 = 0
        var i32: Int32 = 0
        var u64: UInt64 = 0
        var u32: UInt32 = 0
        var z64: SInt64 = 0
        var z32: SInt32 = 0
        var b = false
        var f64: Double = 0
        var f32: Float = 0
        var buf = Data()
        var inner: ConfInner?
        var list: [ConfInner] = []
        var nums: [UInt32] = []
        var zigs: [SInt64] = []
        var reals: [Float] = []
        var strs: [String] = []
        var m: [String: Int64] = [:]
        var mm: [Int32: ConfInner] = [:]
        var a = ""
        var c: Int64 = 0
        var d: ConfInner?
        var flags: [Bool] = []
        var negs: [Int64] = []
        var bm: [Bool: Bool] = [:]
        enum CodingKeys: Int, CodingKey {
            case s = 1, i64, i32, u64, u32, z64, z32, b, f64, f32, buf, inner, list, nums, zigs, reals, strs,
                 m, mm, a, c, d, flags, negs, bm
        }
    }

    struct Row {
        var input: Data
        var hex: String
        var accept: Bool
        /// On accept, the known fields protobuf-go read, re-encoded; on
        /// reject, protowire-go's error.
        var detail: String
    }

    static let rows: [Row] = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("testdata/wiretype/table.tsv")
        let text = try! String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return Row(input: Data(unhex(cols[0])), hex: cols[0], accept: cols[1] == "accept", detail: cols[2])
        }
    }()

    func testDecoderMatchesProtobuf() throws {
        var accepted = 0, rejected = 0, sameText = 0
        for row in Self.rows {
            let got = Result { try PBDecoder().decode(ConfAll.self, from: row.input) }
            if !row.accept {
                rejected += 1
                switch got {
                case .success(let v):
                    XCTFail("\(row.hex): protobuf-go rejects it (\(row.detail)), this accepts \(v)")
                case .failure(let error):
                    // Where protowire-go refuses a record from its skip, the
                    // error is its text word for word, after the "field X: "
                    // it puts before a nested field's, which names a Go struct
                    // field. A record of the field's own wire type that is
                    // cut short reads differently: protowire-go reads it as
                    // the field ("field S: corrupt string"), and this finds
                    // it while splitting the message into records.
                    guard row.detail.contains("corrupt field") else { break }
                    let text = String(describing: error)
                    XCTAssertTrue(row.detail.hasSuffix(text), "\(row.hex): \"\(text)\", protowire-go \"\(row.detail)\"")
                    if row.detail == text { sameText += 1 }
                }
                continue
            }
            accepted += 1
            guard case .success(let value) = got else {
                XCTFail("\(row.hex): protobuf-go accepts it, this rejects it: \(got)")
                continue
            }
            let want = try PBDecoder().decode(ConfAll.self, from: Data(unhex(row.detail)))
            XCTAssertEqual(value, want, "\(row.hex): values differ from protobuf-go's")
        }
        // A positive marker that both verdicts were exercised, on the whole table.
        print("wire types: \(Self.rows.count) inputs, protobuf-go accepts \(accepted), rejects \(rejected); \(sameText) errors are protowire-go's text exactly")
        XCTAssertEqual(Self.rows.count, 606)
        XCTAssertEqual(accepted, 254)
        XCTAssertEqual(rejected, 352)
        // Every reject at the top level that protowire-go reports from its skip.
        XCTAssertEqual(sameText, Self.rows.filter { !$0.accept && $0.detail.hasPrefix("corrupt field") }.count)
    }

    /// The schema-bound reader, `PXF.BoundMessage(reading:)`, which reads the
    /// PB of an Any's body and of a `pb` input to the text marshaller, holds
    /// to the same table through conf.proto's descriptor set.
    func testBoundReaderMatchesProtobuf() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("testdata/wiretype/conf.binpb")
        let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: try Data(contentsOf: url))
        let annotations = PXF.Annotations(descriptorSet: set)
        func read(_ data: Data) throws -> Data {
            try PXF.BoundMessage(reading: data, message: "conf.All", annotations: annotations).serialized()
        }
        var accepted = 0, rejected = 0, sameText = 0
        for row in Self.rows {
            let got = Result { try read(row.input) }
            if !row.accept {
                rejected += 1
                switch got {
                case .success:
                    XCTFail("\(row.hex): protobuf-go rejects it (\(row.detail)), this accepts it")
                case .failure(let error):
                    guard row.detail.contains("corrupt field") else { break }
                    let text = String(describing: error)
                    XCTAssertTrue(row.detail.hasSuffix(text), "\(row.hex): \"\(text)\", protowire-go \"\(row.detail)\"")
                    if row.detail == text { sameText += 1 }
                }
                continue
            }
            accepted += 1
            guard case .success(let bytes) = got else {
                XCTFail("\(row.hex): protobuf-go accepts it, this rejects it: \(got)")
                continue
            }
            XCTAssertEqual(bytes, try read(Data(unhex(row.detail))), "\(row.hex): values differ from protobuf-go's")
        }
        print("wire types, bound reader: \(Self.rows.count) inputs, protobuf-go accepts \(accepted), rejects \(rejected); \(sameText) errors are protowire-go's text exactly")
        XCTAssertEqual(accepted, 254)
        XCTAssertEqual(rejected, 352)
        XCTAssertEqual(sameText, Self.rows.filter { !$0.accept && $0.detail.hasPrefix("corrupt field") }.count)
    }

    struct I64Holder: Codable, Equatable {
        var v: Int64 = 0
        enum CodingKeys: Int, CodingKey { case v = 1 }
    }

    struct StringHolder: Codable, Equatable {
        var v = ""
        enum CodingKeys: Int, CodingKey { case v = 1 }
    }

    /// The rows of #97 and protowire-go#304's table, by name. The texts are
    /// protowire-go's `pb.Unmarshal`, at v1.19.0, on the same input.
    func testIssueRows() {
        for (name, hex, isString, error) in [
            ("int64, wire type 6", "0e01", false, "corrupt field 1: proto: cannot parse reserved wire type"),
            ("string, wire type 7", "0f0161", true, "corrupt field 1: proto: cannot parse reserved wire type"),
            ("string, wire type 6", "0e0161", true, "corrupt field 1: proto: cannot parse reserved wire type"),
            ("int64 sent as wire type 2", "0a0101", false, nil),
            ("int64 sent as wire type 5", "0d01000000", false, nil),
            ("string sent as wire type 0", "0801", true, nil),
            ("int64 as wire type 2, cut short", "0a01", false, "corrupt field 1: unexpected EOF"),
            ("int64 as wire type 5, cut short", "0d01", false, "corrupt field 1: unexpected EOF"),
        ] as [(String, String, Bool, String?)] {
            let input = Data(unhex(hex))
            let got: Result<Bool, Error> = Result {
                isString ? try PBDecoder().decode(StringHolder.self, from: input) == StringHolder()
                         : try PBDecoder().decode(I64Holder.self, from: input) == I64Holder()
            }
            switch (got, error) {
            case (.success(let leftAlone), nil):
                XCTAssertTrue(leftAlone, "\(name): the field was set")
            case (.failure(let e), let want?):
                XCTAssertEqual(String(describing: e), want, name)
            default:
                XCTFail("\(name): \(got), want \(error ?? "accept")")
            }
        }
    }

    struct Alone: Codable, Equatable {
        var p: Int64?
        var l: [String] = []
        var kept = ""
        enum CodingKeys: Int, CodingKey { case p = 1, l, kept }
    }

    /// A skipped field is not touched: an Optional stays nil and a list gets
    /// no element.
    func testMismatchLeavesFieldAlone() throws {
        let got = try PBDecoder().decode(Alone.self, from: Data(unhex("0d01000000" + "1001" + "1a0161")))
        XCTAssertEqual(got, Alone(p: nil, l: [], kept: "a"))
    }

    struct BigHolder: Decodable {
        var i: Pxf_BigInt?
        var r: Pxf_Decimal?
        var f: Pxf_BigFloat?
        enum CodingKeys: Int, CodingKey { case i = 1, r, f }
    }

    /// The big-number messages are read by the same rule: a field whose wire
    /// type does not match is skipped, and wire types 6 and 7 are refused.
    /// protowire-go's TestUnmarshal_WireTypeBigNumbers. Its texts at v1.19.0
    /// are these, after a "field I: " naming its Go struct field.
    func testBigNumbers() throws {
        func decode(_ hex: String) throws -> BigHolder { try PBDecoder().decode(BigHolder.self, from: Data(unhex(hex))) }

        // BigInt{abs: 5, negative sent as wire type 2}: negative is skipped.
        var m = try decode("0a06" + "0a0105" + "120101")
        XCTAssertEqual(m.i?.abs, Data([5]))
        XCTAssertEqual(m.i?.negative, false)
        // BigInt{abs sent as a varint}: abs is skipped, the value is 0.
        m = try decode("0a02" + "0805")
        XCTAssertEqual(m.i?.abs, Data())
        // Decimal{unscaled: 15, scale sent as fixed32}: scale stays 0.
        m = try decode("1208" + "0a010f" + "1501000000")
        XCTAssertEqual(m.r?.unscaled, Data([15]))
        XCTAssertEqual(m.r?.scale, 0)
        // BigFloat{mantissa: 1, exponent sent as bytes, prec 53}: exponent stays 0.
        m = try decode("1a08" + "0a0101" + "120101" + "1835")
        XCTAssertEqual(m.f?.mantissa, Data([1]))
        XCTAssertEqual(m.f?.exponent, 0)
        XCTAssertEqual(m.f?.prec, 53)

        for (hex, want) in [
            ("0a02" + "0e01", "corrupt field 1 in BigInt: proto: cannot parse reserved wire type"),
            ("1203" + "1f0101", "corrupt field 3 in Decimal: proto: cannot parse reserved wire type"),
            ("1a02" + "2601", "corrupt field 4 in BigFloat: proto: cannot parse reserved wire type"),
        ] {
            XCTAssertThrowsError(try decode(hex), hex) { XCTAssertEqual(String(describing: $0), want, hex) }
        }
    }

    /// An unknown group is skipped as protobuf-go skips one, and nesting is
    /// bounded where protobuf-go bounds it: 10001 groups nest and 10002 do
    /// not. The texts are protowire-go's at v1.19.0.
    func testGroups() throws {
        func decode(_ bytes: [UInt8]) throws -> I64Holder { try PBDecoder().decode(I64Holder.self, from: Data(bytes)) }
        // Field 15: start group, a varint field inside, end group; then field 1.
        XCTAssertEqual(try decode([0x7b, 0x08, 0x01, 0x7c, 0x08, 0x05]), I64Holder(v: 5))
        // A group on a known field is not its value either.
        XCTAssertEqual(try decode([0x0b, 0x0c]), I64Holder())
        for (bytes, want) in [
            ([0x7b, 0x08, 0x01, 0x74], "corrupt field 15: proto: mismatching end group marker"),
            ([0x7c], "corrupt field 15: proto: mismatching end group marker"),
            ([0x0b], "corrupt field 1: unexpected EOF"),
            ([0x0b, 0x0a, 0x01], "corrupt field 1: unexpected EOF"),
            ([0x0b, 0x0f, 0x0c], "corrupt field 1: proto: cannot parse reserved wire type"),
            ([UInt8](repeating: 0x7b, count: 200_000), "corrupt field 15: proto: parse error"),
        ] as [([UInt8], String)] {
            XCTAssertThrowsError(try decode(bytes)) { XCTAssertEqual(String(describing: $0), want) }
        }
        func nested(_ n: Int) -> [UInt8] { [UInt8](repeating: 0x7b, count: n) + [UInt8](repeating: 0x7c, count: n) }
        XCTAssertEqual(try decode(nested(10_001)), I64Holder())
        XCTAssertThrowsError(try decode(nested(10_002))) {
            XCTAssertEqual(String(describing: $0), "corrupt field 15: proto: parse error")
        }
    }

    enum Level: Int, Codable { case low = 0, mid = 1, high = 2 }

    struct Levels: Codable, Equatable {
        var levels: [Level] = []
        var one: Level?
        enum CodingKeys: Int, CodingKey { case levels = 1, one = 2 }
    }

    /// A list of enums reads both its own wire type and the packed form, as
    /// a list of numbers does; an enum field reads only a varint.
    func testEnums() throws {
        func decode(_ hex: String) throws -> Levels { try PBDecoder().decode(Levels.self, from: Data(unhex(hex))) }
        XCTAssertEqual(try decode("08010802"), Levels(levels: [.mid, .high]))
        XCTAssertEqual(try decode("0a020102"), Levels(levels: [.mid, .high]))
        XCTAssertEqual(try decode("0a0201020800"), Levels(levels: [.mid, .high, .low]))
        XCTAssertEqual(try decode("1002"), Levels(one: .high))
        XCTAssertEqual(try decode("12010210011d01000000"), Levels(one: .mid))
    }

    /// A packed list whose last element is cut short is corrupt, as in
    /// protobuf: it used to end the list there.
    func testPackedCutShort() {
        struct Reals: Decodable { var r: [Float]; enum CodingKeys: Int, CodingKey { case r = 1 } }
        struct Nums: Decodable { var n: [UInt32]; enum CodingKeys: Int, CodingKey { case n = 1 } }
        XCTAssertThrowsError(try PBDecoder().decode(Reals.self, from: Data(unhex("0a050000803f00"))))
        XCTAssertThrowsError(try PBDecoder().decode(Nums.self, from: Data(unhex("0a020180"))))
    }
}

func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
