// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import SwiftProtobuf
import XCTest
@testable import Protowire

/// The Codable bridge's half of the binding rules, which holds with no schema,
/// and the rules ConformanceTests has no fixture for. The corpus covers the
/// schema-bound verdicts themselves.
final class PXFBindTests: XCTestCase {
    struct Inner: Codable, Equatable { var a: Int32?; var b: Int32? }
    struct Holder: Codable, Equatable {
        var s: String?
        var m: Inner?
        var tags: [String]?
        var inners: [String: Inner]?
        var labels: [String: String]?
        var nums: [Int32: String]?
        var flags: [Bool: String]?
    }

    private func decode(_ text: String) throws -> Holder {
        try PXFDecoder().decode(Holder.self, from: text)
    }

    // MARK: maps (#28, #27)

    func testMapOfMessagesKeepsItsValues() throws {
        XCTAssertEqual(try decode("inners = { k: { a = 1 } j: { b = 2 } }").inners,
                       ["k": Inner(a: 1, b: nil), "j": Inner(a: nil, b: 2)])
    }

    func testMapKeysOfEveryKindBind() throws {
        XCTAssertEqual(try decode(#"nums = { 1: "x" "2": "y" }"#).nums, [1: "x", 2: "y"])
        XCTAssertEqual(try decode(#"flags = { "true": "x" 0: "y" }"#).flags, [true: "x", false: "y"])
    }

    func testDistinctKeysAcrossBindingsMerge() throws {
        XCTAssertEqual(try decode("labels = { a: \"1\" }\nlabels = { b: \"2\" }").labels, ["a": "1", "b": "2"])
    }

    func testMapKeyBoundTwiceIsRejected() {
        for text in [
            #"labels = { a: "1" a: "2" }"#,
            #"labels = { a: "1" a: "1" }"#,
            "labels = { a: \"1\" }\nlabels = { a: \"2\" }",
            #"nums = { 1: "x" "1": "y" }"#,
            "inners = { k: { a = 1 } k: { b = 2 } }",
        ] {
            XCTAssertThrowsError(try decode(text), text)
        }
    }

    func testEachListElementIsItsOwnMapScope() throws {
        struct Element: Codable { var labels: [String: String] }
        struct Root: Codable { var items: [Element] }
        let r = try PXFDecoder().decode(Root.self, from: #"items = [ { labels = { a: "1" } }, { labels = { a: "2" } } ]"#)
        XCTAssertEqual(r.items.map(\.labels), [["a": "1"], ["a": "2"]])
    }

    // MARK: repeated and singular (#33, #25)

    func testRepeatedBindingsConcatenate() throws {
        XCTAssertEqual(try decode("tags = [\"a\"]\ntags = [\"b\", \"c\"]").tags, ["a", "b", "c"])
    }

    func testSingularBoundTwiceIsRejected() {
        for text in [
            "s = \"a\"\ns = \"b\"",
            "s = \"a\"\ns = \"a\"",
            "s = null\ns = \"a\"",
            "m { a = 1 }\nm { b = 2 }",
            "m = { a = 1 }\nm { b = 2 }",
            "m { a = 1 a = 2 }",
        ] {
            XCTAssertThrowsError(try decode(text), text)
        }
    }

    func testEachBodyIsItsOwnScope() throws {
        struct Root: Codable { var x: Inner?; var y: Inner? }
        let r = try PXFDecoder().decode(Root.self, from: "x { a = 1 }\ny { a = 2 }")
        XCTAssertEqual(r.x?.a, 1)
        XCTAssertEqual(r.y?.a, 2)
    }

    // MARK: no silent narrowing

    func testAnIntegerOutOfRangeThrowsRatherThanTraps() {
        struct Narrow: Codable { var n: Int8 }
        XCTAssertThrowsError(try PXFDecoder().decode(Narrow.self, from: "n = 300"))
    }

    func testAListElementOfTheWrongTypeThrowsRatherThanZeroes() {
        struct Numbers: Codable { var n: [Int32] }
        XCTAssertThrowsError(try PXFDecoder().decode(Numbers.self, from: #"n = [1, "x"]"#))
        XCTAssertThrowsError(try PXFDecoder().decode(Numbers.self, from: "n = [3000000000]"))
    }

    // MARK: schema-bound

    private static let schema: PXF.Annotations = {
        func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                   typeName: String? = nil, repeated: Bool = false, required: Bool = false, defaultLiteral: String? = nil,
                   oneof: Int32? = nil) -> Google_Protobuf_FieldDescriptorProto {
            var f = Google_Protobuf_FieldDescriptorProto()
            f.name = name
            f.number = number
            f.type = type
            f.label = repeated ? .repeated : .optional
            if let typeName { f.typeName = "." + typeName }
            if required { f.options.Pxf_required = true }
            if let defaultLiteral { f.options.Pxf_default = defaultLiteral }
            if let oneof { f.oneofIndex = oneof }
            return f
        }
        var entry = Google_Protobuf_DescriptorProto()
        entry.name = "ByKeyEntry"
        entry.options.mapEntry = true
        entry.field = [field("key", 1, .string), field("value", 2, .message, typeName: "b.v1.Elem")]
        var elem = Google_Protobuf_DescriptorProto()
        elem.name = "Elem"
        elem.field = [field("name", 1, .string, defaultLiteral: "dflt"), field("req", 2, .string, required: true)]
        var root = Google_Protobuf_DescriptorProto()
        root.name = "Root"
        root.nestedType = [entry]
        root.field = [
            field("id", 1, .string),
            field("by_key", 2, .message, typeName: "b.v1.Root.ByKeyEntry", repeated: true),
            field("first", 3, .string, defaultLiteral: "f", oneof: 0),
            field("second", 4, .string, oneof: 0),
        ]
        var oneof = Google_Protobuf_OneofDescriptorProto()
        oneof.name = "pick"
        root.oneofDecl = [oneof]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "b.proto"
        file.package = "b.v1"
        file.syntax = "proto3"
        file.messageType = [root, elem]
        return PXF.Annotations(files: [file])
    }()

    struct Elem: Codable, Equatable { var name: String?; var req: String? }
    struct Root: Codable { var id: String?; var by_key: [String: Elem]?; var first: String?; var second: String? }

    private func bound() -> PXFDecoder { PXFDecoder(annotations: Self.schema, rootMessage: "b.v1.Root") }

    func testDefaultsAndRequiredApplyInMapValues() throws {
        let r = try bound().decode(Root.self, from: #"by_key = { a: { req = "x" } }"#)
        XCTAssertEqual(r.by_key?["a"], Elem(name: "dflt", req: "x"))
        XCTAssertThrowsError(try bound().decode(Root.self, from: "by_key = { a: {} }")) { error in
            XCTAssertEqual(error as? PXF.AnnotationError, .requiredFieldAbsent(path: "by_key[\"a\"].req"))
        }
    }

    func testAOneofDefaultStaysOffWhenASiblingIsPresent() throws {
        XCTAssertEqual(try bound().decode(Root.self, from: "").first, "f")
        let r = try bound().decode(Root.self, from: #"second = "s""#)
        XCTAssertNil(r.first)
        XCTAssertEqual(r.second, "s")
    }

    func testABareIdentifierIsNotAString() {
        XCTAssertThrowsError(try bound().decode(Root.self, from: "id = foo")) { error in
            XCTAssertEqual((error as? PXF.BindError)?.message, "expected string for field \"id\"")
        }
    }

    func testAnUnknownFieldIsAnErrorUnlessDiscarded() throws {
        XCTAssertThrowsError(try bound().decode(Root.self, from: "nope = 1"))
        let d = bound()
        d.discardUnknown = true
        XCTAssertNoThrow(try d.decode(Root.self, from: "nope = 1"))
    }
}
