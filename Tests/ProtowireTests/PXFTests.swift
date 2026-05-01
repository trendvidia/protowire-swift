import XCTest
import SwiftProtobuf
@testable import Protowire

extension Google_Protobuf_Any: Codable {
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.typeURL = try container.decode(String.self, forKey: .typeURL)
        self.value = try container.decode(Data.self, forKey: .value)
    }
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeURL, forKey: .typeURL)
        try container.encode(value, forKey: .value)
    }
    enum CodingKeys: String, CodingKey {
        case typeURL = "type_url"
        case value
    }
}

extension Google_Protobuf_Struct: Codable {
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in container.allKeys {
            let val = try container.decode(Google_Protobuf_Value.self, forKey: key)
            self.fields[key.stringValue] = val
        }
    }
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, val) in fields {
            try container.encode(val, forKey: DynamicKey(stringValue: key)!)
        }
    }
}

extension Google_Protobuf_Value: Codable {
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self.stringValue = v }
        else if let v = try? container.decode(Double.self) { self.numberValue = v }
        else if let v = try? container.decode(Bool.self) { self.boolValue = v }
        else if let v = try? container.decode(Google_Protobuf_Struct.self) { self.structValue = v }
        else if let v = try? container.decode(Google_Protobuf_ListValue.self) { self.listValue = v }
        else if container.decodeNil() { self.nullValue = .nullValue }
    }
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        switch kind {
        case .stringValue(let v): try container.encode(v)
        case .numberValue(let v): try container.encode(v)
        case .boolValue(let v): try container.encode(v)
        case .structValue(let v): try container.encode(v)
        case .listValue(let v): try container.encode(v)
        case .nullValue: try container.encodeNil()
        case nil: try container.encodeNil()
        }
    }
}

extension Google_Protobuf_ListValue: Codable {
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let val = try container.decode(Google_Protobuf_Value.self)
            self.values.append(val)
        }
    }
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.unkeyedContainer()
        for v in values { try container.encode(v) }
    }
}

extension Google_Protobuf_FieldMask: Codable {
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        if let container = try? decoder.singleValueContainer(), let s = try? container.decode(String.self) {
            self.paths = s.components(separatedBy: ",")
        } else {
            let container = try decoder.singleValueContainer()
            self.paths = try container.decode([String].self)
        }
    }
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(paths.joined(separator: ","))
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

final class PXFTests: XCTestCase {
    func testLexerBasic() {
        let input = """
        @type example.v1.Message
        
        name = "Protowire" # A comment
        count = 42
        enabled = true
        data = b"deadbeef"
        
        nested = {
            id = 1
        }
        """
        let lexer = PXF.Lexer(string: input)
        var tokens: [PXF.Token] = []
        var token = lexer.next()
        while token.kind != .eof {
            tokens.append(token)
            token = lexer.next()
        }
        
        XCTAssertEqual(tokens[0].kind, .atType)
        XCTAssertEqual(tokens[1].kind, .identifier)
        XCTAssertEqual(tokens[1].value, "example.v1.Message")
    }
        
    func testParserBasic() throws {
        let input = """
        @type example.v1.Message
        
        # Leading comment
        name = "Protowire" # A comment
        count = 42
        enabled = true
        
        nested = {
            id = 1
        }
        
        items = [1, 2, 3]
        """
        let parser = PXF.Parser(string: input)
        let doc = try parser.parseDocument()
        
        XCTAssertEqual(doc.typeURL, "example.v1.Message")
        XCTAssertEqual(doc.entries.count, 5)
        
        if let first = doc.entries[0] as? PXF.Assignment {
            XCTAssertEqual(first.key, "name")
            XCTAssertEqual((first.value as? PXF.StringVal)?.value, "Protowire")
            XCTAssertEqual(first.leadingComments.count, 1)
            XCTAssertEqual(first.leadingComments[0].text, "# Leading comment")
        } else {
            XCTFail("Expected Assignment")
        }
    }

    func testEncoderBasic() throws {
        struct Message: Encodable {
            var name: String
            var count: Int
            var enabled: Bool
            var data: Data
        }
        
        let msg = Message(name: "Protowire", count: 42, enabled: true, data: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let encoder = PXFEncoder()
        let output = try encoder.encode(msg)
        
        XCTAssertTrue(output.contains("name = \"Protowire\""))
        XCTAssertTrue(output.contains("count = 42"))
        XCTAssertTrue(output.contains("enabled = true"))
        XCTAssertTrue(output.contains("data = b\"3q2+7w==\""))
    }

    func testDecoderBasic() throws {
        struct Message: Codable, Equatable {
            var name: String
            var count: Int
            var enabled: Bool
            var data: Data
            var nested: Nested
            var items: [Int]
            
            struct Nested: Codable, Equatable {
                var id: Int
            }
        }
        
        let input = """
        name = "Protowire"
        count = 42
        enabled = true
        data = b"3q2+7w=="
        
        nested = {
            id = 1
        }
        
        items = [1, 2, 3]
        """
        
        let decoder = PXFDecoder()
        let msg = try decoder.decode(Message.self, from: input)
        
        XCTAssertEqual(msg.name, "Protowire")
        XCTAssertEqual(msg.count, 42)
        XCTAssertEqual(msg.enabled, true)
        XCTAssertEqual(msg.data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(msg.nested.id, 1)
        XCTAssertEqual(msg.items, [1, 2, 3])
    }

    func testWKTs() throws {
        struct Message: Codable, Equatable {
            var ts: Date
        }
        
        let input = "ts = 2026-04-29T21:00:00.000Z"
        let decoder = PXFDecoder()
        let msg = try decoder.decode(Message.self, from: input)
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(formatter.string(from: msg.ts), "2026-04-29T21:00:00.000Z")
        
        let encoder = PXFEncoder()
        let output = try encoder.encode(msg)
        XCTAssertTrue(output.contains("ts = 2026-04-29T21:00:00.000Z"))
    }

    func testUnmarshalFull() throws {
        struct Message: Codable {
            var name: String?
            var email: String?
            var role: String?
        }
        
        let input = """
        name = "Alice"
        email = null
        """
        
        let decoder = PXFDecoder()
        let (msg, result) = try decoder.unmarshalFull(Message.self, from: input)
        
        XCTAssertEqual(msg.name, "Alice")
        XCTAssertNil(msg.email)
        XCTAssertNil(msg.role)
        
        XCTAssertTrue(result.isSet("name"))
        XCTAssertTrue(result.isNull("email"))
        XCTAssertTrue(result.isAbsent("role"))
    }

    func testNullSurvival() throws {
        struct Message: Codable {
            var name: String?
            var email: String?
            var _null: [String] = []
            
            enum CodingKeys: String, CodingKey {
                case name, email, _null
            }
        }
        
        let msg = Message(name: "Alice", email: nil, _null: ["email"])
        let encoder = PXFEncoder()
        let output = try encoder.encode(msg)
        print("NULL SURVIVAL OUTPUT:\n\(output)")
        
        XCTAssertTrue(output.contains("email = null"))
        XCTAssertFalse(output.contains("_null"))
    }

    func testWrapperSugar() throws {
        // Mocking google.protobuf.StringValue
        struct StringValue: Codable, Equatable {
            var value: String
        }
        
        struct Message: Codable, Equatable {
            var label: StringValue
        }
        
        let input = """
        label = "hello"
        """
        
        let decoder = PXFDecoder()
        // This should now work with our wrapper sugar implementation
        let msg = try decoder.decode(Message.self, from: input)
        XCTAssertEqual(msg.label.value, "hello")
    }

    func testAnySupport() throws {
        struct Message: Codable {
            var content: Google_Protobuf_Any
        }
        
        // Mock TypeResolver
        class MyResolver: PXF.TypeResolver {
            func resolve(typeURL: String) -> Decodable.Type? {
                if typeURL == "example.v1.Simple" { return Simple.self }
                return nil
            }
        }
        
        struct Simple: Codable, Equatable {
            var name: String
        }
        
        let input = """
        content = @type example.v1.Simple {
            name = "Protowire"
        }
        """
        
        let decoder = PXFDecoder()
        decoder.typeResolver = MyResolver()
        
        do {
            let msg = try decoder.decode(Message.self, from: input)
            XCTAssertEqual(msg.content.typeURL, "example.v1.Simple")
            XCTAssertFalse(msg.content.value.isEmpty)
        } catch {
            XCTFail("Any support failed: \(error)")
        }
    }

    func testWrapperSugarEncoding() throws {
        // Mocking google.protobuf.StringValue
        struct StringValue: Codable, Equatable {
            var value: String
        }
        
        struct Message: Codable, Equatable {
            var label: StringValue
        }
        
        let msg = Message(label: StringValue(value: "hello"))
        let encoder = PXFEncoder()
        let output = try encoder.encode(msg)
        
        // Expected: label = "hello" (NOT label = { value = "hello" })
        XCTAssertTrue(output.contains("label = \"hello\""))
        XCTAssertFalse(output.contains("{"))
    }

    func testStructSupport() throws {
        struct Message: Codable {
            var metadata: Google_Protobuf_Struct
        }
        
        let input = """
        metadata = {
            foo = "bar"
            count = 42
            active = true
        }
        """
        
        let decoder = PXFDecoder()
        do {
            let msg = try decoder.decode(Message.self, from: input)
            XCTAssertEqual(msg.metadata.fields["foo"]?.stringValue, "bar")
            XCTAssertEqual(msg.metadata.fields["count"]?.numberValue, 42.0)
            XCTAssertEqual(msg.metadata.fields["active"]?.boolValue, true)
        } catch {
            XCTFail("Struct support failed: \(error)")
        }
    }

    func testFieldMaskSupport() throws {
        struct Message: Codable {
            var mask: Google_Protobuf_FieldMask
        }
        
        let input = """
        mask = ["foo.bar", "baz"]
        """
        
        let decoder = PXFDecoder()
        let msg = try decoder.decode(Message.self, from: input)
        XCTAssertEqual(msg.mask.paths, ["foo.bar", "baz"])
        
        let encoder = PXFEncoder()
        let output = try encoder.encode(msg)
        print("FIELD MASK OUTPUT:\n\(output)")
        XCTAssertTrue(output.contains("mask = \"foo.bar,baz\""))
    }
}
