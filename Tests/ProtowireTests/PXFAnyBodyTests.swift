// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

/// The encoder writes an Any as `@type` and a body only when reading that body
/// gives back the Any's value, byte for byte. Anything else stays as the Any's
/// own fields, `type_url` and `value` (protowire#501, draft -01 § Any Blocks).
/// A reader compares an Any by its bytes, so a body that drops or reorders
/// them changes the message with no error. The cases are protowire-go's
/// encoding/pxf/any_body_readback_test.go.
final class PXFAnyBodyTests: XCTestCase {

    // MARK: schema

    private static func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                              typeName: String? = nil, repeated: Bool = false,
                              required: Bool = false, defaultLiteral: String? = nil) -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = repeated ? .repeated : .optional
        if let typeName { f.typeName = "." + typeName }
        if required { f.options.Pxf_required = true }
        if let defaultLiteral { f.options.Pxf_default = defaultLiteral }
        return f
    }

    private static func message(_ name: String, _ fields: [Google_Protobuf_FieldDescriptorProto]) -> Google_Protobuf_DescriptorProto {
        var m = Google_Protobuf_DescriptorProto()
        m.name = name
        m.field = fields
        return m
    }

    private static func file(_ name: String, _ package: String, imports: [String] = [],
                             _ messages: [Google_Protobuf_DescriptorProto]) -> Google_Protobuf_FileDescriptorProto {
        var f = Google_Protobuf_FileDescriptorProto()
        f.name = name
        f.package = package
        f.syntax = "proto3"
        f.dependency = imports
        f.messageType = messages
        return f
    }

    /// anyback.v1 as in protowire-go's test, with the well-known types it
    /// imports written out.
    private static let annotations: PXF.Annotations = {
        let any = file("google/protobuf/any.proto", "google.protobuf",
                       [message("Any", [field("type_url", 1, .string), field("value", 2, .bytes)])])
        let timestamp = file("google/protobuf/timestamp.proto", "google.protobuf",
                             [message("Timestamp", [field("seconds", 1, .int64), field("nanos", 2, .int32)])])
        let wrappers = file("google/protobuf/wrappers.proto", "google.protobuf",
                            [message("Int32Value", [field("value", 1, .int32)])])

        var mEntry = message("MEntry", [field("key", 1, .string), field("value", 2, .int32)])
        mEntry.options.mapEntry = true
        var optional = field("o", 6, .int32)
        optional.proto3Optional = true
        optional.oneofIndex = 0
        var rich = message("Rich", [
            field("ts", 1, .message, typeName: "google.protobuf.Timestamp"),
            field("w", 2, .message, typeName: "google.protobuf.Int32Value"),
            field("leaf", 3, .message, typeName: "anyback.v1.Leaf"),
            field("m", 4, .message, typeName: "anyback.v1.Rich.MEntry", repeated: true),
            field("r", 5, .int32, repeated: true),
            optional,
            field("leaves", 8, .message, typeName: "anyback.v1.Leaf", repeated: true),
        ])
        rich.nestedType = [mEntry]
        var synthetic = Google_Protobuf_OneofDescriptorProto()
        synthetic.name = "_o"
        rich.oneofDecl = [synthetic]

        let anyback = file("anyback.proto", "anyback.v1",
                           imports: ["google/protobuf/any.proto", "google/protobuf/timestamp.proto", "google/protobuf/wrappers.proto"], [
            message("Holder", [field("payload", 1, .message, typeName: "google.protobuf.Any"),
                               field("next", 2, .message, typeName: "anyback.v1.Holder")]),
            message("Leaf", [field("tag", 1, .string), field("n", 2, .int32)]),
            rich,
            message("Defaulted", [field("label", 1, .string, defaultLiteral: "dflt"), field("n", 2, .int32)]),
            message("Required", [field("n", 1, .int32, required: true), field("s", 2, .string)]),
        ])
        return PXF.Annotations(files: [any, timestamp, wrappers, anyback])
    }()

    private static let holder = "anyback.v1.Holder"

    /// Reads nothing, so a decode runs the schema-bound pass and no Swift type.
    private struct Anything: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private struct Resolver: PXF.TypeResolver {
        func resolve(typeURL: String) -> Decodable.Type? {
            PXFAnyBodyTests.annotations.message(PXF.Binder.messageName(ofTypeURL: typeURL)) == nil ? nil : Anything.self
        }
    }

    // MARK: bytes

    private static func varintField(_ number: Int32, _ value: UInt64) -> Data {
        var out = Data()
        Protowire.appendTag(&out, number: number, type: .varint)
        Protowire.appendVarint(&out, value)
        return out
    }

    private static func lenField(_ number: Int32, _ body: Data) -> Data {
        var out = Data()
        Protowire.appendTag(&out, number: number, type: .bytes)
        Protowire.appendBytes(&out, body)
        return out
    }

    private static func lenField(_ number: Int32, _ text: String) -> Data { lenField(number, Data(text.utf8)) }

    /// A Holder's bytes, its payload an Any of `typeName` holding `value`
    /// verbatim. An empty value is left off, as a deterministic marshal does.
    private static func anyHolder(_ typeName: String, _ value: Data) -> Data {
        var any = lenField(1, typeName)
        if !value.isEmpty { any += lenField(2, value) }
        return lenField(1, any)
    }

    // MARK: writing and reading back

    /// Writes the Holder `bytes` as PXF, reads the text back with the
    /// schema-bound decoder and checks that it gives the same bytes. Returns
    /// the text.
    @discardableResult
    private func assertReadsBack(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let bound = try PXF.BoundMessage(reading: bytes, message: Self.holder, annotations: Self.annotations)
        let text = try PXFEncoder(annotations: Self.annotations, rootMessage: Self.holder)
            .encode(PXF.BoundText(message: bound, annotations: Self.annotations))
        let decoder = PXFDecoder(annotations: Self.annotations, rootMessage: Self.holder)
        decoder.typeResolver = Resolver()
        do {
            _ = try decoder.decode(Anything.self, from: text)
        } catch {
            XCTFail("did not read back: \(error)\n\(text.prefix(2000))", file: file, line: line)
            return text
        }
        XCTAssertEqual(decoder.lastBound?.serialized().hex, bytes.hex, "reading changed the message:\n\(text.prefix(2000))",
                       file: file, line: line)
        return text
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testAnyBodyIsWrittenOnlyWhenItReadsBack() throws {
        let tagT = Self.lenField(1, "t")
        let n1 = Self.varintField(2, 1)
        let unknown = Self.varintField(101, 1)
        func entry(_ key: String, _ value: UInt64) -> Data {
            Self.lenField(4, Self.lenField(1, key) + Self.varintField(2, value))
        }

        let cases: [(name: String, type: String, value: Data, body: Bool)] = [
            // What a body can say keeps the body form.
            ("canonical", "anyback.v1.Leaf", tagT + n1, true),
            ("empty", "anyback.v1.Leaf", Data(), true),
            ("timestamp", "anyback.v1.Rich", Self.lenField(1, Self.varintField(1, 1_700_000_000)), true),
            ("wrapper", "anyback.v1.Rich", Self.lenField(2, Self.varintField(1, 7)), true),
            ("wrapper holding zero", "anyback.v1.Rich", Self.lenField(2, Data()), true),
            ("sorted map", "anyback.v1.Rich", entry("a", 1) + entry("b", 2), true),
            ("packed list", "anyback.v1.Rich", Self.lenField(5, Data([1, 2])), true),
            ("optional zero", "anyback.v1.Rich", Self.varintField(6, 0), true),
            ("default field set", "anyback.v1.Defaulted", Self.lenField(1, "x"), true),
            ("required field set", "anyback.v1.Required", Self.varintField(1, 3), true),

            // Unknown fields, at the top of the value and at every level below.
            ("unknown field", "anyback.v1.Leaf", tagT + unknown, false),
            ("unknown in submessage", "anyback.v1.Rich", Self.lenField(3, tagT + unknown), false),
            ("unknown in list element", "anyback.v1.Rich", Self.lenField(8, tagT + unknown), false),
            ("unknown in wrapper", "anyback.v1.Rich", Self.lenField(2, Self.varintField(1, 7) + unknown), false),
            ("unknown in timestamp", "anyback.v1.Rich", Self.lenField(1, Self.varintField(1, 5) + unknown), false),

            // Bytes a decoder would not write back.
            ("fields out of order", "anyback.v1.Leaf", n1 + tagT, false),
            ("map out of order", "anyback.v1.Rich", entry("b", 2) + entry("a", 1), false),
            ("explicit zero", "anyback.v1.Leaf", Self.varintField(2, 0), false),
            ("long varint", "anyback.v1.Leaf", Data([0x10, 0x81, 0x00]), false),
            ("unpacked list", "anyback.v1.Rich", Self.varintField(5, 1) + Self.varintField(5, 2), false),
            ("repeated singular field", "anyback.v1.Leaf", Self.varintField(2, 1) + Self.varintField(2, 2), false),

            // A literal cannot hold it.
            ("timestamp past year 9999", "anyback.v1.Rich", Self.lenField(1, Self.varintField(1, 1 << 40)), false),

            // A reader's annotation rules would change or refuse the body.
            ("default unset", "anyback.v1.Defaulted", Self.varintField(2, 1), false),
            ("required unset", "anyback.v1.Required", Self.lenField(2, "s"), false),

            // Never unpacked at all.
            ("unresolved", "anyback.v1.Nope", tagT, false),
            ("unparsable", "anyback.v1.Leaf", Data([0xff]), false),
            ("map key of the wrong wire type", "anyback.v1.Rich", Self.lenField(4, Self.lenField(1, "a") + Self.varintField(1, 5)), false),
        ]
        for c in cases {
            let text = try assertReadsBack(Self.anyHolder(c.type, c.value))
            XCTAssertEqual(text.contains("@type"), c.body, "\(c.name):\n\(text)")
            XCTAssertEqual(text.contains("type_url"), !c.body, "\(c.name):\n\(text)")
        }
    }

    /// A canonical Any still takes the body form, and the raw form is the
    /// Any's own two fields.
    func testBothForms() throws {
        let canonical = try assertReadsBack(Self.anyHolder("anyback.v1.Leaf", Self.lenField(1, "t") + Self.varintField(2, 1)))
        XCTAssertEqual(canonical, """
            payload {
              @type = "anyback.v1.Leaf"
              tag = "t"
              n = 1
            }

            """)
        let raw = try assertReadsBack(Self.anyHolder("anyback.v1.Leaf", Self.varintField(2, 1) + Self.lenField(1, "t")))
        XCTAssertEqual(raw, """
            payload {
              type_url = "anyback.v1.Leaf"
              value = b"EAEKAXQ="
            }

            """)
    }

    /// `n` Anys, each holding a Holder whose payload is the next, around a Leaf.
    private static func holderChain(_ n: Int) -> Data {
        var bytes = anyHolder("anyback.v1.Leaf", lenField(1, "t"))
        for _ in 1..<n { bytes = anyHolder(holder, bytes) }
        return bytes
    }

    /// A chain of Anys costs its own bytes on the wire, not a nesting level,
    /// so a long one has to stop opening bodies where the text runs out of
    /// depth: the 101st Any's block would be past the limit, so the 100th
    /// stays raw to hold it as bytes.
    func testAChainOfAnysStopsAtTheDepthLimit() throws {
        for (n, bodies) in [(1, 1), (99, 99), (100, 100), (101, 99), (300, 99)] {
            let text = try assertReadsBack(Self.holderChain(n))
            XCTAssertEqual(Self.count("@type", in: text), bodies, "\(n) Anys")
        }
    }

    /// A body is checked where it lands: the same value that fits near the
    /// root does not fit near the limit, and only the Any there stays raw.
    func testABodyCountsItsDepthFromWhereItLands() throws {
        for (levels, body) in [(0, true), (98, true), (99, false)] {
            var bytes = Self.anyHolder("anyback.v1.Rich", Self.lenField(3, Self.lenField(1, "t")))
            for _ in 0..<levels { bytes = Self.lenField(2, bytes) }
            let text = try assertReadsBack(bytes)
            XCTAssertEqual(text.contains("@type"), body, "\(levels) levels")
        }
    }

    /// The Codable path has no descriptor to check a body against, so it
    /// never writes one: an Any is its own fields, whatever its value holds.
    func testTheCodableEncoderWritesAnAnyRaw() throws {
        struct Message: Codable { var content: Google_Protobuf_Any }
        var any = Google_Protobuf_Any()
        any.typeURL = "anyback.v1.Leaf"
        any.value = Self.lenField(1, "t") + Self.varintField(101, 1)
        let text = try PXFEncoder().encode(Message(content: any))
        XCTAssertFalse(text.contains("@type"), text)
        let back = try PXFDecoder().decode(Message.self, from: text)
        XCTAssertEqual(back.content.typeURL, any.typeURL)
        XCTAssertEqual(back.content.value.hex, any.value.hex)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
