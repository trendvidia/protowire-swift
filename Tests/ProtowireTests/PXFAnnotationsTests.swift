// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

/// `(pxf.required)` / `(pxf.default)` on the Codable decode path
/// (protowire-swift#11), against a descriptor built here in the shape of
/// protowire's testdata/annotations/settings.proto plus a nested message.
/// Semantics mirror protowire-go's postDecode: null counts as present,
/// singular present message fields are descended into, list elements are
/// not, and a defaulted field stays absent in the Result.
final class PXFAnnotationsTests: XCTestCase {

    // MARK: descriptor

    private static func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                              typeName: String? = nil, repeated: Bool = false,
                              required: Bool = false, defaultLiteral: String? = nil) -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = repeated ? .repeated : .optional
        if let t = typeName { f.typeName = "." + t }
        if required { f.options.Pxf_required = true }
        if let d = defaultLiteral { f.options.Pxf_default = d }
        return f
    }

    /// settings.v1.Settings as in the spec fixture, plus:
    ///   Limits limits = 5;            message Limits { int32 max = 1 [(pxf.required)=true]; int32 min = 2 [(pxf.default)="1"]; }
    ///   repeated Limits history = 6;
    ///   Level level = 7 [(pxf.default)="LEVEL_HIGH"];  enum Level { LEVEL_LOW = 0; LEVEL_HIGH = 1; }
    ///   bytes token = 8 [(pxf.default)="AQID"];
    ///   double ratio = 9 [(pxf.default)="0.5"];
    ///   int32 bad = 10 [(pxf.default)="many"];
    private static let annotations: PXF.Annotations = {
        var limits = Google_Protobuf_DescriptorProto()
        limits.name = "Limits"
        limits.field = [
            field("max", 1, .int32, required: true),
            field("min", 2, .int32, defaultLiteral: "1"),
        ]
        var settings = Google_Protobuf_DescriptorProto()
        settings.name = "Settings"
        settings.field = [
            field("name", 1, .string, required: true),
            field("retries", 2, .int32, defaultLiteral: "3"),
            field("region", 3, .string, defaultLiteral: "us-east-1"),
            field("verbose", 4, .bool, defaultLiteral: "true"),
            field("limits", 5, .message, typeName: "settings.v1.Limits"),
            field("history", 6, .message, typeName: "settings.v1.Limits", repeated: true),
            field("level", 7, .enum, typeName: "settings.v1.Level", defaultLiteral: "LEVEL_HIGH"),
            field("token", 8, .bytes, defaultLiteral: "AQID"),
            field("ratio", 9, .double, defaultLiteral: "0.5"),
            field("bad", 10, .int32, defaultLiteral: "many"),
        ]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "settings.proto"
        file.package = "settings.v1"
        file.messageType = [settings, limits]
        return PXF.Annotations(files: [file])
    }()

    // MARK: mirrors

    struct Limits: Codable, Equatable {
        var max: Int32?
        var min: Int32?
    }
    enum Level: String, Codable { case low = "LEVEL_LOW", high = "LEVEL_HIGH" }
    struct Settings: Codable {
        var name: String?
        var retries: Int32?
        var region: String?
        var verbose: Bool?
        var limits: Limits?
        var history: [Limits]?
        var level: Level?
        var token: Data?
        var ratio: Double?
    }
    struct BadDefault: Codable { var bad: Int32? }

    private func decoder() -> PXFDecoder {
        PXFDecoder(annotations: Self.annotations, rootMessage: "settings.v1.Settings")
    }

    // MARK: index

    func testIndexReadsTheOptions() {
        let m = Self.annotations.message("settings.v1.Settings")!
        XCTAssertEqual(m.field(named: "name")?.required, true)
        XCTAssertEqual(m.field(named: "name")?.defaultLiteral, nil)
        XCTAssertEqual(m.field(named: "retries")?.required, false)
        XCTAssertEqual(m.field(named: "retries")?.defaultLiteral, "3")
        XCTAssertEqual(m.field(named: "limits")?.typeName, "settings.v1.Limits")
        XCTAssertEqual(m.field(named: "history")?.isRepeated, true)
        XCTAssertNotNil(Self.annotations.message("settings.v1.Limits"))
        XCTAssertNil(Self.annotations.message("settings.v1.Missing"))
    }

    // MARK: required

    func testRequiredAbsentIsRejectedWithGosMessage() {
        XCTAssertThrowsError(try decoder().decode(Settings.self, from: "retries = 5")) { error in
            XCTAssertEqual(error as? PXF.AnnotationError, .requiredFieldAbsent(path: "name"))
            XCTAssertEqual("\(error)", "required field \"name\" is absent")
        }
    }

    func testRequiredCoversFieldsTheSwiftTypeDoesNotDeclare() {
        // Only `retries` is declared; `name` is still checked from the schema.
        struct Partial: Codable { var retries: Int32? }
        XCTAssertThrowsError(try decoder().decode(Partial.self, from: "retries = 5"))
        XCTAssertNoThrow(try decoder().decode(Partial.self, from: "name = \"svc\""))
    }

    func testRequiredSetToNullCountsAsPresent() throws {
        let (s, r) = try decoder().unmarshalFull(Settings.self, from: "name = null")
        XCTAssertNil(s.name)
        XCTAssertTrue(r.isNull("name"))
    }

    func testRequiredIsCheckedInsidePresentSingularMessages() {
        XCTAssertThrowsError(try decoder().decode(Settings.self, from: "name = \"svc\"\nlimits { min = 2 }")) { error in
            XCTAssertEqual(error as? PXF.AnnotationError, .requiredFieldAbsent(path: "limits.max"))
        }
        XCTAssertNoThrow(try decoder().decode(Settings.self, from: "name = \"svc\"\nlimits { max = 2 }"))
        XCTAssertNoThrow(try decoder().decode(Settings.self, from: "name = \"svc\"\nlimits = { max = 2 }"))
        // An absent or null nested message is not descended into.
        XCTAssertNoThrow(try decoder().decode(Settings.self, from: "name = \"svc\""))
        XCTAssertNoThrow(try decoder().decode(Settings.self, from: "name = \"svc\"\nlimits = null"))
    }

    func testListElementsAreNotValidated() throws {
        // Go's postDecode does not descend into repeated message fields;
        // mirrored here so the ports agree on what a document means.
        let s = try decoder().decode(Settings.self, from: "name = \"svc\"\nhistory = [ { min = 2 } ]")
        XCTAssertEqual(s.history, [Limits(max: nil, min: 2)])
    }

    // MARK: defaults

    func testDefaultsFillAbsentFieldsOfEveryScalarKind() throws {
        let (s, r) = try decoder().unmarshalFull(Settings.self, from: "name = \"svc\"")
        XCTAssertEqual(s.name, "svc")
        XCTAssertEqual(s.retries, 3)
        XCTAssertEqual(s.region, "us-east-1")
        XCTAssertEqual(s.verbose, true)
        XCTAssertEqual(s.level, .high)
        XCTAssertEqual(s.token, Data([1, 2, 3]))
        XCTAssertEqual(s.ratio, 0.5)
        // Defaulted fields were not in the input: the Result says absent.
        XCTAssertTrue(r.isSet("name"))
        XCTAssertTrue(r.isAbsent("retries"))
        XCTAssertTrue(r.isAbsent("region"))
        XCTAssertTrue(r.isAbsent("verbose"))
        XCTAssertEqual(r.allSetFields, ["name"])
    }

    func testPresentValuesAreNotOverridden() throws {
        let s = try decoder().decode(Settings.self, from: "name = \"svc\"\nretries = 7\nverbose = false\nregion = \"eu\"")
        XCTAssertEqual(s.retries, 7)
        XCTAssertEqual(s.verbose, false)
        XCTAssertEqual(s.region, "eu")
    }

    func testNullIsNotDefaulted() throws {
        let (s, r) = try decoder().unmarshalFull(Settings.self, from: "name = \"svc\"\nretries = null")
        XCTAssertNil(s.retries)
        XCTAssertTrue(r.isNull("retries"))
    }

    func testDefaultsApplyInsidePresentSingularMessages() throws {
        let s = try decoder().decode(Settings.self, from: "name = \"svc\"\nlimits { max = 9 }")
        XCTAssertEqual(s.limits, Limits(max: 9, min: 1))
    }

    func testDefaultsDoNotApplyInsideListElements() throws {
        let s = try decoder().decode(Settings.self, from: "name = \"svc\"\nhistory = [ { max = 9 } ]")
        XCTAssertEqual(s.history, [Limits(max: 9, min: nil)])
    }

    func testDefaultsApplyToNonOptionalProperties() throws {
        struct Strict: Codable { var name: String; var retries: Int32; var verbose: Bool }
        let s = try decoder().decode(Strict.self, from: "name = \"svc\"")
        XCTAssertEqual(s.retries, 3)
        XCTAssertEqual(s.verbose, true)
    }

    func testBadDefaultLiteralIsItsOwnError() {
        XCTAssertThrowsError(try decoder().decode(BadDefault.self, from: "name = \"svc\"")) { error in
            XCTAssertEqual(error as? PXF.AnnotationError,
                           .invalidDefault(field: "bad", literal: "many", reason: "not an int32"))
        }
    }

    func testDefaultValueParsing() throws {
        func f(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum, _ literal: String) -> PXF.Annotations.Field {
            PXF.Annotations.Field(name: "x", number: 1, type: type, typeName: nil, isRepeated: false, isMap: false,
                                  required: false, defaultLiteral: literal)
        }
        let a = Self.annotations
        XCTAssertEqual((try a.defaultValue(for: f(.string, "\"quoted\"")) as? PXF.StringVal)?.value, "\"quoted\"", "strings are verbatim")
        XCTAssertEqual((try a.defaultValue(for: f(.bool, "false")) as? PXF.BoolVal)?.value, false)
        XCTAssertThrowsError(try a.defaultValue(for: f(.bool, "yes")))
        XCTAssertEqual((try a.defaultValue(for: f(.uint64, "18446744073709551615")) as? PXF.IntVal)?.raw, "18446744073709551615")
        XCTAssertThrowsError(try a.defaultValue(for: f(.int32, "2147483648")), "out of int32 range")
        XCTAssertThrowsError(try a.defaultValue(for: f(.bytes, "not base64!")))
        XCTAssertNotNil(try a.defaultValue(for: f(.message, "{ max = 1 }")) as? PXF.BlockVal)
        XCTAssertThrowsError(try a.defaultValue(for: f(.message, "42")))
        XCTAssertNil(try a.defaultValue(for: PXF.Annotations.Field(name: "x", number: 1, type: .int32, typeName: nil, isRepeated: false, isMap: false, required: false, defaultLiteral: nil)))
    }

    // MARK: off switch

    func testWithoutAnnotationsNothingChanges() throws {
        let plain = PXFDecoder()
        let s = try plain.decode(Settings.self, from: "retries = 5")
        XCTAssertNil(s.name)
        XCTAssertEqual(s.retries, 5)
        XCTAssertNil(s.region)
    }

    func testUnknownRootMessageIsInert() throws {
        let d = PXFDecoder(annotations: Self.annotations, rootMessage: "settings.v1.Missing")
        XCTAssertNoThrow(try d.decode(Settings.self, from: "retries = 5"))
    }
}
