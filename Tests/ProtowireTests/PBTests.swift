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

    private struct MapHolder: Encodable {
        struct Inner: Encodable {
            var metadata: [String: String]
            enum CodingKeys: Int, CodingKey { case metadata = 5 }
        }
        var error: Inner
        enum CodingKeys: Int, CodingKey { case error = 4 }
    }

    /// The golden is protowire's `testdata/envelope/zero-map-entry.expected.hex`,
    /// which protoc and protobuf-go both produce. A map entry carries its key
    /// and value at zero (protowire#295).
    func testZeroMapEntryMatchesGolden() throws {
        let data = try PBEncoder().encode(MapHolder(error: .init(metadata: ["": ""])))
        XCTAssertEqual(data.map { String(format: "%02x", $0) }.joined(), "22062a040a001200")
    }
}
