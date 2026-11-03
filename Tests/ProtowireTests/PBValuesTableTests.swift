// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import XCTest
@testable import Protowire

/// The struct-binding table (protowire#509): each row of the spec's
/// `testdata/values/values.tsv` is a value written through a struct API, with
/// the bytes protowire-go writes for it. This holds a Codable twin of each
/// row's struct, with the field numbers and types of the spec's
/// `values_table_test.go`, and compares `PBEncoder`'s bytes.
///
/// The table is read from the conformance record, where `conformance/refgen`
/// copies it unchanged, so the `conformance-record` workflow proves it is the
/// spec's file.
final class PBValuesTableTests: XCTestCase {
    // MARK: - Twins of values_table_test.go

    struct Ints: Encodable {
        var a: Int64, b: Int64, c: Int32
        var m: [String: Int64], mi: [String: Int32]
        enum CodingKeys: Int, CodingKey { case a = 1, b, c, m, mi }
    }
    struct Age: Encodable {
        var age: Int32
        enum CodingKeys: Int, CodingKey { case age = 1 }
    }
    struct MinLong: Encodable {
        var v: Int64
        enum CodingKeys: Int, CodingKey { case v = 1 }
    }
    /// Go tags both fields `zigzag` (sint64, sint32). PBEncoder has no way to
    /// say so, so this writes them as int64 and int32 (#70).
    struct Zigzag: Encodable {
        var d: Int64, e: Int32
        enum CodingKeys: Int, CodingKey { case d = 1, e }
    }
    struct Packed: Encodable {
        var xs: [Int32], ys: [Int64], bs: [Bool], ds: [Double], fs: [Float]
        enum CodingKeys: Int, CodingKey { case xs = 1, ys, bs, ds, fs }
    }
    struct ZeroMapEntry: Encodable {
        var m: [String: String], z: [String: Int32], k: [Int32: String]
        enum CodingKeys: Int, CodingKey { case m = 1, z, k }
    }
    /// Go's `*big.Rat` is nullable, so each big number is an Optional here.
    struct Decimal: Encodable {
        var d: Pxf_Decimal?
        enum CodingKeys: Int, CodingKey { case d = 1 }
    }
    struct Decimals: Encodable {
        var ds: [Pxf_Decimal?]
        enum CodingKeys: Int, CodingKey { case ds = 1 }
    }
    struct Leaf: Encodable {
        var name: String = "", n: Int32 = 0
        enum CodingKeys: Int, CodingKey { case name = 1, n }
    }
    struct Nested: Encodable {
        var s: String, ls: [Leaf], ss: [String]
        enum CodingKeys: Int, CodingKey { case s = 1, ls, ss }
    }
    struct Zeros: Encodable {
        var i: Int32 = 0, s = "", b = false, d = 0.0, bs = Data(), u: UInt64 = 0
        enum CodingKeys: Int, CodingKey { case i = 1, s, b, d, bs, u }
    }
    struct BigNums: Encodable {
        var i: Pxf_BigInt?, d: Pxf_Decimal?, f: Pxf_BigFloat?
        enum CodingKeys: Int, CodingKey { case i = 1, d, f }
    }
    struct BigInts: Encodable {
        var values: [Pxf_BigInt?]
        enum CodingKeys: Int, CodingKey { case values = 1 }
    }
    struct BigFloatMap: Encodable {
        var m: [String: Pxf_BigFloat?]
        enum CodingKeys: Int, CodingKey { case m = 1 }
    }
    struct BigFloat: Encodable {
        var f: Pxf_BigFloat?
        enum CodingKeys: Int, CodingKey { case f = 1 }
    }

    // MARK: - Big numbers from the row's words

    // This port binds a big number to its generated message, so a value is
    // built the one way the port turns a number into one: its PXF literal
    // reader, which is what `PXFDecoder` hands a struct field.

    private func int(_ literal: String) throws -> Pxf_BigInt {
        var v = Pxf_BigInt()
        (v.abs, v.negative) = try PXF.parseBigInt(literal, codingPath: [])
        return v
    }
    private func dec(_ literal: String) throws -> Pxf_Decimal { try PXF.parseDecimal(literal) }
    private func float(_ literal: String) throws -> Pxf_BigFloat { try PXF.parseBigFloat(literal) }

    /// Each row's twin, keyed by the row's case name.
    private func twins() -> [String: () throws -> Encodable] {
        [
            "Ints": { Ints(a: -1, b: -1, c: -1, m: ["k": -1], mi: ["k": -1]) },
            "Age": { Age(age: 30) },
            "MinLong": { MinLong(v: .min) },
            "Zigzag": { Zigzag(d: -1, e: -2) },
            "Packed": { Packed(xs: [1, 0, -1], ys: [300], bs: [true, false], ds: [1.5], fs: [-2.5]) },
            "ZeroMapEntry": { ZeroMapEntry(m: ["": ""], z: ["zero": 0], k: [0: "v"]) },
            "Decimal": { Decimal(d: try self.dec("3.1415")) },
            "DecimalOne": { Decimal(d: try self.dec("1.00")) },
            "DecimalFiveE2": { Decimal(d: try self.dec("5E+2")) },
            "DecimalFifteen": { Decimal(d: try self.dec("15.00")) },
            "DecimalZero": { Decimal(d: try self.dec("0.00")) },
            "DecimalNegative": { Decimal(d: try self.dec("-1.50")) },
            "Decimals": { Decimals(ds: [try self.dec("0.00"), try self.dec("1.00"), try self.dec("5E+2")]) },
            "Nested": { Nested(s: "x", ls: [Leaf(), Leaf(name: "l", n: -3)], ss: ["", "s"]) },
            "Zeros": { Zeros() },
            "BigNumsNull": { BigNums(i: nil, d: nil, f: nil) },
            "BigNumsZero": { BigNums(i: try self.int("0"), d: try self.dec("0"), f: Pxf_BigFloat()) },
            "BigNumsNegative": { BigNums(i: try self.int("-12345678901234567890"), d: try self.dec("-0.5"), f: try self.float("-1.5p53")) },
            "BigIntsZeroElement": { BigInts(values: [try self.int("0"), try self.int("1")]) },
            "BigIntsNullElement": { BigInts(values: [try self.int("1"), nil]) },
            "DecimalsNullElement": { Decimals(ds: [try self.dec("1"), nil]) },
            "BigFloatMapNullValue": { BigFloatMap(m: ["k": nil]) },
            "BigFloatPrec64": { BigFloat(f: try self.float("1.5p64")) },
        ]
    }

    /// Rows this port does not write as protowire-go does, each with the
    /// issue that tracks it. A pinned row that starts to match fails, so the
    /// fix has to remove it here.
    private let divergences: [String: String] = [
        // No way to mark a field sint32 / sint64.
        "Zigzag": "#70",
        // No arbitrary-precision language type: a big number is its generated
        // message, which the draft says is written as it is, scale and all.
        "DecimalOne": "#71",
        "DecimalFiveE2": "#71",
        "DecimalFifteen": "#71",
        "DecimalZero": "#71",
        "DecimalNegative": "#71",
        "Decimals": "#71",
        "BigNumsZero": "#71",
    ]

    private struct Row { var name: String; var hex: String; var value: String }

    private static func rows() throws -> [Row] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("testdata/conformance/values.tsv")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            if line.hasPrefix("#") { return nil }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 3 else { throw NSError(domain: "values.tsv", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad row: \(line)"]) }
            return Row(name: cols[0], hex: cols[1], value: cols[2])
        }
    }

    func testValuesTable() throws {
        let rows = try Self.rows()
        let twins = twins()
        XCTAssertEqual(rows.count, 23, "values.tsv changed size: add or remove twins")
        XCTAssertEqual(Set(rows.map(\.name)), Set(twins.keys), "a row without a twin, or a twin without a row")
        var compared = 0
        for row in rows {
            guard let twin = twins[row.name] else { continue }
            let got: String
            do {
                got = try PBEncoder().encode(AnyEncodable(try twin())).map { String(format: "%02x", $0) }.joined()
            } catch {
                got = "error: \(error)"
            }
            compared += 1
            let matches = got == row.hex
            if let issue = divergences[row.name] {
                XCTAssertFalse(matches, "\(row.name) now matches protowire-go; remove it from divergences (\(issue))")
                print("values \(row.name): pinned (\(issue)): got \(got), go \(row.hex)")
            } else {
                XCTAssertTrue(matches, "\(row.name) \(row.value): got \(got), go \(row.hex)")
            }
        }
        XCTAssertEqual(compared, rows.count)
        print("values table: compared \(compared), pinned \(divergences.count)")
    }
}

/// Lets a twin closure return any Encodable struct.
private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
