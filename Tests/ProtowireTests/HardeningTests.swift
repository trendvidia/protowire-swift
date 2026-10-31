// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// Regression tests for the HARDENING.md decoder-safety contract. These are
/// the inputs the cross-port adversarial corpus surfaces; once the conformance
/// gate flips to required this file plus the corpus run together.
final class HardeningTests: XCTestCase {

    // Mirrors the corpus's adversarial.v1.Tree.
    final class Tree: Codable {
        var child: Tree?
        var label: String?
        var children: [Tree]?
        var branches: [String: Tree]?
        var tags: [String: String]?
        enum CodingKeys: Int, CodingKey { case child = 1, label = 2, children = 3, branches = 4, tags = 5 }
    }

    struct StringHolder: Codable {
        var value: String?
        enum CodingKeys: Int, CodingKey { case value = 1 }
    }

    // MARK: - PXF nesting depth

    func testPXFRejectsNestingOverLimit() throws {
        // 200 levels of `child{...}` exceeds MaxNestingDepth=100.
        var s = "@type adversarial.v1.Tree\n"
        for _ in 0..<200 { s += "child{" }
        for _ in 0..<200 { s += "}" }

        let dec = PXFDecoder()
        XCTAssertThrowsError(try dec.decode(Tree.self, from: Data(s.utf8))) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    func testPXFAcceptsNestingAtBaseline() throws {
        // 10 levels is well below the limit and must round-trip.
        var s = "@type adversarial.v1.Tree\n"
        for _ in 0..<10 { s += "child{" }
        for _ in 0..<10 { s += "}" }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: Data(s.utf8)))
    }

    /// A map's `{` is a descent and so is its value's, so 50 `branches` levels
    /// are exactly the bound (protowire#449).
    func testPXFCountsAMapsBraceAtTheBound() {
        func doc(pairs: Int, extra: Int) -> String {
            String(repeating: "branches = { k: { ", count: pairs) + String(repeating: "child { ", count: extra)
                + "label = \"x\"" + String(repeating: " }", count: extra) + String(repeating: " } }", count: pairs)
        }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: doc(pairs: 50, extra: 0)))
        assertDepthExceeded(try PXFDecoder().decode(Tree.self, from: doc(pairs: 50, extra: 1)))
    }

    /// A scalar-valued map has no message under it, and its `{` still counts.
    func testPXFCountsAScalarMapsBraceAtTheBound() {
        func doc(blocks: Int) -> String {
            String(repeating: "child { ", count: blocks) + "tags = { k: \"v\" }" + String(repeating: " }", count: blocks)
        }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: doc(blocks: 99)))
        assertDepthExceeded(try PXFDecoder().decode(Tree.self, from: doc(blocks: 100)))
    }

    // MARK: - PXF UTF-8 strictness

    func testPXFRejectsInvalidUTF8InStringLiteral() {
        // \xFF\xFE is not valid UTF-8; per HARDENING.md § UTF-8 the lossy
        // U+FFFD substitution path is forbidden.
        let s = "@type adversarial.v1.StringHolder\nvalue = \"\\xFF\\xFE\"\n"
        XCTAssertThrowsError(try PXFDecoder().decode(StringHolder.self, from: Data(s.utf8)))
    }

    // MARK: - PB nesting depth

    func testPBRejectsSubmessageNestingOverLimit() throws {
        // Build N nested length-delimited Tree submessages: tag=1 wire=2.
        var data = Data()
        for _ in 0..<200 {
            // length placeholder filled below
            data = encodeLenDelim(field: 1, payload: data)
        }
        XCTAssertThrowsError(try PBDecoder().decode(Tree.self, from: data)) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    /// A map entry is a descent and so is a message value inside it, so 50
    /// `branches` levels are exactly the bound (protowire#449).
    func testPBCountsAMapEntryAndItsMessageValueAtTheBound() {
        func message(pairs: Int, extra: Int) -> Data {
            var data = Data()
            for _ in 0..<extra { data = encodeLenDelim(field: 1, payload: data) }
            for _ in 0..<pairs { data = encodeLenDelim(field: 4, payload: mapEntry(value: data)) }
            return data
        }
        XCTAssertNoThrow(try PBDecoder().decode(Tree.self, from: message(pairs: 50, extra: 0)))
        assertDepthExceeded(try PBDecoder().decode(Tree.self, from: message(pairs: 50, extra: 1)))
    }

    /// A scalar-valued entry recurses into nothing, and it is still a descent.
    func testPBCountsAScalarMapEntryAtTheBound() {
        func message(submessages: Int) -> Data {
            var data = encodeLenDelim(field: 5, payload: mapEntry(value: Data("v".utf8)))
            for _ in 0..<submessages { data = encodeLenDelim(field: 1, payload: data) }
            return data
        }
        XCTAssertNoThrow(try PBDecoder().decode(Tree.self, from: message(submessages: 99)))
        assertDepthExceeded(try PBDecoder().decode(Tree.self, from: message(submessages: 100)))
    }

    // MARK: - PB length-prefix bounds

    func testPBRejectsTruncatedLengthPrefix() {
        // tag=1 (string), declared length = 100, no payload.
        let data = Data([0x0a, 0x64])
        XCTAssertThrowsError(try PBDecoder().decode(StringHolder.self, from: data))
    }

    func testPBRejectsLengthPrefixOverflow() {
        // tag=1, length = 2^64-1 (max 10-byte varint). Pre-fix this trapped
        // on the `Int(_:)` conversion; post-fix it must surface as a clean error.
        let data = Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
        XCTAssertThrowsError(try PBDecoder().decode(StringHolder.self, from: data))
    }

    // MARK: - helpers

    private func assertDepthExceeded<T>(_ expression: @autoclosure () throws -> T, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)", line: line)
            }
        }
    }

    /// A `map<string, _>` entry with key "k" and the given length-delimited value.
    private func mapEntry(value: Data) -> Data {
        encodeLenDelim(field: 1, payload: Data("k".utf8)) + encodeLenDelim(field: 2, payload: value)
    }

    /// Wraps `payload` as a length-delimited field with tag=`field` (wire=2).
    private func encodeLenDelim(field: Int, payload: Data) -> Data {
        var out = Data()
        Protowire.appendTag(&out, number: Int32(field), type: .bytes)
        Protowire.appendBytes(&out, payload)
        return out
    }
}
