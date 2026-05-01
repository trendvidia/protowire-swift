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
}
