// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

/// `google.protobuf.Timestamp` and `Duration` through the Codable bridge,
/// which `ConformanceTests` does not reach: it compares the schema-bound pass.
/// Each expected text below is what Go printed for the same value
/// (`time.Duration.String()`, `time.Unix(s, n).UTC().Format(time.RFC3339Nano)`).
final class PXFTimeTests: XCTestCase {
    struct AllTypes: Codable {
        var ts_field: Google_Protobuf_Timestamp?
        var dur_field: Google_Protobuf_Duration?
    }

    private static func duration(_ seconds: Int64, _ nanos: Int32) -> Google_Protobuf_Duration {
        var d = Google_Protobuf_Duration()
        d.seconds = seconds
        d.nanos = nanos
        return d
    }

    private static func timestamp(_ seconds: Int64, _ nanos: Int32) -> Google_Protobuf_Timestamp {
        var t = Google_Protobuf_Timestamp()
        t.seconds = seconds
        t.nanos = nanos
        return t
    }

    // MARK: Duration

    /// protowire-go's TestMarshalDurationReadsBack: whatever the encoder
    /// writes for a Duration, the decoder reads to the same (seconds, nanos).
    /// The values hit every branch of `time.Duration.String()`.
    func testMarshalDurationReadsBack() throws {
        let cases: [(Int64, String)] = [
            (0, "0s"), (1, "1ns"), (999, "999ns"), (1000, "1µs"), (1234, "1.234µs"), (1500, "1.5µs"),
            (312_500, "312.5µs"), (1_234_567, "1.234567ms"), (1_500_000, "1.5ms"), (250_000_000, "250ms"),
            (1_000_000_000, "1s"), (1_500_000_000, "1.5s"), (5_400_000_000_000, "1h30m0s"),
            (5_400_500_000_000, "1h30m0.5s"), (5_445_123_456_789, "1h30m45.123456789s"),
            (360_000_000_000_000, "100h0m0s"),
            (-1, "-1ns"), (-1500, "-1.5µs"), (-312_500, "-312.5µs"), (-1_500_000_000, "-1.5s"),
            (-5_400_500_000_000, "-1h30m0.5s"),
            (Int64.max, "2562047h47m16.854775807s"), (Int64.min, "-2562047h47m16.854775808s"),
        ]
        for (total, want) in cases {
            let seconds = total / 1_000_000_000
            let nanos = Int32(total % 1_000_000_000)
            let text = try PXFEncoder().encode(AllTypes(dur_field: Self.duration(seconds, nanos)))
            XCTAssertTrue(text.contains("dur_field = \(want)\n"), "\(want): \(text)")
            let back = try PXFDecoder().decode(AllTypes.self, from: text)
            XCTAssertEqual(back.dur_field?.seconds, seconds, want)
            XCTAssertEqual(back.dur_field?.nanos, nanos, want)
        }
    }

    /// The literal forms protowire-go's TestFullRoundTripFractionalDuration
    /// reads, each to its exact value, then written in canonical form.
    func testDurationLiteralsReadExactly() throws {
        let cases: [(String, Int64, Int32, String)] = [
            ("1.234567ms", 0, 1_234_567, "1.234567ms"), ("1.5h", 5400, 0, "1h30m0s"), ("2µs", 0, 2000, "2µs"),
            ("1.5ms", 0, 1_500_000, "1.5ms"), ("312.5µs", 0, 312_500, "312.5µs"), ("1h30m500ms", 5400, 500_000_000, "1h30m0.5s"),
            ("1ms234us567ns", 0, 1_234_567, "1.234567ms"), ("-1.5s", -1, -500_000_000, "-1.5s"),
            ("1ns", 0, 1, "1ns"), ("999.999999ms", 0, 999_999_999, "999.999999ms"), ("1h2m", 3720, 0, "1h2m0s"),
            ("9223372036854775807ns", 9_223_372_036, 854_775_807, "2562047h47m16.854775807s"),
            ("-9223372036854775808ns", -9_223_372_036, -854_775_808, "-2562047h47m16.854775808s"),
        ]
        for (literal, seconds, nanos, canonical) in cases {
            let v = try PXFDecoder().decode(AllTypes.self, from: "dur_field = \(literal)")
            XCTAssertEqual(v.dur_field?.seconds, seconds, literal)
            XCTAssertEqual(v.dur_field?.nanos, nanos, literal)
            XCTAssertEqual(try PXFEncoder().encode(v), "dur_field = \(canonical)\n", literal)
        }
    }

    /// Past int64 nanoseconds a literal can't hold the value, so the encoder
    /// writes the message form, as protowire-go does, and it reads back.
    func testALongDurationIsWrittenAsABlock() throws {
        let long = AllTypes(dur_field: Self.duration(315_576_000_000, 5))
        let text = try PXFEncoder().encode(long)
        XCTAssertEqual(text, "dur_field {\n  seconds = 315576000000\n  nanos = 5\n}\n")
        let back = try PXFDecoder().decode(AllTypes.self, from: text)
        XCTAssertEqual(back.dur_field?.seconds, 315_576_000_000)
        XCTAssertEqual(back.dur_field?.nanos, 5)
    }

    /// What `time.ParseDuration` refuses, and what is not a duration at all.
    func testDurationRejects() {
        for input in ["dur_field = 2562048h", "dur_field = 9223372036854775808ns",
                      "dur_field = -9223372036854775809ns", "dur_field = 5", "dur_field = \"1s\""] {
            XCTAssertThrowsError(try PXFDecoder().decode(AllTypes.self, from: input), input)
        }
    }

    // MARK: Timestamp

    /// Nanosecond precision both ways, and an offset read into UTC.
    func testTimestampRoundTripsEveryNanosecond() throws {
        let cases: [(String, Int64, Int32, String)] = [
            ("2024-01-15T10:30:00.123456789Z", 1_705_314_600, 123_456_789, "2024-01-15T10:30:00.123456789Z"),
            ("2024-01-15T10:30:00.0000001Z", 1_705_314_600, 100, "2024-01-15T10:30:00.0000001Z"),
            ("2024-01-15T10:30:00.000000001Z", 1_705_314_600, 1, "2024-01-15T10:30:00.000000001Z"),
            ("2024-01-15T10:30:00.123456789+05:30", 1_705_294_800, 123_456_789, "2024-01-15T05:00:00.123456789Z"),
            ("2024-02-29T00:00:00Z", 1_709_164_800, 0, "2024-02-29T00:00:00Z"),
            ("0001-01-01T00:00:00Z", -62_135_596_800, 0, "0001-01-01T00:00:00Z"),
            ("9999-12-31T23:59:59.999999999Z", 253_402_300_799, 999_999_999, "9999-12-31T23:59:59.999999999Z"),
        ]
        for (literal, seconds, nanos, canonical) in cases {
            let v = try PXFDecoder().decode(AllTypes.self, from: "ts_field = \(literal)")
            XCTAssertEqual(v.ts_field?.seconds, seconds, literal)
            XCTAssertEqual(v.ts_field?.nanos, nanos, literal)
            let text = try PXFEncoder().encode(v)
            XCTAssertEqual(text, "ts_field = \(canonical)\n", literal)
            let back = try PXFDecoder().decode(AllTypes.self, from: text)
            XCTAssertEqual(back.ts_field?.seconds, seconds, literal)
            XCTAssertEqual(back.ts_field?.nanos, nanos, literal)
        }
    }

    /// What `time.Parse(time.RFC3339Nano, …)` refuses, and what is not a
    /// timestamp at all.
    func testTimestampRejects() {
        for input in ["ts_field = 2024-02-30T00:00:00Z", "ts_field = 2023-02-29T00:00:00Z",
                      "ts_field = 2024-13-01T00:00:00Z", "ts_field = 2024-01-01T24:00:00Z",
                      "ts_field = 2024-01-01T00:00:60Z", "ts_field = 5",
                      "ts_field = \"2024-01-15T10:30:00Z\""] {
            XCTAssertThrowsError(try PXFDecoder().decode(AllTypes.self, from: input), input)
        }
    }

    /// The message form reads too, in a PXF block.
    func testBlockFormReads() throws {
        let v = try PXFDecoder().decode(AllTypes.self, from: "ts_field { seconds = 1 nanos = 2 }\ndur_field { seconds = -3 nanos = -4 }")
        XCTAssertEqual(v.ts_field, Self.timestamp(1, 2))
        XCTAssertEqual(v.dur_field, Self.duration(-3, -4))
    }

    /// A list element and a map value take the literal too.
    func testListsAndMaps() throws {
        struct C: Codable {
            var at: [Google_Protobuf_Timestamp]
            var timeouts: [String: Google_Protobuf_Duration]
        }
        let text = "at = [\n  2024-01-15T10:30:00.123456789Z,\n  1970-01-01T00:00:00Z\n]\ntimeouts = {\n  read: 1.5ms\n  write: 2s\n}\n"
        let c = try PXFDecoder().decode(C.self, from: text)
        XCTAssertEqual(c.at, [Self.timestamp(1_705_314_600, 123_456_789), Self.timestamp(0, 0)])
        XCTAssertEqual(c.timeouts, ["read": Self.duration(0, 1_500_000), "write": Self.duration(2, 0)])
        XCTAssertEqual(try PXFEncoder().encode(c), text)
    }

    // MARK: PB

    /// Through `PBEncoder`, a field holding either type is the message the
    /// stock runtime writes, and it reads back.
    func testPBMatchesTheStockRuntime() throws {
        struct W: Codable, Equatable {
            var ts: Google_Protobuf_Timestamp?
            var d: Google_Protobuf_Duration?
            enum CodingKeys: Int, CodingKey { case ts = 1, d = 2 }
        }
        for (ts, d) in [(Self.timestamp(1_705_314_600, 123_456_789), Self.duration(-1, -500_000_000)),
                        (Self.timestamp(-62_135_596_800, 0), Self.duration(315_576_000_000, 999_999_999)),
                        (Self.timestamp(0, 1), Self.duration(0, 0))] {
            let w = W(ts: ts, d: d)
            let tsBytes: Data = try ts.serializedBytes()
            let dBytes: Data = try d.serializedBytes()
            var want = Data([0x0a, UInt8(tsBytes.count)]) + tsBytes
            want += Data([0x12, UInt8(dBytes.count)]) + dBytes
            let got = try PBEncoder().encode(w)
            XCTAssertEqual(got.map { String(format: "%02x", $0) }.joined(), want.map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(try PBDecoder().decode(W.self, from: got), w)
            XCTAssertEqual(try PBEncoder().encode(ts), tsBytes)
            XCTAssertEqual(try PBDecoder().decode(Google_Protobuf_Duration.self, from: dBytes), d)
        }
    }
}
