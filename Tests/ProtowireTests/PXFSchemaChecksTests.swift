// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf
import XCTest
@testable import Protowire

/// The bind-time checks: a schema the draft refuses fails on every document,
/// and the valid neighbour of each rule binds. The verdicts are the reference's
/// `ValidateFile`, recorded on the PR that added these.
final class PXFSchemaChecksTests: XCTestCase {
    private typealias FieldType = Google_Protobuf_FieldDescriptorProto.TypeEnum

    private static func field(_ name: String, _ number: Int32, _ type: FieldType, typeName: String? = nil,
                              repeated: Bool = false, required: Bool = false, defaultLiteral: String? = nil,
                              oneof: Int32? = nil, carrier: Data? = nil) -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = repeated ? .repeated : .optional
        if let typeName { f.typeName = "." + typeName }
        if required { f.options.Pxf_required = true }
        if let defaultLiteral { f.options.Pxf_default = defaultLiteral }
        if let oneof { f.oneofIndex = oneof }
        if let carrier { f.options.unknownFields = Self.unknown(carrier) }
        return f
    }

    /// `bytes` as a FieldOptions' unknown fields.
    private static func unknown(_ bytes: Data) -> SwiftProtobuf.UnknownStorage {
        var options = Google_Protobuf_FieldOptions()
        // Parsing is the one public way to fill an UnknownStorage.
        options = (try? Google_Protobuf_FieldOptions(serializedBytes: bytes)) ?? options
        return options.unknownFields
    }

    private static func file(_ fields: [Google_Protobuf_FieldDescriptorProto], oneofs: [String] = [],
                             name: String = "c.proto", imports: [String] = [],
                             more: [Google_Protobuf_DescriptorProto] = []) -> Google_Protobuf_FileDescriptorProto {
        var m = Google_Protobuf_DescriptorProto()
        m.name = "M"
        m.field = fields
        m.oneofDecl = oneofs.map { n in
            var o = Google_Protobuf_OneofDescriptorProto()
            o.name = n
            return o
        }
        var f = Google_Protobuf_FileDescriptorProto()
        f.name = name
        f.package = "v"
        f.syntax = "proto3"
        f.dependency = imports
        f.messageType = [m] + more
        return f
    }

    private static func plain(_ name: String, in package: String = "v") -> Google_Protobuf_DescriptorProto {
        var m = Google_Protobuf_DescriptorProto()
        m.name = name
        return m
    }

    private func check(_ files: [Google_Protobuf_FileDescriptorProto], message: String = "v.M") throws {
        try PXF.Annotations(files: files).validateSchema(message: message)
    }

    private func assertRefused(_ file: Google_Protobuf_FileDescriptorProto, _ fragment: String,
                               line: UInt = #line) {
        XCTAssertThrowsError(try check([file]), line: line) { error in
            XCTAssertTrue("\(error)".contains(fragment), "\(error)", line: line)
        }
    }

    // MARK: default placement

    func testDefaultOnARepeatedFieldIsRefused() {
        assertRefused(Self.file([Self.field("t", 1, .string, repeated: true, defaultLiteral: "x")]),
                      "(pxf.default) is not valid on repeated fields")
    }

    func testDefaultOnAMapFieldIsRefused() {
        var entry = Self.plain("TEntry")
        entry.options.mapEntry = true
        entry.field = [Self.field("key", 1, .string), Self.field("value", 2, .string)]
        var file = Self.file([Self.field("t", 1, .message, typeName: "v.M.TEntry", repeated: true, defaultLiteral: "x")])
        file.messageType[0].nestedType = [entry]
        assertRefused(file, "(pxf.default) is not valid on map fields")
    }

    func testDefaultOnAGroupIsRefused() {
        assertRefused(Self.file([Self.field("t", 1, .group, typeName: "v.Sub", defaultLiteral: "x")], more: [Self.plain("Sub")]),
                      "(pxf.default) is not valid on group fields")
    }

    func testDefaultOnAMessageWithNoLiteralIsRefused() {
        assertRefused(Self.file([Self.field("t", 1, .message, typeName: "v.Sub", defaultLiteral: "x")], more: [Self.plain("Sub")]),
                      "no PXF literal denotes it")
    }

    func testDefaultOnAScalarOrALiteralMessageBinds() throws {
        try check([Self.file([Self.field("t", 1, .string, defaultLiteral: "x")])])
        for type in ["google.protobuf.Timestamp", "google.protobuf.Duration", "google.protobuf.Int32Value",
                     "pxf.BigInt", "pxf.Decimal", "pxf.BigFloat"] {
            try check([Self.file([Self.field("t", 1, .message, typeName: type, defaultLiteral: "1")])])
        }
    }

    // MARK: oneof members

    func testRequiredOnAOneofMemberIsRefused() {
        assertRefused(Self.file([Self.field("a", 1, .string, required: true, oneof: 0), Self.field("b", 2, .string, oneof: 0)], oneofs: ["o"]),
                      "(pxf.required) is not valid on a member of oneof \"o\"")
    }

    func testTwoDefaultsInAOneofAreRefused() {
        assertRefused(Self.file([Self.field("a", 1, .string, defaultLiteral: "x", oneof: 0),
                                 Self.field("b", 2, .string, defaultLiteral: "y", oneof: 0)], oneofs: ["o"]),
                      "at most one member of oneof \"o\" may carry a default; 2 do (a, b)")
    }

    func testOneDefaultInAOneofBinds() throws {
        try check([Self.file([Self.field("a", 1, .string, defaultLiteral: "x", oneof: 0), Self.field("b", 2, .string, oneof: 0)], oneofs: ["o"])])
    }

    func testRequiredOnAProto3OptionalBinds() throws {
        // Its synthetic oneof is not a oneof to the rule.
        var f = Self.field("a", 1, .string, required: true, oneof: 0)
        f.proto3Optional = true
        try check([Self.file([f], oneofs: ["_a"])])
    }

    func testAViolationInAnImportedFileIsReported() {
        let imported = Self.file([Self.field("t", 1, .string, repeated: true, defaultLiteral: "x")], name: "lib.proto")
        var lib = imported
        lib.messageType[0].name = "L"
        let root = Self.file([Self.field("n", 1, .string)], imports: ["lib.proto"])
        XCTAssertThrowsError(try check([lib, root]))
        // Outside the closure it is not this message's schema.
        let unrelated = Self.file([Self.field("n", 1, .string)])
        XCTAssertNoThrow(try check([lib, unrelated]))
    }

    func testARefusedSchemaFailsBeforeADocumentIsRead() {
        struct Anything: Decodable { init(from decoder: Decoder) throws {} }
        let bad = PXF.Annotations(files: [Self.file([Self.field("t", 1, .string, repeated: true, defaultLiteral: "x")])])
        let decoder = PXFDecoder(annotations: bad, rootMessage: "v.M")
        XCTAssertThrowsError(try decoder.decode(Anything.self, from: "not { valid")) { error in
            XCTAssertTrue(error is PXF.AnnotationError, "\(error)")
        }
    }

    // MARK: the carrier

    private static func tag(_ number: Int, into out: inout Data) {
        Protowire.appendTag(&out, number: Int32(number), type: .bytes)
    }

    private static func bytesField(_ number: Int, _ payload: Data) -> Data {
        var out = Data()
        tag(number, into: &out)
        Protowire.appendBytes(&out, payload)
        return out
    }

    private static func annotation(_ name: String, _ arg: Data? = nil) -> Data {
        var entry = bytesField(1, Data(name.utf8))
        if let arg { entry += bytesField(2, arg) }
        return bytesField(1327, bytesField(1, entry))
    }

    private static let required = annotation("protowire.schema.v1.required")

    private static func stringDefault(_ s: String) -> Data {
        annotation("protowire.schema.v1.default", bytesField(10, Data(s.utf8)))
    }

    func testTheCarrierSuppliesRequiredAndDefault() throws {
        let a = PXF.Annotations(files: [Self.file([
            Self.field("r", 1, .string, carrier: Self.required),
            Self.field("d", 2, .string, carrier: Self.stringDefault("x")),
        ])])
        let m = try XCTUnwrap(a.message("v.M"))
        XCTAssertEqual(m.field(named: "r")?.required, true)
        XCTAssertEqual(m.field(named: "d")?.defaultLiteral, "x")
    }

    func testTwoSpellingsThatDisagreeAreRefused() {
        assertRefused(Self.file([Self.field("t", 1, .string, carrier: Self.bytesField(1315, Data("x".utf8)) + Self.stringDefault("y"))]),
                      "(pxf.default) = \"x\" and @default = \"y\" carry different values")
    }

    func testTwoSpellingsThatAgreeBind() throws {
        try check([Self.file([Self.field("t", 1, .string, carrier: Self.bytesField(1315, Data("x".utf8)) + Self.stringDefault("x"))])])
    }

    func testRequiredAndDefaultInTheCarrierAreRefused() {
        assertRefused(Self.file([Self.field("t", 1, .string, carrier: Self.required + Self.stringDefault("x"))]),
                      "invalid @required: @required and @default are exclusive")
    }

    func testADefaultWithNoArgumentIsRefused() {
        assertRefused(Self.file([Self.field("t", 1, .string, carrier: Self.annotation("protowire.schema.v1.default"))]),
                      "invalid @default: @default carries no value argument")
    }

    func testCarrierArgumentsReduceToTheBracketLiteral() throws {
        func literal(_ type: FieldType, typeName: String? = nil, _ arg: Data) throws -> String? {
            let a = PXF.Annotations(files: [Self.file([
                Self.field("t", 1, type, typeName: typeName, carrier: Self.annotation("protowire.schema.v1.default", arg)),
            ])])
            return a.message("v.M")?.field(named: "t")?.defaultLiteral
        }
        func varint(_ number: Int32, _ value: UInt64) -> Data {
            var out = Data()
            Protowire.appendTag(&out, number: number, type: .varint)
            Protowire.appendVarint(&out, value)
            return out
        }
        func double(_ value: Double) -> Data {
            var out = Data()
            Protowire.appendTag(&out, number: 12, type: .fixed64)
            Protowire.appendFixed64(&out, value.bitPattern)
            return out
        }
        XCTAssertEqual(try literal(.int32, varint(11, UInt64(bitPattern: -3))), "-3")
        XCTAssertEqual(try literal(.uint64, varint(11, UInt64.max)), "18446744073709551615")
        XCTAssertEqual(try literal(.bool, varint(13, 1)), "true")
        XCTAssertEqual(try literal(.double, double(1.5)), "1.5")
        XCTAssertEqual(try literal(.bytes, Self.bytesField(14, Data([1, 2, 3]))), "AQID")

        let big = Self.bytesField(1, Data([0x01, 0x00])) + varint(2, 1)
        XCTAssertEqual(try literal(.message, typeName: "pxf.BigInt", Self.bytesField(16, big)), "-256")
        let decimal = Self.bytesField(1, Data([0x05])) + varint(2, 3)
        XCTAssertEqual(try literal(.message, typeName: "pxf.Decimal", Self.bytesField(17, decimal)), "0.005")

        let value = Self.bytesField(2, Data("LEVEL_HIGH".utf8))
        XCTAssertEqual(try literal(.enum, typeName: "v.E", Self.bytesField(15, Self.bytesField(1, value))), "LEVEL_HIGH")
    }

    /// The right column is `strconv.FormatFloat(v, 'g', -1, 64)`, measured.
    func testDoublesFormatAsGoDoes() {
        for (value, want) in [(1.5, "1.5"), (1e6, "1e+06"), (123456789, "1.23456789e+08"), (100000, "100000"),
                              (0.0001, "0.0001"), (0.00001, "1e-05"), (1e21, "1e+21")] as [(Double, String)] {
            XCTAssertEqual(PXF.GoFloat.format(value, positional: false), want)
        }
        XCTAssertEqual(PXF.GoFloat.format(1e21, positional: true), "1000000000000000000000")
        XCTAssertEqual(PXF.GoFloat.format(0.00001, positional: true), "0.00001")
    }

    // MARK: unknown bytes

    func testBracketOptionsAreReadWithoutTheExtensionMap() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("testdata/conformance/descriptors/annotations.binpb")
        let bytes = try Data(contentsOf: url)
        let plain = try Google_Protobuf_FileDescriptorSet(serializedBytes: bytes)
        let m = try XCTUnwrap(PXF.Annotations(descriptorSet: plain).message("settings.v1.Settings"))
        XCTAssertEqual(m.field(named: "name")?.required, true)
        XCTAssertEqual(m.field(named: "retries")?.defaultLiteral, "3")
    }

    // MARK: message literals as defaults

    func testMessageDefaultsReadTheirLiterals() throws {
        func field(_ typeName: String, _ literal: String) -> PXF.Annotations.Field {
            PXF.Annotations.Field(name: "t", number: 1, type: .message, typeName: typeName, isRepeated: false, isMap: false,
                                  required: false, defaultLiteral: literal)
        }
        let a = PXF.Annotations(files: [])
        XCTAssertNotNil(try a.defaultValue(for: field("google.protobuf.Timestamp", "2026-01-02T03:04:05Z")) as? PXF.TimestampVal)
        XCTAssertNotNil(try a.defaultValue(for: field("google.protobuf.Duration", "1.5s")) as? PXF.DurationVal)
        XCTAssertNotNil(try a.defaultValue(for: field("google.protobuf.Int32Value", "3")) as? PXF.IntVal)
        XCTAssertNotNil(try a.defaultValue(for: field("google.protobuf.BoolValue", "true")) as? PXF.BoolVal)
        XCTAssertNotNil(try a.defaultValue(for: field("pxf.BigInt", "123456789012345678901234567890")) as? PXF.IntVal)
        XCTAssertNotNil(try a.defaultValue(for: field("pxf.Decimal", "-1.50")) as? PXF.FloatVal)
        XCTAssertNotNil(try a.defaultValue(for: field("pxf.BigFloat", "1.5p64")) as? PXF.FloatVal)
        XCTAssertThrowsError(try a.defaultValue(for: field("google.protobuf.Timestamp", "soon")))
        XCTAssertThrowsError(try a.defaultValue(for: field("google.protobuf.Int32Value", "x")))
        XCTAssertThrowsError(try a.defaultValue(for: field("google.protobuf.BoolValue", "TRUE")), "strict, as the grammar is")
        XCTAssertThrowsError(try a.defaultValue(for: field("pxf.BigInt", "1.5")))
    }

    // MARK: duplicate names (#39)

    func testATopLevelNameDeclaredTwiceIsAnErrorNotATrap() {
        var file = Self.file([Self.field("n", 1, .string)])
        file.messageType.append(file.messageType[0])
        assertRefused(file, "message \"v.M\" is declared twice")
    }

    func testANestedNameDeclaredTwiceIsAnErrorNotATrap() {
        var file = Self.file([Self.field("n", 1, .string)])
        file.messageType[0].nestedType = [Self.plain("N"), Self.plain("N")]
        assertRefused(file, "message \"v.M.N\" is declared twice")
    }

    func testDistinctNamesBind() throws {
        var file = Self.file([Self.field("n", 1, .string)])
        file.messageType[0].nestedType = [Self.plain("N"), Self.plain("O")]
        try check([file])
    }

    /// A `(pxf.default)` on a `pxf.BigFloat` reads as its literal, and binds to
    /// the fields the literal stands for.
    func testABigFloatDefaultBinds() throws {
        func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> Google_Protobuf_FieldDescriptorProto {
            var f = Google_Protobuf_FieldDescriptorProto()
            f.name = name
            f.number = number
            f.type = type
            f.label = .optional
            return f
        }
        var bigFloat = Google_Protobuf_DescriptorProto()
        bigFloat.name = "BigFloat"
        bigFloat.field = [field("mantissa", 1, .bytes), field("exponent", 2, .int32), field("prec", 3, .uint32), field("negative", 4, .bool)]
        var pxf = Google_Protobuf_FileDescriptorProto()
        pxf.name = "pxf/bignum.proto"
        pxf.package = "pxf"
        pxf.syntax = "proto3"
        pxf.messageType = [bigFloat]
        var f = field("rate", 1, .message)
        f.typeName = ".pxf.BigFloat"
        f.options.Pxf_default = "1.5p64"
        var holder = Google_Protobuf_DescriptorProto()
        holder.name = "Holder"
        holder.field = [f]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "h.proto"
        file.package = "h.v1"
        file.syntax = "proto3"
        file.dependency = ["pxf/bignum.proto"]
        file.messageType = [holder]

        struct Anything: Decodable { init(from decoder: Decoder) throws {} }
        let decoder = PXFDecoder(annotations: PXF.Annotations(files: [pxf, file]), rootMessage: "h.v1.Holder")
        _ = try decoder.decode(Anything.self, from: "")
        var want = Pxf_BigFloat()
        want.mantissa = Data([0xC0, 0, 0, 0, 0, 0, 0, 0])
        want.exponent = -63
        want.prec = 64
        let inner: Data = try want.serializedBytes()
        XCTAssertEqual(decoder.lastBound?.serialized(), Data([0x0A, UInt8(inner.count)]) + inner)
    }
}
