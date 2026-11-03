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

    // MARK: declarations (#55), ported from protowire-go's schema_test.go,
    // retired_test.go and wkt_shape_test.go

    private struct Anything: Decodable { init(from decoder: Decoder) throws {} }

    private static func message(_ name: String, _ fields: [Google_Protobuf_FieldDescriptorProto] = [],
                                oneofs: [String] = []) -> Google_Protobuf_DescriptorProto {
        var m = plain(name)
        m.field = fields
        m.oneofDecl = oneofs.map { n in
            var o = Google_Protobuf_OneofDescriptorProto()
            o.name = n
            return o
        }
        return m
    }

    private static func enumType(_ name: String, _ values: [String]) -> Google_Protobuf_EnumDescriptorProto {
        var e = Google_Protobuf_EnumDescriptorProto()
        e.name = name
        e.value = values.enumerated().map { i, n in
            var v = Google_Protobuf_EnumValueDescriptorProto()
            v.name = n
            v.number = Int32(i)
            return v
        }
        return e
    }

    private static func protoFile(_ name: String, package: String, deps: [String] = [],
                                  messages: [Google_Protobuf_DescriptorProto] = [],
                                  enums: [Google_Protobuf_EnumDescriptorProto] = []) -> Google_Protobuf_FileDescriptorProto {
        var f = Google_Protobuf_FileDescriptorProto()
        f.name = name
        f.package = package
        f.syntax = "proto3"
        f.dependency = deps
        f.messageType = messages
        f.enumType = enums
        return f
    }

    private func violations(_ files: [Google_Protobuf_FileDescriptorProto], _ message: String) -> [PXF.AnnotationError] {
        PXF.Annotations(files: files).closureViolations(of: message)
    }

    // MARK: reserved names (draft §3.13)

    func testAReservedEnumValueIsRefused() {
        let file = Self.protoFile("trades.proto", package: "trades.v1",
            messages: [Self.message("Order", [Self.field("side", 1, .enum, typeName: "trades.v1.Side")])],
            enums: [Self.enumType("Side", ["SIDE_UNSPECIFIED", "BUY", "SELL", "null"])])
        XCTAssertEqual(violations([file], "trades.v1.Order"),
                       [.reservedName(file: "trades.proto", kind: "enum value", element: "trades.v1.null", name: "null")])
        XCTAssertEqual(violations([file], "trades.v1.Order").first.map { "\($0)" },
                       "trades.proto: enum value \"trades.v1.null\" uses PXF-reserved name \"null\" (draft §3.13)")
    }

    func testAReservedFieldNameIsRefused() {
        let file = Self.protoFile("flag.proto", package: "flag.v1",
            messages: [Self.message("Flag", [Self.field("enabled", 1, .bool), Self.field("true", 2, .bool)])])
        XCTAssertEqual(violations([file], "flag.v1.Flag"),
                       [.reservedName(file: "flag.proto", kind: "message field", element: "flag.v1.Flag.true", name: "true")])
    }

    func testAReservedOneofNameIsRefused() {
        let file = Self.protoFile("choice.proto", package: "choice.v1",
            messages: [Self.message("Choice", [Self.field("text", 1, .string, oneof: 0), Self.field("number", 2, .int32, oneof: 0)],
                                    oneofs: ["false"])])
        XCTAssertEqual(violations([file], "choice.v1.Choice"),
                       [.reservedName(file: "choice.proto", kind: "oneof", element: "choice.v1.Choice.false", name: "false")])
    }

    func testReservedNamesAreCaseSensitive() throws {
        let file = Self.protoFile("box.proto", package: "box.v1",
            messages: [Self.message("Box", [Self.field("NULL", 1, .string), Self.field("True", 2, .bool)])],
            enums: [Self.enumType("Truth", ["TRUTH_UNSPECIFIED", "NULL", "TRUE", "FALSE"])])
        try check([file], message: "box.v1.Box")
    }

    func testAReservedNameInANestedMessageIsRefused() {
        var outer = Self.message("Outer")
        outer.nestedType = [Self.message("Inner", [Self.field("false", 1, .bool)])]
        let file = Self.protoFile("nested.proto", package: "nest.v1", messages: [outer])
        XCTAssertEqual(violations([file], "nest.v1.Outer").map(\.element), ["nest.v1.Outer.Inner.false"])
    }

    func testACleanFileBinds() throws {
        let file = Self.protoFile("clean.proto", package: "clean.v1",
            messages: [Self.message("M", [Self.field("x", 1, .int32)])], enums: [Self.enumType("E", ["E_UNSPECIFIED", "ALPHA"])])
        try check([file], message: "clean.v1.M")
    }

    func testAProto3OptionalNamedNullIsReportedOnce() {
        // Its synthetic oneof `_null` is not a oneof to the rule.
        var f = Self.field("null", 1, .bool, oneof: 0)
        f.proto3Optional = true
        let file = Self.protoFile("opt.proto", package: "opt.v1", messages: [Self.message("M", [f], oneofs: ["_null"])])
        XCTAssertEqual(violations([file], "opt.v1.M"),
                       [.reservedName(file: "opt.proto", kind: "message field", element: "opt.v1.M.null", name: "null")])
    }

    func testViolationsAreOrderedByElementAndTheFirstIsThrown() {
        let file = Self.protoFile("multi.proto", package: "m.v1",
            messages: [Self.message("Z", [Self.field("true", 1, .bool), Self.field("s", 2, .string, oneof: 0)], oneofs: ["false"])],
            enums: [Self.enumType("E", ["E_UNSPECIFIED", "null"])])
        XCTAssertEqual(violations([file], "m.v1.Z").map(\.element), ["m.v1.Z.false", "m.v1.Z.true", "m.v1.null"])
        XCTAssertThrowsError(try check([file], message: "m.v1.Z")) { error in
            XCTAssertEqual(error as? PXF.AnnotationError,
                           .reservedName(file: "multi.proto", kind: "oneof", element: "m.v1.Z.false", name: "false"))
        }
    }

    func testAReservedNameFailsTheDecode() {
        let file = Self.protoFile("bad.proto", package: "bad.v1", messages: [Self.message("M", [Self.field("true", 1, .bool)])])
        let decoder = PXFDecoder(annotations: PXF.Annotations(files: [file]), rootMessage: "bad.v1.M")
        XCTAssertThrowsError(try decoder.decode(Anything.self, from: "true = true")) { error in
            XCTAssertTrue("\(error)".contains("bad.v1.M.true"), "\(error)")
        }
    }

    // MARK: retired option numbers (STABILITY.md promise 3)

    private struct StaleOptions {
        var file: Data?, msg: Data?, field: Data?, oneof: Data?, enumType: Data?, enumValue: Data?
    }

    private static func varintOpt(_ number: Int32, _ value: UInt64) -> Data {
        var out = Data()
        Protowire.appendTag(&out, number: number, type: .varint)
        Protowire.appendVarint(&out, value)
        return out
    }

    private static func options<T: SwiftProtobuf.Message>(_ bytes: Data) -> T {
        // Nothing declares these numbers, so all of them parse to unknown fields.
        (try? T(serializedBytes: bytes)) ?? T()
    }

    /// protowire-go's `staleFile`: one message with a field in a oneof, one
    /// enum, and the given unknown bytes on each element's options.
    private static func staleFile(_ deps: [String], _ o: StaleOptions) -> Google_Protobuf_FileDescriptorProto {
        var m = message("M", [field("x", 1, .string, oneof: 0)], oneofs: ["o"])
        var e = enumType("E", ["E_ZERO"])
        var file = protoFile("stale.proto", package: "stale.v1", deps: deps)
        if let b = o.file { file.options = options(b) }
        if let b = o.msg { m.options = options(b) }
        if let b = o.field { m.field[0].options = options(b) }
        if let b = o.oneof { m.oneofDecl[0].options = options(b) }
        if let b = o.enumType { e.options = options(b) }
        if let b = o.enumValue { e.value[0].options = options(b) }
        file.messageType = [m]
        file.enumType = [e]
        return file
    }

    private static func retired(_ vs: [PXF.AnnotationError]) -> [PXF.AnnotationError] {
        vs.filter { if case .retiredNumber = $0 { return true } else { return false } }
    }

    func testRetiredNumbersAreDiagnosed() {
        let carrier = Self.bytesField(50400, Data())
        let file = Self.staleFile(["pxf/annotations.proto"], StaleOptions(
            file: Self.varintOpt(50100, 9001) + Self.varintOpt(50101, 0) + Self.bytesField(50404, Data()),
            msg: Self.varintOpt(50200, 7) + carrier,
            field: Self.varintOpt(50000, 1) + Self.bytesField(50001, Data("42".utf8)) + carrier + Self.varintOpt(51000, 1),
            oneof: carrier, enumType: carrier, enumValue: carrier))
        let vs = violations([file], "stale.v1.M")
        var byNumber: [String: PXF.AnnotationError] = [:]
        for v in vs {
            guard case .retiredNumber(_, let element, let number, _) = v else { return XCTFail("\(v)") }
            byNumber["\(element)#\(number)"] = v
        }
        let want = [
            "stale.proto#50100": "(sbe.schema_id) before protowire v1.12.0 and is 1319 now",
            "stale.proto#50101": "(sbe.version) before protowire v1.12.0 and is 1320 now",
            "stale.proto#50404": "source_map carrier before protowire v1.12.0 and is 1331 now",
            "stale.v1.M#50200": "(sbe.template_id) before protowire v1.12.0 and is 1321 now",
            "stale.v1.M#50400": "message_annotations carrier before protowire v1.12.0 and is 1327 now",
            "stale.v1.M.x#50000": "(pxf.required) before protowire v1.12.0 and is 1314 now",
            "stale.v1.M.x#50001": "(pxf.default) before protowire v1.12.0 and is 1315 now",
            "stale.v1.M.x#50400": "field_annotations carrier before protowire v1.12.0 and is 1327 now",
            "stale.v1.M.x#51000": "protocheck field constraint before protowire v1.12.0 and is 1347 now",
            "stale.v1.M.o#50400": "oneof_annotations carrier",
            "stale.v1.E#50400": "*_annotations carrier",
            "stale.v1.E_ZERO#50400": "*_annotations carrier",
        ]
        for (key, detail) in want {
            guard let v = byNumber[key] else {
                XCTFail("expected a violation for \(key); got \(byNumber.keys.sorted())")
                continue
            }
            XCTAssertTrue("\(v)".contains(detail), "\(v)")
            XCTAssertTrue("\(v)".contains("must be recompiled"), "\(v)")
            XCTAssertTrue("\(v)".hasSuffix("(STABILITY.md promise 3)"), "\(v)")
        }
        XCTAssertEqual(vs.count, want.count, "one violation per retired number, no more: \(vs)")

        // The violation is a bind failure: the alternative was a schema that
        // silently stopped enforcing (pxf.required).
        let only = Self.staleFile(["pxf/annotations.proto"], StaleOptions(field: Self.varintOpt(50000, 1)))
        let decoder = PXFDecoder(annotations: PXF.Annotations(files: [only]), rootMessage: "stale.v1.M")
        XCTAssertThrowsError(try decoder.decode(Anything.self, from: "x = \"v\"")) { error in
            XCTAssertTrue("\(error)".contains("50000"), "\(error)")
        }
    }

    /// The gate: the same bytes in a file that imports none of protowire's
    /// annotation files are a third party's options in the range everybody
    /// squats. Likewise numbers that were never allocated, and a clean file.
    func testRetiredNumbersNeedAProtowireImport() {
        let stale = StaleOptions(file: Self.varintOpt(50100, 9001), msg: Self.bytesField(50400, Data()), field: Self.varintOpt(50000, 1))
        let cases: [(String, [String], StaleOptions)] = [
            ("no protowire import", ["google/protobuf/timestamp.proto"], stale),
            ("no import at all", [], stale),
            ("unallocated numbers", ["pxf/annotations.proto"], StaleOptions(file: Self.varintOpt(50999, 1), field: Self.varintOpt(50050, 1))),
            ("registered numbers as unknown bytes", ["pxf/annotations.proto"], StaleOptions(field: Self.varintOpt(1314, 1))),
            ("clean", ["pxf/annotations.proto"], StaleOptions()),
        ]
        for (name, deps, opts) in cases {
            XCTAssertEqual(Self.retired(violations([Self.staleFile(deps, opts)], "stale.v1.M")), [], name)
        }
    }

    func testRetiredNumbersInAnImportAreDiagnosed() {
        let stale = Self.staleFile(["pxf/annotations.proto"], StaleOptions(field: Self.varintOpt(50000, 1)))
        let uses = Self.protoFile("uses.proto", package: "uses.v1", deps: ["stale.proto"],
                                  messages: [Self.message("U", [Self.field("m", 1, .message, typeName: "stale.v1.M")])])
        let vs = violations([stale, uses], "uses.v1.U")
        XCTAssertEqual(vs.count, 1, "\(vs)")
        guard case .retiredNumber(let file, _, let number, _)? = vs.first else { return XCTFail("\(vs)") }
        XCTAssertEqual(file, "stale.proto")
        XCTAssertEqual(number, 50000)
    }

    /// The option bytes are read as protobuf-go's `ConsumeFieldValue` reads
    /// them: a group is skipped whole, and a malformed field ends the scan
    /// with what came before it kept.
    func testOptionBytesAreScannedAsTheReferenceDoes() {
        var group = Data()
        Protowire.appendTag(&group, number: 7, type: .startGroup)
        group += Self.varintOpt(50001, 5)
        Protowire.appendTag(&group, number: 7, type: .endGroup)
        XCTAssertEqual(PXF.Annotations.optionNumbers(group + Self.varintOpt(50000, 1)), [7, 50000])
        // An end group that doesn't close the open one is malformed.
        var crossed = Data()
        Protowire.appendTag(&crossed, number: 7, type: .startGroup)
        Protowire.appendTag(&crossed, number: 8, type: .endGroup)
        XCTAssertEqual(PXF.Annotations.optionNumbers(Self.varintOpt(50000, 1) + crossed + Self.varintOpt(50001, 1)), [50000])
        // Field number 0 is no field.
        XCTAssertEqual(PXF.Annotations.optionNumbers(Data([0x00, 0x01]) + Self.varintOpt(50000, 1)), [])
        // A length past the end is truncated.
        XCTAssertEqual(PXF.Annotations.optionNumbers(Self.varintOpt(50000, 1) + Data([0x8A, 0x9A, 0x0C, 0x05])), [50000])
    }

    // MARK: well-known shapes (draft -01 §wkt-shapes)

    /// One field of a redefinition's body: `type name = number`.
    private typealias BodyField = (name: String, type: FieldType, repeated: Bool, optional: Bool)

    private static func body(_ fields: (String, FieldType)...) -> [BodyField] {
        fields.map { ($0.0, $0.1, false, false) }
    }

    /// protowire-go's `compileRedefinition`: `message <name> { body }` and a
    /// holder using it singly, in a list and as a map value.
    private static func redefinition(_ pkg: String, _ name: String, _ body: [BodyField]) -> Google_Protobuf_FileDescriptorProto {
        var oneofs: [String] = []
        let fields = body.enumerated().map { i, b -> Google_Protobuf_FieldDescriptorProto in
            var f = field(b.name, Int32(i + 1), b.type, repeated: b.repeated, oneof: b.optional ? Int32(oneofs.count) : nil)
            if b.optional {
                f.proto3Optional = true
                oneofs.append("_" + b.name)
            }
            return f
        }
        let full = pkg + "." + name
        var entry = message("MEntry", [field("key", 1, .string), field("value", 2, .message, typeName: full)])
        entry.options.mapEntry = true
        var holder = message("H", [field("pw", 1, .message, typeName: full), field("l", 2, .message, typeName: full, repeated: true),
                                   field("m", 3, .message, typeName: pkg + ".H.MEntry", repeated: true)])
        holder.nestedType = [entry]
        return protoFile("p.proto", package: pkg, messages: [message(name, fields, oneofs: oneofs), holder])
    }

    func testAWellKnownNameWithTheWrongShapeIsRefused() {
        let cases: [(String, String, [BodyField], String, String)] = [
            ("pxf", "Secret", Self.body(("other", .string)), "pw = \"x\"", "no field \"value\""),
            ("pxf", "Secret", Self.body(("value", .int32)), "pw = \"x\"", "field \"value\" is int32"),
            ("pxf", "Secret", [("value", .string, true, false)], "pw = \"x\"", "field \"value\" has the wrong cardinality"),
            ("pxf", "Secret", Self.body(("value", .string), ("hint", .int32)), "pw = \"x\"", "field \"hint\" is int32"),
            ("pxf", "BigInt", Self.body(("other", .string)), "pw = 5", "no field \"abs\""),
            ("pxf", "BigInt", Self.body(("abs", .int32), ("negative", .bool)), "pw = 5", "field \"abs\" is int32"),
            ("pxf", "Decimal", Self.body(("other", .string)), "pw = 1.5", "no field \"unscaled\""),
            ("pxf", "BigFloat", Self.body(("other", .string)), "pw = 1.5", "no field \"mantissa\""),
            ("google.protobuf", "Timestamp", Self.body(("other", .string)), "pw = 2026-01-01T00:00:00Z", "no field \"seconds\""),
            ("google.protobuf", "Duration", Self.body(("other", .string)), "pw = 5s", "no field \"seconds\""),
            ("google.protobuf", "StringValue", Self.body(("other", .string)), "pw = \"x\"", "no field \"value\""),
            ("google.protobuf", "StringValue", Self.body(("value", .int32)), "pw = \"x\"", "field \"value\" is int32"),
            ("google.protobuf", "Int32Value", Self.body(("value", .string)), "pw = 5", "field \"value\" is string"),
            ("google.protobuf", "Any", Self.body(("other", .string)), "pw { @type = \"x\" }", "no field \"type_url\""),
        ]
        for (pkg, name, body, doc, detail) in cases {
            let file = Self.redefinition(pkg, name, body)
            let vs = violations([file], pkg + ".H")
            XCTAssertEqual(vs.count, 1, "\(name) \(body): \(vs)")
            guard case .wellKnownShape(_, let element, _)? = vs.first else {
                XCTFail("\(name) \(body): \(vs)")
                continue
            }
            XCTAssertEqual(element, pkg + "." + name)
            XCTAssertTrue("\(vs[0])".contains(detail), "\(vs[0])")
            XCTAssertTrue("\(vs[0])".contains("§wkt-shapes"), "\(vs[0])")
            let decoder = PXFDecoder(annotations: PXF.Annotations(files: [file]), rootMessage: pkg + ".H")
            XCTAssertThrowsError(try decoder.decode(Anything.self, from: doc)) { error in
                XCTAssertTrue("\(error)".contains("redefines a well-known type"), "\(error)")
            }
        }
    }

    /// Only the shape counts: a copy of a canonical type, a smaller Secret and
    /// extra fields are all still the well-known type.
    func testAWellKnownNameWithItsShapeBinds() throws {
        let cases: [(String, String, [BodyField])] = [
            ("pxf", "Secret", Self.body(("value", .string))),
            ("pxf", "Secret", Self.body(("value", .string), ("hint", .string), ("fingerprint", .string))),
            ("pxf", "Secret", Self.body(("value", .string), ("note", .string))),
            ("pxf", "Secret", [("value", .string, false, true)]),
            ("pxf", "BigInt", Self.body(("abs", .bytes), ("negative", .bool))),
            ("pxf", "Decimal", Self.body(("unscaled", .bytes), ("scale", .int32), ("negative", .bool))),
            ("pxf", "BigFloat", Self.body(("mantissa", .bytes), ("exponent", .int32), ("prec", .uint32), ("negative", .bool))),
            ("google.protobuf", "Timestamp", Self.body(("seconds", .int64), ("nanos", .int32))),
            ("google.protobuf", "Int32Value", Self.body(("value", .int32))),
        ]
        for (pkg, name, body) in cases {
            XCTAssertEqual(violations([Self.redefinition(pkg, name, body)], pkg + ".H"), [], "\(name) \(body)")
        }
    }

    /// A null mask needs the real FieldMask: this one has no paths to read.
    func testAFieldMaskWithoutPathsIsRefused() {
        let file = Self.protoFile("p.proto", package: "google.protobuf", messages: [
            Self.message("FieldMask", [Self.field("other", 1, .string)]),
            Self.message("H", [Self.field("_null", 1, .message, typeName: "google.protobuf.FieldMask"), Self.field("s", 2, .string)]),
        ])
        XCTAssertEqual(violations([file], "google.protobuf.H"),
                       [.wellKnownShape(file: "p.proto", element: "google.protobuf.FieldMask", detail: "it has no field \"paths\"")])
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
