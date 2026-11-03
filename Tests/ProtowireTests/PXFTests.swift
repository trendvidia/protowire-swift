// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

extension Google_Protobuf_Any: @retroactive Codable {
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

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Google_Protobuf_Struct: @retroactive Codable {
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

extension Google_Protobuf_Value: @retroactive Codable {
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

extension Google_Protobuf_ListValue: @retroactive Codable {
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

extension Google_Protobuf_StringValue: @retroactive Codable {
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decode(String.self, forKey: .value)
    }
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
    enum CodingKeys: String, CodingKey { case value }
}

extension Google_Protobuf_FieldMask: @retroactive Codable {
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
        XCTAssertTrue(output.contains("ts = 2026-04-29T21:00:00Z"), output)
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

    // MARK: Any bodies (#51)

    // The packed bytes below are what protowire-go 9fe20a1 writes for the same
    // documents and schema (encoding/pxf UnmarshalOptions with a TypeResolver,
    // then the Any's `value` field).

    private struct AnyHolder: Codable { var content: Google_Protobuf_Any }
    private struct Simple: Codable { var name: String? }
    /// `Simple` with field numbers, which `PBEncoder` can write without a schema.
    private struct NumberedSimple: Codable {
        var name: String?
        enum CodingKeys: Int, CodingKey { case name = 1 }
    }

    private struct AnyResolver: PXF.TypeResolver {
        var type: Decodable.Type
        func resolve(typeURL: String) -> Decodable.Type? { typeURL == "example.v1.Simple" ? type : nil }
    }

    private static let anyDoc = """
    content = {
            @type = "example.v1.Simple"
        name = "Protowire"
    }
    """
    /// `name = "Protowire"`: field 1, length 9.
    private static let packedSimple = Data([0x0a, 0x09] + Array("Protowire".utf8))

    /// example.v1 with `Message { Any content = 1 }`, `Many { repeated Any
    /// contents = 1 }` and `Simple { string name = 1 }`, with or without
    /// any.proto in the set.
    private static func anySchema(includeAnyProto: Bool) -> PXF.Annotations {
        func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                   typeName: String? = nil, repeated: Bool = false) -> Google_Protobuf_FieldDescriptorProto {
            var f = Google_Protobuf_FieldDescriptorProto()
            f.name = name
            f.number = number
            f.type = type
            f.label = repeated ? .repeated : .optional
            if let typeName { f.typeName = typeName }
            return f
        }
        func message(_ name: String, _ fields: [Google_Protobuf_FieldDescriptorProto]) -> Google_Protobuf_DescriptorProto {
            var m = Google_Protobuf_DescriptorProto()
            m.name = name
            m.field = fields
            return m
        }
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "example.proto"
        file.package = "example.v1"
        file.dependency = ["google/protobuf/any.proto"]
        file.messageType = [
            message("Message", [field("content", 1, .message, typeName: ".google.protobuf.Any")]),
            message("Many", [field("contents", 1, .message, typeName: ".google.protobuf.Any", repeated: true)]),
            message("Simple", [field("name", 1, .string)]),
        ]
        guard includeAnyProto else { return PXF.Annotations(files: [file]) }
        var any = Google_Protobuf_FileDescriptorProto()
        any.name = "google/protobuf/any.proto"
        any.package = "google.protobuf"
        any.syntax = "proto3"
        any.messageType = [message("Any", [field("type_url", 1, .string), field("value", 2, .bytes)])]
        return PXF.Annotations(files: [any, file])
    }

    /// With a schema the body packs from the descriptor, so a Swift type with
    /// string keys gets the reference's bytes. The set may leave out
    /// any.proto: Any's shape is fixed, and the reference always knows it.
    func testAnySupport() throws {
        for includeAnyProto in [true, false] {
            let decoder = PXFDecoder(annotations: Self.anySchema(includeAnyProto: includeAnyProto), rootMessage: "example.v1.Message")
            decoder.typeResolver = AnyResolver(type: Simple.self)
            let msg = try decoder.decode(AnyHolder.self, from: Self.anyDoc)
            XCTAssertEqual(msg.content.typeURL, "example.v1.Simple")
            XCTAssertEqual(msg.content.value, Self.packedSimple, "any.proto in the set: \(includeAnyProto)")
            XCTAssertEqual(decoder.lastBound?.serialized().hex,
                           "0a200a116578616d706c652e76312e53696d706c65120b0a0950726f746f77697265")
        }
    }

    /// Without a schema the only field numbers are the Swift type's. String
    /// keys have none, which is an error rather than bytes with no tags.
    func testAnyBodyWithoutASchemaNeedsIntKeys() throws {
        let decoder = PXFDecoder()
        decoder.typeResolver = AnyResolver(type: Simple.self)
        XCTAssertThrowsError(try decoder.decode(AnyHolder.self, from: Self.anyDoc)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["content"])
            XCTAssertTrue(context.debugDescription.contains(#"key "name" has no field number"#), context.debugDescription)
            XCTAssertTrue(context.debugDescription.contains("annotations and rootMessage"), context.debugDescription)
        }

        decoder.typeResolver = AnyResolver(type: NumberedSimple.self)
        let msg = try decoder.decode(AnyHolder.self, from: Self.anyDoc)
        XCTAssertEqual(msg.content.value, Self.packedSimple)
    }

    /// The body is bound even when the set leaves out any.proto, so its
    /// rules hold there as they do in the reference.
    func testAnyBodyIsBoundWithoutAnyProto() {
        let decoder = PXFDecoder(annotations: Self.anySchema(includeAnyProto: false), rootMessage: "example.v1.Message")
        decoder.typeResolver = AnyResolver(type: Simple.self)
        XCTAssertThrowsError(try decoder.decode(AnyHolder.self, from: #"content = { @type = "example.v1.Simple" nope = 1 }"#)) { error in
            // protowire-go: `1:41: unknown field "nope" in example.v1.Simple`
            XCTAssertEqual((error as? PXF.BindError)?.message, #"unknown field "nope" in example.v1.Simple"#)
            XCTAssertEqual((error as? PXF.BindError)?.pos.column, 41)
        }
    }

    func testWrapperSugarEncoding_protobufType() throws {
        // PR4: wrapper sugar is restricted to the nine SwiftProtobuf-generated
        // Google_Protobuf_*Value types. A real Google_Protobuf_StringValue
        // emits as `field = "..."` (sugared), not `field = { value = "..." }`.
        struct Message: Codable, Equatable {
            var label: Google_Protobuf_StringValue
        }

        var sv = Google_Protobuf_StringValue()
        sv.value = "hello"
        let msg = Message(label: sv)
        let output = try PXFEncoder().encode(msg)

        XCTAssertTrue(output.contains("label = \"hello\""), "got: \(output)")
        XCTAssertFalse(output.contains("{"), "got: \(output)")
    }

    func testWrapperSugarEncoding_userTypeIsNotSugared() throws {
        // PR4: a user struct with one `value` field is NOT a protobuf wrapper
        // and should emit as a regular nested message. The previous heuristic
        // ("any struct with a single `value` field") was a false-positive trap.
        struct UserWrapper: Codable, Equatable { var value: String }
        struct Message: Codable, Equatable { var label: UserWrapper }

        let output = try PXFEncoder().encode(Message(label: UserWrapper(value: "hello")))
        XCTAssertTrue(output.contains("label {"), "got: \(output)")
        XCTAssertTrue(output.contains("value = \"hello\""), "got: \(output)")
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
