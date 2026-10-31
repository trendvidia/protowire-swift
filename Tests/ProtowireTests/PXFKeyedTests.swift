// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

// Keyed repeated fields (draft -01 "Keyed Repeated Fields"; protowire#116,
// protowire-swift#7). `testdata/keyed/` is vendored verbatim from the spec
// repository's testdata/keyed/ and shared by every port; keep the two in sync
// when the spec repo adds fixtures. `keyed.binpb` is its keyed.proto with
// proto/pxf/annotations.proto as a descriptor set: copy both into a scratch
// directory (annotations under pxf/) and run
// `buf build --as-file-descriptor-set --exclude-source-info -o keyed.binpb`.

private struct Node: Codable, Equatable {
    var id: String?
    var type: String?
    var weight: Int32?
    var children: [Node]?
}
private struct Region: Codable, Equatable {
    var name: String?
    var replicas: Int32?
}
private struct Deployment: Codable, Equatable {
    var service: String?
    var regions: [Region]?
}
private struct Plain: Codable, Equatable {
    var id: String?
    var label: String?
}
private struct Doc: Codable, Equatable {
    var items: [Plain]?
}

final class PXFKeyedTests: XCTestCase {

    // MARK: harness

    private static let directory = Bundle.module.resourceURL!.appendingPathComponent("testdata/keyed")

    private static let annotations: PXF.Annotations = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("keyed.binpb"))
        let set = try! Google_Protobuf_FileDescriptorSet(serializedBytes: data, extensions: Pxf_Annotations_Extensions)
        return PXF.Annotations(descriptorSet: set)
    }()

    private func read(_ name: String) throws -> String {
        try String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func decoder(_ type: String) -> PXFDecoder {
        PXFDecoder(annotations: Self.annotations, rootMessage: type)
    }

    private func encoder(_ type: String) -> PXFEncoder {
        PXFEncoder(annotations: Self.annotations, rootMessage: type)
    }

    private func typeURL(of text: String) throws -> String {
        try XCTUnwrap(try PXF.Parser(string: text).parseDocument().typeURL)
    }

    /// Strips comment lines and collapses the blank runs they leave, giving
    /// the document the encoder is expected to reproduce: the fixtures'
    /// comments are documentation, not content.
    private func clean(_ text: String) -> String {
        var s = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop { $0 == " " || $0 == "\t" }.hasPrefix("#") }
            .joined(separator: "\n")
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while s.hasSuffix("\n") { s.removeLast() }
        return s + "\n"
    }

    /// `pxf fmt`: parse, canonicalize against the schema, format.
    private func fmt(_ text: String) throws -> String {
        var doc = try PXF.Parser(string: text).parseDocument()
        Self.annotations.canonicalizeKeyed(&doc, message: try XCTUnwrap(doc.typeURL))
        return PXF.Format.formatDocument(doc)
    }

    /// Decode → encode, the `@type` header restored: the encoder writes
    /// bodies only.
    private func reencoded(_ text: String) throws -> String {
        let type = try typeURL(of: text)
        let body: String
        switch type {
        case "keyed.v1.Node":
            body = try encoder(type).encode(try decoder(type).decode(Node.self, from: text))
        case "keyed.v1.Deployment":
            body = try encoder(type).encode(try decoder(type).decode(Deployment.self, from: text))
        default:
            body = try encoder(type).encode(try decoder(type).decode(Doc.self, from: text))
        }
        return "@type \(type)\n\n\(body)"
    }

    private func assertRejected(_ name: String, kind: PXF.KeyedErrorKind, message: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try read(name)
        // The grammar accepts every one of these; the schema layer rejects.
        XCTAssertNoThrow(try PXF.Parser(string: text).parseDocument(), name, file: file, line: line)
        let type = try typeURL(of: text)
        func check(_ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), name, file: file, line: line) { error in
                let keyed = error as? PXF.KeyedError
                XCTAssertEqual(keyed?.kind, kind, "\(name): \(error)", file: file, line: line)
                XCTAssertEqual(keyed?.message, message, name, file: file, line: line)
            }
        }
        if type == "keyed.v1.Doc" {
            check { _ = try decoder(type).decode(Doc.self, from: text) }
            check { _ = try decoder(type).unmarshalFull(Doc.self, from: text) }
        } else {
            check { _ = try decoder(type).decode(Node.self, from: text) }
            check { _ = try decoder(type).unmarshalFull(Node.self, from: text) }
        }
    }

    // MARK: every fixture

    /// One verdict per file. The switch has no silent default, and the count
    /// at the end is the positive marker that the corpus really ran.
    func testEveryFixture() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".pxf") }.sorted()
        var ran = 0
        for name in names {
            switch name {
            case "roundtrip-keyed.pxf", "roundtrip-quoted.pxf":
                try checkRoundtrip(name)
            case "anonymous-equivalence.pxf":
                try checkAnonymousEquivalence(name)
            case "redundant-key-ok.pxf":
                try checkRedundantKey(name)
            case "anonymous-duplicate-ok.pxf":
                try checkAnonymousDuplicate(name)
            case "fmt-unquote.pxf", "fmt-anonymous-to-keyed.pxf":
                let expected = name.replacingOccurrences(of: ".pxf", with: ".expected.pxf")
                XCTAssertEqual(try fmt(try read(name)), try read(expected), name)
            case "fmt-unquote.expected.pxf", "fmt-anonymous-to-keyed.expected.pxf":
                XCTAssertEqual(try fmt(try read(name)), try read(name), "\(name) must be a fixed point")
            case "err-duplicate-key.pxf", "err-duplicate-key-spelling.pxf":
                try assertRejected(name, kind: .duplicateKey, message: "duplicate key \"greeting\" in keyed field \"children\"")
            case "err-key-conflict.pxf":
                try assertRejected(name, kind: .keyConflict, message: "key field \"id\" = \"farewell\" conflicts with entry name \"greeting\" in keyed field \"children\"")
            case "err-empty-key.pxf":
                try assertRejected(name, kind: .emptyKey, message: "empty entry name in keyed field \"children\": the empty string is not a valid key")
            case "err-empty-key-anonymous.pxf":
                try assertRejected(name, kind: .emptyKey, message: "explicit empty-string assignment to key field \"id\" of keyed field \"children\": the empty string is not a valid key")
            case "err-quoted-name-unkeyed.pxf":
                try assertRejected(name, kind: .quotedNameUnkeyed, message: "quoted entry name \"a\" is only valid inside a keyed repeated field's block (draft -01 §3.13)")
            default:
                XCTFail("\(name) has no verdict in this harness")
                continue
            }
            ran += 1
        }
        print("keyed fixtures ran: \(ran) of \(names.count)")
        XCTAssertEqual(ran, 15)
        XCTAssertEqual(ran, names.count)
    }

    private func checkRoundtrip(_ name: String) throws {
        let text = try read(name)
        XCTAssertEqual(try reencoded(text), clean(text), "\(name): decode → encode must reproduce the body")
    }

    private func checkAnonymousEquivalence(_ name: String) throws {
        let text = try read(name)
        let keyed = try read("roundtrip-keyed.pxf")
        let type = try typeURL(of: text)
        let anonymousNode = try decoder(type).decode(Node.self, from: text)
        XCTAssertEqual(anonymousNode, try decoder(type).decode(Node.self, from: keyed), "same message in either form")
        XCTAssertEqual(anonymousNode.children?.map(\.id), ["greeting", "counter_row"])
        XCTAssertEqual(try reencoded(text), clean(keyed), "encode writes the keyed form")
        // fmt keeps this fixture's comments, the encoder has none to keep.
        XCTAssertEqual(clean(try fmt(text)), clean(keyed), "fmt writes the keyed form")
    }

    private func checkRedundantKey(_ name: String) throws {
        let text = try read(name)
        let type = try typeURL(of: text)
        let node = try decoder(type).decode(Node.self, from: text)
        XCTAssertEqual(node.children?.map(\.id), ["greeting"])
        let keyLines = { (s: String) in s.components(separatedBy: "id = ").count - 1 }
        XCTAssertEqual(keyLines(try fmt(text)), 1, "only the root's own id survives fmt")
        XCTAssertEqual(keyLines(try reencoded(text)), 1, "only the root's own id survives encode")
    }

    private func checkAnonymousDuplicate(_ name: String) throws {
        let text = try read(name)
        let type = try typeURL(of: text)
        let node = try decoder(type).decode(Node.self, from: text)
        XCTAssertEqual(node.children?.map(\.id), ["dup", "dup"])
        let encoded = try reencoded(text)
        XCTAssertTrue(encoded.contains("children = [\n"), encoded)
        XCTAssertEqual(try decoder(type).decode(Node.self, from: encoded), node, "the anonymous output reads back")
        XCTAssertTrue(try fmt(text).contains("children = [\n"))
    }

    // MARK: beyond the fixtures

    func testDescriptorIsTheFixtureSchema() throws {
        let node = try XCTUnwrap(Self.annotations.message("keyed.v1.Node"))
        XCTAssertEqual(node.field(named: "children")?.keyName, "id")
        XCTAssertEqual(Self.annotations.keyField(of: try XCTUnwrap(node.field(named: "children")))?.name, "id")
        XCTAssertNil(Self.annotations.keyField(of: try XCTUnwrap(node.field(named: "id"))))
        let doc = try XCTUnwrap(Self.annotations.message("keyed.v1.Doc"))
        XCTAssertNil(Self.annotations.keyField(of: try XCTUnwrap(doc.field(named: "items"))))
    }

    func testIdentSafeEntryName() {
        for (name, safe) in [("greeting", true), ("user.name", true), ("_x1", true), ("A", true),
                             ("us-east-1", false), ("1abc", false), ("", false), (".a", false),
                             ("true", false), ("false", false), ("null", false), ("é", false)] {
            XCTAssertEqual(PXF.Format.identSafeEntryName(name), safe, name)
        }
    }

    func testAssignmentSpelling() throws {
        let text = """
        id = "root"
        children = {
          greeting { type = "Label" }
          counter_row = { type = "HBox" }
        }
        """
        let node = try decoder("keyed.v1.Node").decode(Node.self, from: text)
        XCTAssertEqual(node.children?.map(\.id), ["greeting", "counter_row"])

        var doc = try PXF.Parser(string: text).parseDocument()
        Self.annotations.canonicalizeKeyed(&doc, message: "keyed.v1.Node")
        XCTAssertEqual(PXF.Format.formatDocument(doc), """
        id = "root"
        children {
          greeting {
            type = "Label"
          }
          counter_row {
            type = "HBox"
          }
        }

        """)
    }

    func testNamedEntry_mustBeABlock() {
        for text in [#"children { greeting = "x" }"#, #"children { greeting: { type = "x" } }"#] {
            XCTAssertThrowsError(try decoder("keyed.v1.Node").decode(Node.self, from: text), text) { error in
                XCTAssertEqual((error as? PXF.KeyedError)?.kind, .malformedEntry, "\(error)")
            }
        }
    }

    func testBindingsConcatenateInDocumentOrder() throws {
        let text = """
        children { a { type = "Label" } }
        children = [ { id = "b" type = "HBox" } ]
        children = { c { type = "VBox" } }
        """
        let node = try decoder("keyed.v1.Node").decode(Node.self, from: text)
        XCTAssertEqual(node.children?.map(\.id), ["a", "b", "c"])
    }

    func testDuplicateRule_isPerBlock() throws {
        let text = #"children { a { } } children { a { } }"#
        let node = try decoder("keyed.v1.Node").decode(Node.self, from: text)
        XCTAssertEqual(node.children?.map(\.id), ["a", "a"])
    }

    func testNestedKeyedBlocks() throws {
        let text = """
        id = "root"
        children {
          outer {
            children {
              inner {
                type = "Leaf"
              }
            }
          }
        }

        """
        let node = try decoder("keyed.v1.Node").decode(Node.self, from: text)
        XCTAssertEqual(node.children?.first?.children?.first?.id, "inner")
        XCTAssertEqual(try encoder("keyed.v1.Node").encode(node), text)
    }

    func testKeysAreComparedByBytes() throws {
        // Canonically equivalent to Swift's ==, but two different keys.
        let (composed, decomposed) = ("caf\u{E9}", "cafe\u{301}")
        XCTAssertEqual(composed, decomposed)
        let text = "children { \"\(composed)\" { } \"\(decomposed)\" { } }"
        let node = try decoder("keyed.v1.Node").decode(Node.self, from: text)
        XCTAssertEqual(node.children?.count, 2)
        XCTAssertTrue(try encoder("keyed.v1.Node").encode(node).hasPrefix("children {\n"))

        let conflict = "children { \"\(composed)\" { id = \"\(decomposed)\" } }"
        XCTAssertThrowsError(try decoder("keyed.v1.Node").decode(Node.self, from: conflict)) { error in
            XCTAssertEqual((error as? PXF.KeyedError)?.kind, .keyConflict)
        }
    }

    func testEncoder_fallsBackToAnonymousWhenIneligible() throws {
        let enc = encoder("keyed.v1.Node")
        let absent = try enc.encode(Node(children: [Node(id: "a", type: "T"), Node(type: "T")]))
        XCTAssertEqual(absent, "children = [\n  {\n    id = \"a\"\n    type = \"T\"\n  },\n  {\n    type = \"T\"\n  }\n]\n")
        let empty = try enc.encode(Node(children: [Node(id: "a"), Node(id: "", type: "T")]))
        XCTAssertFalse(empty.contains("id = \"\""), "an explicit empty key would not read back:\n\(empty)")
        XCTAssertNoThrow(try decoder("keyed.v1.Node").decode(Node.self, from: empty))
        let duplicate = try enc.encode(Node(children: [Node(id: "a"), Node(id: "a")]))
        XCTAssertTrue(duplicate.hasPrefix("children = [\n"), duplicate)
        XCTAssertEqual(try enc.encode(Node(children: [Node(id: "a", type: "T"), Node(id: "b", type: "T")])),
                       "children {\n  a {\n    type = \"T\"\n  }\n  b {\n    type = \"T\"\n  }\n}\n")
    }

    func testEncoder_quotesWhatIsNotIdentifierSafe() throws {
        let out = try encoder("keyed.v1.Deployment").encode(
            Deployment(regions: [Region(name: "true"), Region(name: "a.b"), Region(name: "x y\"")]))
        XCTAssertEqual(out, "regions {\n  \"true\" {\n  }\n  a.b {\n  }\n  \"x y\\\"\" {\n  }\n}\n")
        let back = try decoder("keyed.v1.Deployment").decode(Deployment.self, from: out)
        XCTAssertEqual(back.regions?.map(\.name), ["true", "a.b", "x y\""])
    }

    func testEncoder_emptyListWritesNothing() throws {
        XCTAssertEqual(try encoder("keyed.v1.Node").encode(Node(id: "a", children: [])), "id = \"a\"\n")
    }

    func testEncoder_withoutAnnotations_isUnchanged() throws {
        XCTAssertFalse(try PXFEncoder().encode(Node(children: [Node(id: "a")])).contains("children {"))
    }

    func testQuotedName_isRejectedWithoutASchema() {
        for text in [#""id" = "a""#, #""children" { }"#, #"children = { "a" { } }"#, #"children = [ { "id" = "a" } ]"#] {
            XCTAssertThrowsError(try PXFDecoder().decode(Node.self, from: text), text) { error in
                XCTAssertEqual((error as? PXF.KeyedError)?.kind, .quotedNameUnkeyed, "\(error)")
            }
        }
    }

    func testQuotedName_isRejectedInMessageContextWithASchema() {
        for text in [#""id" = "a""#, #""children" { a { } }"#, #"children { a { "type" = "x" } }"#] {
            XCTAssertThrowsError(try decoder("keyed.v1.Node").decode(Node.self, from: text), text) { error in
                XCTAssertEqual((error as? PXF.KeyedError)?.kind, .quotedNameUnkeyed, "\(error)")
            }
        }
    }

    func testResult_seesTheKeyedField() throws {
        let (_, result) = try decoder("keyed.v1.Node").unmarshalFull(Node.self, from: #"children { a { } }"#)
        XCTAssertTrue(result.isSet("children"))
    }

    // MARK: placement

    private static func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                              typeName: String? = nil, repeated: Bool = false, key: String? = nil) -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = repeated ? .repeated : .optional
        if let typeName { f.typeName = "." + typeName }
        if let key { f.options.Pxf_key = key }
        return f
    }

    private static func file(_ name: String, imports: [String] = [], _ messages: (String, [Google_Protobuf_FieldDescriptorProto])...) -> Google_Protobuf_FileDescriptorProto {
        var f = Google_Protobuf_FileDescriptorProto()
        f.name = name
        f.package = "p"
        f.dependency = imports
        f.messageType = messages.map { name, fields in
            var m = Google_Protobuf_DescriptorProto()
            m.name = name
            m.field = fields
            return m
        }
        return f
    }

    private static let element = ("E", [field("id", 1, .string), field("n", 2, .int32), field("tags", 3, .string, repeated: true)])

    private func assertViolation(_ root: Google_Protobuf_FieldDescriptorProto, _ detail: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let set = PXF.Annotations(files: [Self.file("a.proto", Self.element, ("Root", [root]))])
        XCTAssertThrowsError(try set.validateKeyPlacement(message: "p.Root"), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(detail), "\(error)", file: file, line: line)
        }
        XCTAssertNil(set.keyField(of: set.message("p.Root")!.fields[0]), file: file, line: line)
    }

    func testPlacement_rejections() {
        assertViolation(Self.field("x", 1, .string, key: "id"), "valid only on repeated message-typed fields")
        assertViolation(Self.field("x", 1, .message, typeName: "p.E", key: "id"), "valid only on repeated message-typed fields")
        assertViolation(Self.field("x", 1, .string, repeated: true, key: "id"), "valid only on repeated message-typed fields")
        assertViolation(Self.field("x", 1, .message, typeName: "p.E", repeated: true, key: "nope"), "has no field \"nope\"")
        assertViolation(Self.field("x", 1, .message, typeName: "p.E", repeated: true, key: ""), "has no field \"\"")
        assertViolation(Self.field("x", 1, .message, typeName: "p.E", repeated: true, key: "n"), "must be a singular string field")
        assertViolation(Self.field("x", 1, .message, typeName: "p.E", repeated: true, key: "tags"), "must be a singular string field")
    }

    func testPlacement_rejectsAMapField() throws {
        var entry = Google_Protobuf_DescriptorProto()
        entry.name = "XEntry"
        entry.options.mapEntry = true
        entry.field = [Self.field("key", 1, .string), Self.field("value", 2, .message, typeName: "p.E")]
        var file = Self.file("a.proto", Self.element, ("Root", [Self.field("x", 1, .message, typeName: "p.Root.XEntry", repeated: true, key: "id")]))
        file.messageType[1].nestedType = [entry]
        XCTAssertThrowsError(try PXF.Annotations(files: [file]).validateKeyPlacement(message: "p.Root"))
    }

    func testPlacement_coversTheImportClosureAndNothingElse() throws {
        let bad = Self.field("x", 1, .string, key: "id")
        let good = Self.file("good.proto", ("Ok", [Self.field("id", 1, .string)]))
        let deep = Self.file("deep.proto", ("Bad", [bad]))
        let middle = Self.file("middle.proto", imports: ["deep.proto"], ("Mid", [Self.field("id", 1, .string)]))
        let root = Self.file("root.proto", imports: ["middle.proto"], ("Root", [Self.field("id", 1, .string)]))
        let set = PXF.Annotations(files: [good, deep, middle, root])
        XCTAssertThrowsError(try set.validateKeyPlacement(message: "p.Root")) { error in
            XCTAssertEqual("\(error)", "deep.proto: field \"p.Bad.x\": invalid (pxf.key) = \"id\": (pxf.key) is valid only on repeated message-typed fields (draft -01 §3.13)")
        }
        XCTAssertNoThrow(try set.validateKeyPlacement(message: "p.Ok"), "good.proto does not import deep.proto")
    }

    func testDecoderAndEncoder_refuseABadSchema() {
        let set = PXF.Annotations(files: [Self.file("a.proto", ("Root", [Self.field("id", 1, .string, key: "id")]))])
        XCTAssertThrowsError(try PXFDecoder(annotations: set, rootMessage: "p.Root").decode(Node.self, from: "id = \"a\""))
        XCTAssertThrowsError(try PXFEncoder(annotations: set, rootMessage: "p.Root").encode(Node(id: "a")))
    }

    func testKeyedFieldsInsideMapValuesAndSingularMessages() throws {
        struct Holder: Codable, Equatable { var one: Node?; var many: [String: Node]? }
        var entry = Google_Protobuf_DescriptorProto()
        entry.name = "ManyEntry"
        entry.options.mapEntry = true
        entry.field = [Self.field("key", 1, .string), Self.field("value", 2, .message, typeName: "p.N")]
        var file = Self.file("a.proto",
                             ("N", [Self.field("id", 1, .string), Self.field("children", 2, .message, typeName: "p.N", repeated: true, key: "id")]),
                             ("Holder", [Self.field("one", 1, .message, typeName: "p.N"),
                                         Self.field("many", 2, .message, typeName: "p.Holder.ManyEntry", repeated: true)]))
        file.messageType[1].nestedType = [entry]
        let set = PXF.Annotations(files: [file])
        let text = """
        one { children { a { } } }
        many = { "m": { children { b { } } } }
        """
        // The typed result of `one`. A message-valued map is read at the AST:
        // the Codable bridge does not decode map values that are messages at
        // all, keyed or not, so a Holder could not show this.
        let holder = try PXFDecoder(annotations: set, rootMessage: "p.Holder").decode(Holder.self, from: text)
        XCTAssertEqual(holder.one?.children?.map(\.id), ["a"])

        let doc = try PXF.Parser(string: text).parseDocument()
        let expanded = try set.expandKeyed(doc.entries, message: "p.Holder")
        let many = try XCTUnwrap((expanded[1] as? PXF.Assignment)?.value as? PXF.BlockVal)
        let value = try XCTUnwrap((many.entries.first as? PXF.MapEntry)?.value as? PXF.BlockVal)
        let children = try XCTUnwrap((value.entries.first as? PXF.Assignment)?.value as? PXF.ListVal)
        let element = try XCTUnwrap(children.elements.first as? PXF.BlockVal)
        XCTAssertEqual((element.entries.first as? PXF.Assignment)?.key, "id")
        XCTAssertEqual(((element.entries.first as? PXF.Assignment)?.value as? PXF.StringVal)?.value, "b")
    }

    func testKeyedFieldInsideAnAnyBody() throws {
        struct Holder: Codable { var payload: Google_Protobuf_Any? }
        struct Resolver: PXF.TypeResolver {
            func resolve(typeURL: String) -> Decodable.Type? { Node.self }
        }
        var any = Google_Protobuf_DescriptorProto()
        any.name = "Holder"
        any.field = [Self.field("payload", 1, .message, typeName: "google.protobuf.Any")]
        var file = Self.file("a.proto", ("N", [Self.field("id", 1, .string), Self.field("children", 2, .message, typeName: "p.N", repeated: true, key: "id")]))
        file.messageType.append(any)
        let set = PXF.Annotations(files: [file])
        let dec = PXFDecoder(annotations: set, rootMessage: "p.Holder")
        dec.typeResolver = Resolver()
        // A quoted name is a key here, because the body's type is keyed. The
        // same body is an error when the block names no type this set knows.
        XCTAssertNoThrow(try dec.decode(Holder.self, from: #"payload = @type p.N { children { "a-b" { } } }"#))
        XCTAssertThrowsError(try dec.decode(Holder.self, from: #"payload = @type p.Other { children { "a-b" { } } }"#))
    }
}
