// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

// An entry name of a keyed block populates the element's key field (draft -01
// §3.13), so it counts as the document supplying that field (protowire-go#214).
// Mirrors protowire-go's encoding/pxf/keyed_entry_name_presence_test.go.
//
// The Swift decoder rewrites a named entry to an anonymous element with the
// key written out, so the value was never lost here. What was wrong is the
// Result: its paths lost the message they belong to, and a property read
// without `contains` recorded nothing. The value cases below pin that the
// rewrite keeps giving the name to the key, including when `PXFDecoder` starts
// applying annotations inside list elements as Go does.

private struct WithDefault: Codable { var name: String? }
private struct RequiredName: Codable { var name: String }
private struct NoKeyProperty: Codable {}
private struct InOneof: Codable { var name: String?; var other: String? }
private struct Nests: Codable { var name: String?; var inner: [WithDefault]? }
private struct P: Codable {
    var kd: [WithDefault]?
    var kr: [WithDefault]?
    var ko: [InOneof]?
    var kn: [Nests]?
    var one: InOneof?
}

final class PXFKeyedEntryNamePresenceTests: XCTestCase {
    private typealias FieldType = Google_Protobuf_FieldDescriptorProto.TypeEnum

    private static func field(_ name: String, _ number: Int32, _ type: FieldType = .string, typeName: String? = nil,
                              repeated: Bool = false, required: Bool = false, defaultLiteral: String? = nil,
                              key: String? = nil, oneof: Bool = false) -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = repeated ? .repeated : .optional
        if let typeName { f.typeName = ".keyedname.v1." + typeName }
        if required { f.options.Pxf_required = true }
        if let defaultLiteral { f.options.Pxf_default = defaultLiteral }
        if let key { f.options.Pxf_key = key }
        if oneof { f.oneofIndex = 0 }
        return f
    }

    private static func message(_ name: String, _ fields: [Google_Protobuf_FieldDescriptorProto]) -> Google_Protobuf_DescriptorProto {
        var m = Google_Protobuf_DescriptorProto()
        m.name = name
        m.field = fields
        return m
    }

    /// keyedname.v1 as in the Go test, plus a singular `one` to compare paths.
    private static let annotations: PXF.Annotations = {
        var inOneof = message("InOneof", [field("name", 1, oneof: true), field("other", 2, defaultLiteral: "other-dflt", oneof: true)])
        var pick = Google_Protobuf_OneofDescriptorProto()
        pick.name = "pick"
        inOneof.oneofDecl = [pick]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "keyedname.proto"
        file.package = "keyedname.v1"
        file.messageType = [
            message("P", [
                field("kd", 1, .message, typeName: "WithDefault", repeated: true, key: "name"),
                field("kr", 2, .message, typeName: "WithRequired", repeated: true, key: "name"),
                field("ko", 3, .message, typeName: "InOneof", repeated: true, key: "name"),
                field("kn", 4, .message, typeName: "Nests", repeated: true, key: "name"),
                field("one", 5, .message, typeName: "InOneof"),
            ]),
            message("WithDefault", [field("name", 1, defaultLiteral: "dflt")]),
            message("WithRequired", [field("name", 1, required: true)]),
            inOneof,
            message("Nests", [field("name", 1), field("inner", 2, .message, typeName: "WithDefault", repeated: true, key: "name")]),
        ]
        return PXF.Annotations(files: [file])
    }()

    private func decoder() -> PXFDecoder {
        PXFDecoder(annotations: Self.annotations, rootMessage: "keyedname.v1.P")
    }

    func testEntryNameSuppliesTheKeyField() throws {
        let cases: [(doc: String, value: (P) -> String?, want: String, mark: String)] = [
            (#"kd { alpha {} }"#, { $0.kd?[0].name }, "alpha", "kd[0].name"),
            (#"kd { "not ident" {} }"#, { $0.kd?[0].name }, "not ident", "kd[0].name"),
            (#"kd { alpha = {} }"#, { $0.kd?[0].name }, "alpha", "kd[0].name"),
            (#"kd = { alpha {} }"#, { $0.kd?[0].name }, "alpha", "kd[0].name"),
            (#"kd { a {} alpha {} }"#, { $0.kd?[1].name }, "alpha", "kd[1].name"),
            (#"kd { alpha { name = "alpha" } }"#, { $0.kd?[0].name }, "alpha", "kd[0].name"),
            (#"kr { alpha {} }"#, { $0.kr?[0].name }, "alpha", "kr[0].name"),
            (#"ko { alpha {} }"#, { $0.ko?[0].name }, "alpha", "ko[0].name"),
            (#"kn { a { inner { alpha {} } } }"#, { $0.kn?[0].inner?[0].name }, "alpha", "kn[0].inner[0].name"),
        ]
        for c in cases {
            let (value, result) = try decoder().unmarshalFull(P.self, from: c.doc)
            XCTAssertEqual(c.value(value), c.want, c.doc)
            XCTAssertTrue(result.isSet(c.mark), "\(c.doc) present: \(result.allSetFields)")
            XCTAssertFalse(result.isAbsent(c.mark), c.doc)
            XCTAssertFalse(result.isSet("name"), "\(c.doc) marked the root: \(result.allSetFields)")
        }
        XCTAssertEqual(cases.count, 9)
    }

    /// The other member of the key's oneof must not see the key as unset.
    func testOneofSiblingDefaultStaysOff() throws {
        let (value, _) = try decoder().unmarshalFull(P.self, from: "ko { alpha {} }")
        XCTAssertEqual(value.ko?.first?.name, "alpha")
        XCTAssertNil(value.ko?.first?.other)
    }

    /// Go marks the key whatever reads it. Here the Swift type decides how a
    /// field is read, so the mark must not depend on `contains` being called.
    func testMarkDoesNotDependOnHowTheTypeReadsTheKey() throws {
        struct Strict: Codable { var kr: [RequiredName] }
        let (strict, strictResult) = try decoder().unmarshalFull(Strict.self, from: "kr { alpha {} }")
        XCTAssertEqual(strict.kr.first?.name, "alpha")
        XCTAssertTrue(strictResult.isSet("kr[0].name"), "present: \(strictResult.allSetFields)")

        struct Bare: Codable { var kd: [NoKeyProperty]? }
        let (_, bareResult) = try decoder().unmarshalFull(Bare.self, from: "kd { alpha {} }")
        XCTAssertTrue(bareResult.isSet("kd[0].name"), "present: \(bareResult.allSetFields)")
    }

    /// Only an entry name counts as supplying the key.
    func testAnonymousElementSuppliesNoKey() throws {
        let (_, result) = try decoder().unmarshalFull(P.self, from: "kd = [{}]")
        XCTAssertTrue(result.isAbsent("kd[0].name"), "present: \(result.allSetFields)")
    }

    func testMarkedInsideAnAnyBody() throws {
        struct Holder: Codable { var payload: Google_Protobuf_Any? }
        struct Resolver: PXF.TypeResolver {
            func resolve(typeURL: String) -> Decodable.Type? { Nests.self }
        }
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "any.proto"
        file.package = "keyedname.v1"
        file.dependency = ["keyedname.proto"]
        var payload = Self.field("payload", 1, .message)
        payload.typeName = ".google.protobuf.Any"
        file.messageType = [Self.message("Holder", [payload])]
        var base = Google_Protobuf_FileDescriptorProto()
        base.name = "keyedname.proto"
        base.package = "keyedname.v1"
        base.messageType = [
            Self.message("WithDefault", [Self.field("name", 1, defaultLiteral: "dflt")]),
            Self.message("Nests", [Self.field("name", 1), Self.field("inner", 2, .message, typeName: "WithDefault", repeated: true, key: "name")]),
        ]
        let dec = PXFDecoder(annotations: PXF.Annotations(files: [base, file]), rootMessage: "keyedname.v1.Holder")
        dec.typeResolver = Resolver()
        let (_, result) = try dec.unmarshalFull(Holder.self, from: "payload = @type keyedname.v1.Nests { inner { alpha {} } }")
        XCTAssertTrue(result.isSet("payload.inner[0].name"), "present: \(result.allSetFields)")
    }

    /// One root cause with the keyed case: a mark made inside a message body
    /// is recorded under that message, not under the document root.
    func testMarksInsideASingularMessageNameIt() throws {
        let (_, set) = try decoder().unmarshalFull(P.self, from: #"one { name = "x" }"#)
        XCTAssertTrue(set.isSet("one.name"), "present: \(set.allSetFields)")
        XCTAssertTrue(set.isAbsent("name"), "present: \(set.allSetFields)")

        let (_, null) = try decoder().unmarshalFull(P.self, from: "one { name = null }")
        XCTAssertTrue(null.isNull("one.name"), "null: \(null.allNullFields)")
        XCTAssertFalse(null.isNull("name"), "null: \(null.allNullFields)")
    }

    /// protowire-go#170: `_null` names fields, not list elements. The Result
    /// records a null inside an element; the mask does not.
    func testNullInsideAnElementStaysOutOfTheMask() throws {
        struct Masked: Codable {
            var kd: [WithDefault]?
            var one: InOneof?
            var _null: [String]
        }
        let doc = "kd = [{ name = null }]\none { name = null }"
        let (value, result) = try decoder().unmarshalFull(Masked.self, from: doc)
        XCTAssertEqual(result.allNullFields, ["kd[0].name", "one.name"])
        XCTAssertEqual(value._null, ["one.name"])
    }
}
