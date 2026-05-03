import XCTest
import SwiftProtobuf
@testable import Protowire

/// Tests for the `_null` FieldMask round-trip: the encode side already worked
/// (encoder reads `_null` from a struct via Mirror and emits `field = null`
/// for each path); PR4 fixes the decode side, which previously had a no-op
/// `populateNullMask` stub.
final class PXFNullMaskTests: XCTestCase {

    // MARK: - Decode: unmarshalFull populates `_null`

    func testNullMask_decode_intoStringArray() throws {
        struct Message: Codable {
            var name: String?
            var email: String?
            var role: String?
            var _null: [String] = []

            enum CodingKeys: String, CodingKey {
                case name, email, role, _null
            }
        }

        let input = """
        name = "Alice"
        email = null
        role = null
        """
        let (msg, result) = try PXFDecoder().unmarshalFull(Message.self, from: input)

        XCTAssertEqual(msg.name, "Alice")
        XCTAssertNil(msg.email)
        XCTAssertNil(msg.role)
        XCTAssertEqual(msg._null.sorted(), ["email", "role"])

        XCTAssertEqual(result.allNullFields, ["email", "role"])
        XCTAssertTrue(result.isNull("email"))
        XCTAssertTrue(result.isSet("name"))
    }

    func testNullMask_decode_intoFieldMask() throws {
        struct Message: Codable {
            var name: String?
            var email: String?
            var _null: Google_Protobuf_FieldMask = Google_Protobuf_FieldMask()

            enum CodingKeys: String, CodingKey {
                case name, email, _null
            }
        }

        let input = """
        name = "Alice"
        email = null
        """
        let (msg, _) = try PXFDecoder().unmarshalFull(Message.self, from: input)
        // Google_Protobuf_FieldMask's retroactive Codable in PXFTests
        // joins paths into a single string; assert the joined result.
        XCTAssertTrue(msg._null.paths.contains("email"))
    }

    func testNullMask_decode_emptyWhenNoNulls() throws {
        struct Message: Codable {
            var name: String?
            var _null: [String] = []
            enum CodingKeys: String, CodingKey { case name, _null }
        }

        let (msg, result) = try PXFDecoder().unmarshalFull(Message.self,
                                                            from: #"name = "Alice""#)
        XCTAssertEqual(msg.name, "Alice")
        XCTAssertTrue(msg._null.isEmpty)
        XCTAssertTrue(result.allNullFields.isEmpty)
    }

    // MARK: - Encode: existing behavior is preserved

    func testNullMask_encode_emitsNullEntries() throws {
        struct Message: Codable {
            var name: String?
            var _null: [String]
            enum CodingKeys: String, CodingKey { case name, _null }
        }

        let msg = Message(name: "Alice", _null: ["email", "role"])
        let output = try PXFEncoder().encode(msg)

        XCTAssertTrue(output.contains("email = null"), "got: \(output)")
        XCTAssertTrue(output.contains("role = null"), "got: \(output)")
        XCTAssertFalse(output.contains("_null"), "got: \(output)")
    }

    // MARK: - Round-trip via [String]

    func testNullMask_roundTrip_viaStringArray() throws {
        struct Message: Codable {
            var name: String?
            var email: String?
            var role: String?
            var _null: [String] = []
            enum CodingKeys: String, CodingKey { case name, email, role, _null }
        }

        let original = """
        name = "Alice"
        email = null
        role = null
        """

        let (decoded, _) = try PXFDecoder().unmarshalFull(Message.self, from: original)

        // Encoder doesn't guarantee key order, so re-encode and re-decode:
        let reencoded = try PXFEncoder().encode(decoded)
        let (twiceDecoded, _) = try PXFDecoder().unmarshalFull(Message.self, from: reencoded)

        XCTAssertEqual(twiceDecoded.name, "Alice")
        XCTAssertNil(twiceDecoded.email)
        XCTAssertNil(twiceDecoded.role)
        XCTAssertEqual(twiceDecoded._null.sorted(), ["email", "role"])
    }
}
