// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

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
        XCTAssertEqual(text, "one {\n  b = \"x\"\n  a = null\n}\n")
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
}
