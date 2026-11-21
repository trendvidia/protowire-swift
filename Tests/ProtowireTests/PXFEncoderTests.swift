// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

// The encoder writes a wrapper from its `value` by reflection; the type only
// needs to be Encodable to sit in a Codable struct.
extension Google_Protobuf_Int32Value: @retroactive Encodable {
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// What `PXFEncoder` writes for Swift types. ConformanceTests holds the text to
/// the reference over the corpus; these pin what a Codable type does on top.
final class PXFEncoderTests: XCTestCase {
    struct Item: Codable, Equatable { var name: String; var weight: Int32 }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try PXFEncoder().encode(value)
        XCTAssertEqual(try PXFDecoder().decode(T.self, from: text), value, text, file: file, line: line)
    }

    // MARK: lists (#32)

    func testAListOfScalarsIsOneElementPerLine() throws {
        struct T: Codable { var tags: [String] }
        XCTAssertEqual(try PXFEncoder().encode(T(tags: ["a", "b"])), "tags = [\n  \"a\",\n  \"b\"\n]\n")
    }

    func testAListOfMessagesIsBlocks() throws {
        struct T: Codable { var items: [Item] }
        XCTAssertEqual(try PXFEncoder().encode(T(items: [Item(name: "a", weight: 1)])),
                       "items = [\n  {\n    name = \"a\"\n    weight = 1\n  }\n]\n")
    }

    func testAnEmptyListIsNotWritten() throws {
        struct T: Codable { var tags: [String] }
        XCTAssertEqual(try PXFEncoder().encode(T(tags: [])), "")
    }

    func testListsRoundTrip() throws {
        struct Scalars: Codable, Equatable { var s: [String]; var i: [Int32]; var b: [Bool]; var d: [Double]; var raw: [Data] }
        struct Messages: Codable, Equatable { var items: [Item] }
        struct Nested: Codable, Equatable { var groups: [Messages] }
        try roundTrip(Scalars(s: ["a", "b"], i: [1, -2], b: [true, false], d: [1.5, 1e21], raw: [Data([1, 2])]))
        try roundTrip(Messages(items: [Item(name: "a", weight: 1), Item(name: "b", weight: 2)]))
        try roundTrip(Nested(groups: [Messages(items: [Item(name: "a", weight: 1)])]))
    }

    // MARK: maps

    func testMapKeysAreSortedAndSpelled() throws {
        struct T: Codable { var labels: [String: String] }
        XCTAssertEqual(try PXFEncoder().encode(T(labels: ["b": "2", "a.b": "3", "true": "4", "": "5"])),
                       "labels = {\n  \"\": \"5\"\n  \"true\": \"4\"\n  a.b: \"3\"\n  b: \"2\"\n}\n")
    }

    func testMapsOfEveryKeyRoundTrip() throws {
        struct T: Codable, Equatable {
            var byInt: [Int32: String]
            var byBool: [Bool: String]
            var byItem: [String: Item]
        }
        try roundTrip(T(byInt: [1: "x", -2: "y"], byBool: [true: "t", false: "f"], byItem: ["k": Item(name: "n", weight: 3)]))
    }

    // MARK: _null (#42)

    func testANestedNullIsWrittenInsideItsBlock() throws {
        struct One: Codable, Equatable { var a: String?; var b: String? }
        struct T: Codable { var one: One; var _null: [String] }
        let text = try PXFEncoder().encode(T(one: One(a: nil, b: "x"), _null: ["one.a"]))
        // A nil Optional now holds its place as a left-out zero (#58), so the
        // null lands where the field is declared, as pxf.Marshal writes it.
        XCTAssertEqual(text, "one {\n  a = null\n  b = \"x\"\n}\n")
    }

    func testANullPathMakesTheBlocksItNeeds() throws {
        struct T: Codable { var _null: [String] }
        XCTAssertEqual(try PXFEncoder().encode(T(_null: ["one.two.a", "top"])), "one {\n  two {\n    a = null\n  }\n}\ntop = null\n")
    }

    func testANestedNullReadsBackAsTheSameMask() throws {
        struct One: Codable, Equatable { var a: String?; var b: String? }
        struct T: Codable { var one: One?; var _null: [String]? }
        let text = try PXFEncoder().encode(T(one: One(a: nil, b: "x"), _null: ["one.a"]))
        let (decoded, _) = try PXFDecoder().unmarshalFull(T.self, from: text)
        XCTAssertEqual(decoded._null, ["one.a"])
    }

    // MARK: zero values (#58)

    // The expected strings are pxf.Marshal's output, from a throwaway test in
    // protowire-go at c13c69b6e1a5 over this schema:
    //
    //   enum Color { COLOR_UNSPECIFIED = 0; RED = 1; }
    //   message Inner { int32 n = 1; }
    //   message M {
    //     int32 i32 = 1; int64 i64 = 2; uint32 u32 = 3; uint64 u64 = 4;
    //     float f = 5; double d = 6; bool b = 7; string s = 8; bytes by = 9;
    //     Color c = 10; repeated int32 list = 11; map<string, int32> m = 12;
    //     Inner inner = 13; optional int32 opt = 14; google.protobuf.Int32Value w = 15;
    //   }

    enum Color: String, Codable { case unspecified = "COLOR_UNSPECIFIED", red = "RED" }
    struct Inner: Codable { var n: Int32 = 0 }
    struct Zeros: Encodable {
        var i32: Int32 = 0
        var i64: Int64 = 0
        var u32: UInt32 = 0
        var u64: UInt64 = 0
        var f: Float = 0
        var d: Double = 0
        var b = false
        var s = ""
        var by = Data()
        var c = Color.unspecified
        var list: [Int32] = []
        var m: [String: Int32] = [:]
        var inner: Inner?
        var opt: Int32?
        var w: Google_Protobuf_Int32Value?
    }

    /// The schema above, as far as the renderer reads it: it needs `c` to be
    /// an enum to write its name bare and to know which name is zero.
    private static let zerosSchema: PXF.Annotations = {
        func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                   typeName: String? = nil, repeated: Bool = false) -> Google_Protobuf_FieldDescriptorProto {
            var f = Google_Protobuf_FieldDescriptorProto()
            f.name = name
            f.number = number
            f.type = type
            f.label = repeated ? .repeated : .optional
            if let typeName { f.typeName = "." + typeName }
            return f
        }
        var inner = Google_Protobuf_DescriptorProto()
        inner.name = "Inner"
        inner.field = [field("n", 1, .int32)]
        var m = Google_Protobuf_DescriptorProto()
        m.name = "M"
        m.field = [
            field("i32", 1, .int32), field("i64", 2, .int64), field("u32", 3, .uint32), field("u64", 4, .uint64),
            field("f", 5, .float), field("d", 6, .double), field("b", 7, .bool), field("s", 8, .string),
            field("by", 9, .bytes), field("c", 10, .enum, typeName: "z.v1.Color"),
            field("list", 11, .int32, repeated: true), field("inner", 13, .message, typeName: "z.v1.Inner"),
            field("opt", 14, .int32),
        ]
        var color = Google_Protobuf_EnumDescriptorProto()
        color.name = "Color"
        color.value = [("COLOR_UNSPECIFIED", Int32(0)), ("RED", Int32(1))].map { name, number in
            var v = Google_Protobuf_EnumValueDescriptorProto()
            v.name = name
            v.number = number
            return v
        }
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "z.proto"
        file.package = "z.v1"
        file.messageType = [m, inner]
        file.enumType = [color]
        return PXF.Annotations(files: [file])
    }()

    private func zerosEncoder(emitDefaults: Bool = false) -> PXFEncoder {
        let e = PXFEncoder(annotations: Self.zerosSchema, rootMessage: "z.v1.M")
        e.emitDefaults = emitDefaults
        return e
    }

    /// Every field at its zero, with `inner` an empty message, `opt` an
    /// Optional holding 0 and `w` an Int32Value holding 0.
    private static var setZeros: Zeros {
        Zeros(inner: Inner(), opt: 0, w: Google_Protobuf_Int32Value())
    }

    func testAZeroInANonOptionalFieldIsLeftOut() throws {
        // A set message is written however empty, a set Optional at zero is
        // written, and a set wrapper holding zero is a set message.
        XCTAssertEqual(try zerosEncoder().encode(Self.setZeros), "inner {\n}\nopt = 0\nw = 0\n")
        XCTAssertEqual(try zerosEncoder().encode(Zeros()), "")
    }

    func testEveryNonZeroFieldIsWritten() throws {
        var v = Zeros()
        v.i32 = -1; v.i64 = 2; v.u32 = 3; v.u64 = 4; v.f = 1.5; v.d = 2.5; v.b = true; v.s = "x"
        v.by = Data([1]); v.c = .red; v.list = [0, 7]; v.m = ["a": 0]; v.inner = Inner(n: 5); v.opt = 9
        var w = Google_Protobuf_Int32Value()
        w.value = 6
        v.w = w
        // List elements and map values keep their zeros.
        XCTAssertEqual(try zerosEncoder().encode(v),
                       "i32 = -1\ni64 = 2\nu32 = 3\nu64 = 4\nf = 1.5\nd = 2.5\nb = true\ns = \"x\"\nby = b\"AQ==\"\n"
                       + "c = RED\nlist = [\n  0,\n  7\n]\nm = {\n  a: 0\n}\ninner {\n  n = 5\n}\nopt = 9\nw = 6\n")
    }

    func testANegativeZeroIsWritten() throws {
        var v = Zeros()
        v.f = -0.0
        v.d = -0.0
        XCTAssertEqual(try zerosEncoder().encode(v), "f = -0\nd = -0\n")
    }

    func testEmitDefaultsWritesTheZeros() throws {
        XCTAssertEqual(try zerosEncoder(emitDefaults: true).encode(Self.setZeros),
                       "i32 = 0\ni64 = 0\nu32 = 0\nu64 = 0\nf = 0\nd = 0\nb = false\ns = \"\"\nby = b\"\"\n"
                       + "c = COLOR_UNSPECIFIED\nlist = [\n]\nm = {\n}\ninner {\n  n = 0\n}\nopt = 0\nw = 0\n")
        // A nil Optional scalar is written as its zero, and a nil message is not.
        XCTAssertEqual(try zerosEncoder(emitDefaults: true).encode(Zeros()),
                       "i32 = 0\ni64 = 0\nu32 = 0\nu64 = 0\nf = 0\nd = 0\nb = false\ns = \"\"\nby = b\"\"\n"
                       + "c = COLOR_UNSPECIFIED\nlist = [\n]\nm = {\n}\nopt = 0\n")
    }

    func testAZeroEnumWithoutASchemaIsLeftOutByItsNumber() throws {
        enum Level: Int32, Codable { case low = 0, high = 1 }
        struct T: Codable, Equatable { var level: Level; var other: Int32 }
        XCTAssertEqual(try PXFEncoder().encode(T(level: .low, other: 1)), "other = 1\n")
        XCTAssertEqual(try PXFEncoder().encode(T(level: .high, other: 0)), "level = 1\n")
        try roundTrip(T(level: .low, other: 0))
    }

    func testAZeroNamedInNullIsWrittenAsNull() throws {
        struct T: Codable { var a: Int32?; var b: Int32; var _null: [String] }
        XCTAssertEqual(try PXFEncoder().encode(T(a: nil, b: 0, _null: ["a"])), "a = null\n")
    }

    func testZerosRoundTrip() throws {
        struct T: Codable, Equatable { var i: Int32; var s: String; var b: Bool; var d: Double; var raw: Data; var opt: Int32? }
        try roundTrip(T(i: 0, s: "", b: false, d: 0, raw: Data(), opt: 0))
        try roundTrip(T(i: 0, s: "", b: false, d: 0, raw: Data(), opt: nil))
    }

    // MARK: literals

    func testFloatsAreWrittenAsTheReferenceWrites() {
        let cases: [(Double, String)] = [
            (0, "0"), (1, "1"), (1.5, "1.5"), (-2.5, "-2.5"), (100000, "100000"), (1e6, "1e+06"),
            (1234567, "1.234567e+06"), (0.0001, "0.0001"), (0.00001, "1e-05"), (1e21, "1e+21"),
            (1e100, "1e+100"), (.infinity, "inf"), (-.infinity, "-inf"), (.nan, "nan"), (-0.0, "-0"),
        ]
        for (value, want) in cases { XCTAssertEqual(PXF.WellKnown.float(value), want) }
        XCTAssertEqual(PXF.WellKnown.float(Float(0.1)), "0.1")
    }

    func testDurationsAreWrittenAsTimeDurationString() {
        let cases: [(Int64, Int32, String)] = [
            (0, 0, "0s"), (1, 500_000_000, "1.5s"), (5400, 0, "1h30m0s"), (0, 1_500_000, "1.5ms"),
            (0, 312_500, "312.5µs"), (0, 7, "7ns"), (-2, -500_000_000, "-2.5s"), (60, 0, "1m0s"),
        ]
        for (seconds, nanos, want) in cases {
            XCTAssertEqual(PXF.WellKnown.durationLiteral(seconds: seconds, nanos: nanos), want)
        }
        XCTAssertNil(PXF.WellKnown.durationLiteral(seconds: 9_500_000_000, nanos: 0), "past int64 nanoseconds")
    }

    func testTimestampsHaveNoTrailingZeros() {
        XCTAssertEqual(PXF.WellKnown.timestampLiteral(seconds: 0, nanos: 0), "1970-01-01T00:00:00Z")
        XCTAssertEqual(PXF.WellKnown.timestampLiteral(seconds: 1, nanos: 500_000_000), "1970-01-01T00:00:01.5Z")
        XCTAssertEqual(PXF.WellKnown.timestampLiteral(seconds: -1, nanos: 0), "1969-12-31T23:59:59Z")
    }

    // MARK: absent fields, read back (#58)

    func testAnAbsentNonOptionalFieldReadsAsZero() throws {
        enum Level: Int32, Codable { case low = 0, high = 1 }
        struct T: Codable {
            var i: Int32; var u: UInt64; var f: Float; var s: String; var b: Bool; var raw: Data
            var level: Level; var tags: [String]; var labels: [String: Int32]; var opt: Int32?
        }
        let v = try PXFDecoder().decode(T.self, from: "")
        XCTAssertEqual(v.i, 0); XCTAssertEqual(v.u, 0); XCTAssertEqual(v.f, 0); XCTAssertEqual(v.s, "")
        XCTAssertEqual(v.b, false); XCTAssertEqual(v.raw, Data()); XCTAssertEqual(v.level, .low)
        XCTAssertEqual(v.tags, []); XCTAssertEqual(v.labels, [:]); XCTAssertNil(v.opt)
    }

    func testAnAbsentNonOptionalMessageIsStillAnError() {
        // The encoder always writes a non-optional message, so its absence
        // is not a zero; nor is a String-backed enum's, whose zero name only
        // a schema knows.
        struct WithMessage: Codable { var item: Item }
        XCTAssertThrowsError(try PXFDecoder().decode(WithMessage.self, from: ""))
        enum Named: String, Codable { case none = "NONE" }
        struct WithNamedEnum: Codable { var c: Named }
        XCTAssertThrowsError(try PXFDecoder().decode(WithNamedEnum.self, from: ""))
    }
}
