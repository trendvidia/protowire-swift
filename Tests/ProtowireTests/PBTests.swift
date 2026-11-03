// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

final class PBTests: XCTestCase {
    enum Status: Int, Codable {
        case unknown = 0
        case active = 1
        case inactive = 2
    }

    struct Message: Codable, Equatable {
        var status: Status
        
        enum CodingKeys: Int, CodingKey {
            case status = 1
        }
    }

    func testEnum() throws {
        let msg = Message(status: .active)
        let encoder = PBEncoder()
        let data = try encoder.encode(msg)
        print("ENCODED DATA: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Expected: Tag (1 << 3 | 0) = 8, Value = 1
        XCTAssertEqual(data, Data([0x08, 0x01]))
        
        let decoder = PBDecoder()
        let decoded = try decoder.decode(Message.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    struct PackedMessage: Codable, Equatable {
        var items: [Int32]
        
        enum CodingKeys: Int, CodingKey {
            case items = 1
        }
    }

    func testPackedRepeated() throws {
        let msg = PackedMessage(items: [1, 2, 3])
        let encoder = PBEncoder()
        let data = try encoder.encode(msg)
        
        // Expected: Tag (1 << 3 | 2) = 0x0A, Length = 3, Values = 01 02 03
        XCTAssertEqual(data, Data([0x0A, 0x03, 0x01, 0x02, 0x03]))
        
        let decoder = PBDecoder()
        let decoded = try decoder.decode(PackedMessage.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    /// The golden is protowire's `testdata/envelope/zero-map-entry.expected.hex`,
    /// which protoc and protobuf-go both produce. A map entry carries its key
    /// and value at zero (protowire#295).
    func testZeroMapEntryMatchesGolden() throws {
        let env = Envelope(status: 0, error: AppError(code: "", metadata: ["": ""]))
        XCTAssertEqual(hex(try PBEncoder().encode(env)), "22062a040a001200")
    }
}

/// Hex goldens from protowire-go's `pb.Marshal` at f8a01b1 for the Go structs
/// these mirror, not from this port (protowire-swift#14).
final class PBZeroSkippingTests: XCTestCase {
    struct Inner: Codable, Equatable {
        var x: Int32 = 0
        enum CodingKeys: Int, CodingKey { case x = 1 }
    }
    struct Top: Codable, Equatable {
        var a: Int32 = 0
        var s: String = ""
        var inner = Inner()
        enum CodingKeys: Int, CodingKey { case a = 1, s = 2, inner = 3 }
    }
    struct TopOptional: Codable, Equatable {
        var a: Int32 = 0
        var s: String = ""
        var inner: Inner?
        enum CodingKeys: Int, CodingKey { case a = 1, s = 2, inner = 3 }
    }
    struct Scalars: Codable, Equatable {
        var b = false
        var i32: Int32 = 0
        var i64: Int64 = 0
        var u32: UInt32 = 0
        var u64: UInt64 = 0
        var f: Float = 0
        var d: Double = 0
        var s = ""
        var y = Data()
        var l: [Int32] = []
        var ls: [String] = []
        var m: [String: String] = [:]
        enum CodingKeys: Int, CodingKey {
            case b = 1, i32, i64, u32, u64, f, d, s, y, l, ls, m
        }
    }
    struct Lists: Codable, Equatable {
        var l: [Int32] = []
        var ls: [String] = []
        var ly: [Data] = []
        var lm: [Inner] = []
        var lb: [Bool] = []
        enum CodingKeys: Int, CodingKey { case l = 1, ls, ly, lm, lb }
    }
    struct MapValues: Codable, Equatable {
        var m: [Int32: Inner] = [:]
        enum CodingKeys: Int, CodingKey { case m = 19 }
    }
    struct Optionals: Codable, Equatable {
        var i: Int32?
        var s: String?
        var b: Bool?
        var y: Data?
        enum CodingKeys: Int, CodingKey { case i = 1, s, b, y }
    }

    func testAllZeroScalarsWriteNothing() throws {
        XCTAssertEqual(hex(try PBEncoder().encode(Scalars())), "")
    }

    func testEmptyStructAndContainers() throws {
        XCTAssertEqual(hex(try PBEncoder().encode(TopOptional())), "")
        // Go's value struct writes a record, and only a nil pointer does not.
        XCTAssertEqual(hex(try PBEncoder().encode(Top())), "1a00")
        XCTAssertEqual(hex(try PBEncoder().encode(TopOptional(inner: Inner()))), "1a00")
    }

    func testNegativeZeroIsSkipped() throws {
        XCTAssertEqual(hex(try PBEncoder().encode(Scalars(f: -0.0, d: -0.0))), "")
    }

    func testMapEntryKeepsZeros() throws {
        XCTAssertEqual(hex(try PBEncoder().encode(MapValues(m: [0: Inner()]))), "9a010408001200")
    }

    func testRepeatedElementsKeepZeros() throws {
        let v = Lists(l: [0, 0], ls: [""], ly: [Data()], lm: [Inner()], lb: [false])
        XCTAssertEqual(hex(try PBEncoder().encode(v)), "0a02000012001a0022002a0100")
    }

    func testEnvelopeShapes() throws {
        XCTAssertEqual(hex(try PBEncoder().encode(Envelope(status: 0))), "")
        XCTAssertEqual(hex(try PBEncoder().encode(Envelope(status: 0, transportError: ""))), "")
        XCTAssertEqual(hex(try PBEncoder().encode(Envelope(status: 0, data: Data()))), "")
        XCTAssertEqual(hex(try PBEncoder().encode(Envelope(status: 0, error: AppError(code: "")))), "2200")
        let details = AppError(code: "", details: [FieldError(field: "", code: "")])
        XCTAssertEqual(hex(try PBEncoder().encode(Envelope(status: 0, error: details))), "22022200")
    }

    /// Not a reference golden. The reference writes `*int32` at zero as
    /// nothing, and this port's opt-in is what protobuf-go does for a proto3
    /// `optional` field that is set.
    func testOptionalAtZeroIsWritten() throws {
        XCTAssertEqual(hex(try PBEncoder().encode(Optionals())), "")
        let set = Optionals(i: 0, s: "", b: false, y: Data())
        let data = try PBEncoder().encode(set)
        XCTAssertEqual(hex(data), "080012001800" + "2200")
        XCTAssertEqual(try PBDecoder().decode(Optionals.self, from: data), set)
    }

    /// An explicit `encode(optional, forKey:)` means the same as a synthesized
    /// `encodeIfPresent`.
    func testExplicitOptionalEncode() throws {
        struct Explicit: Encodable {
            var i: Int32?
            enum CodingKeys: Int, CodingKey { case i = 1 }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(i, forKey: .i)
            }
        }
        XCTAssertEqual(hex(try PBEncoder().encode(Explicit(i: 0))), "0800")
        XCTAssertEqual(hex(try PBEncoder().encode(Explicit(i: nil))), "")
    }

    /// protobuf-go and protoc write `10 00`. The reference writes `10 01`, which
    /// reads back as true; that is filed against protowire-go. This pins the
    /// value that round-trips.
    func testBoolMapValueFalseStaysFalse() throws {
        struct M: Codable, Equatable {
            var m: [String: Bool] = [:]
            enum CodingKeys: Int, CodingKey { case m = 1 }
        }
        let v = M(m: ["a": false])
        let data = try PBEncoder().encode(v)
        XCTAssertEqual(hex(data), "0a050a01611000")
        XCTAssertEqual(try PBDecoder().decode(M.self, from: data), v)
    }

    /// Omitted fields read back as zero into non-optional properties, or the
    /// bytes of every other port would not decode here.
    func testZeroValuesRoundTrip() throws {
        XCTAssertEqual(try PBDecoder().decode(Scalars.self, from: Data()), Scalars())
        XCTAssertEqual(try PBDecoder().decode(Top.self, from: try PBEncoder().encode(Top())), Top())
        XCTAssertEqual(try PBDecoder().decode(Top.self, from: Data()), Top())
        XCTAssertEqual(try PBDecoder().decode(TopOptional.self, from: Data()), TopOptional())
        XCTAssertEqual(try PBDecoder().decode(PBTests.Message.self, from: Data()), PBTests.Message(status: .unknown))
        XCTAssertEqual(try PBDecoder().decode(Envelope.self, from: Data()), Envelope(status: 0))
        let lists = Lists(l: [0, 0], ls: [""], ly: [Data()], lm: [Inner()], lb: [false])
        XCTAssertEqual(try PBDecoder().decode(Lists.self, from: try PBEncoder().encode(lists)), lists)
        let map = MapValues(m: [0: Inner()])
        XCTAssertEqual(try PBDecoder().decode(MapValues.self, from: try PBEncoder().encode(map)), map)
    }

    func testTruncationStillFails() {
        XCTAssertThrowsError(try PBDecoder().decode(Scalars.self, from: Data([0x08])))
    }

    func testNarrowingThrows() {
        // Field 2 of Scalars, int32, carrying 2^40.
        XCTAssertThrowsError(try PBDecoder().decode(Scalars.self, from: Data([0x10, 0x80, 0x80, 0x80, 0x80, 0x80, 0x20])))
    }

    func testOutOfRangeFieldNumberThrows() {
        struct Huge: Encodable {
            enum CodingKeys: Int, CodingKey { case a = 0x1_0000_0000 }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(Int32(1), forKey: .a)
            }
        }
        XCTAssertThrowsError(try PBEncoder().encode(Huge()))
    }

    func testNarrowUnsignedListRoundTrips() throws {
        struct U: Codable, Equatable {
            var u: [UInt32] = []
            var i: [Int16] = []
            enum CodingKeys: Int, CodingKey { case u = 1, i = 2 }
        }
        let v = U(u: [0, 300], i: [-1])
        let data = try PBEncoder().encode(v)
        XCTAssertEqual(hex(data), "0a0300ac02120affffffffffffffffff01")
        XCTAssertEqual(try PBDecoder().decode(U.self, from: data), v)
    }

    /// A fixed-width field sits at whatever offset the bytes before it leave.
    /// `PBDecoder` copies each field first, so this input never trapped it;
    /// the pin is for the readers below, which a caller reaches with a slice.
    func testFixedFieldsAtAnyOffset() throws {
        struct Mixed: Codable {
            var a: Int32?
            var f: Float?
            var d: Double?
            enum CodingKeys: Int, CodingKey { case a = 1, f = 2, d = 3 }
        }
        // a = 1, then f at offset 3 and d at offset 8: neither aligned.
        let bytes = Data([0x08, 0x01, 0x15, 0x00, 0x00, 0x80, 0x3F, 0x19, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F])
        let m = try PBDecoder().decode(Mixed.self, from: bytes)
        XCTAssertEqual(m.a, 1)
        XCTAssertEqual(m.f, 1.0)
        XCTAssertEqual(m.d, 1.0)
    }

    func testFixedReadsAtAnyOffsetOfASlice() throws {
        let bytes = Data([0xFF, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Protowire.consumeFixed32(bytes.dropFirst())?.value, 1)
        XCTAssertEqual(Protowire.consumeFixed64(bytes.dropFirst(5))?.value, 2)
    }

    func testSBEHeaderAtAnyOffset() throws {
        let bytes = Data([0xFF, 8, 0, 1, 0, 2, 0, 3, 0, 0xAA])
        let header = try XCTUnwrap(SBE.readHeader(bytes.dropFirst()))
        XCTAssertEqual(header.blockLength, 8)
        XCTAssertEqual(header.templateID, 1)
    }
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
