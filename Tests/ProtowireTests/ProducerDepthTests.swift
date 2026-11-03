// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// A producer refuses a value nested deeper than `MaxNestingDepth`, counted as
/// a decoder reading its output counts it (HARDENING.md § Recursion,
/// protowire#502). Each bound is checked from both sides: the deepest value
/// the producer writes is read back by a decoder at the same limit, and one
/// level more is refused by the producer, and by the decoder when a producer
/// with a raised limit writes it anyway.
final class ProducerDepthTests: XCTestCase {
    typealias Tree = HardeningTests.Tree

    // MARK: - shapes

    /// `n` nested `child` messages: n descents in PXF and in PB.
    private func children(_ n: Int, innermost: Tree = Tree()) -> Tree {
        var t = innermost
        for _ in 0..<n { let p = Tree(); p.child = t; t = p }
        return t
    }

    /// `n` nested `branches` entries with a message value: 2n descents in
    /// both, the map's `{` and the value's in PXF, the entry and the value
    /// message in PB.
    private func branches(_ n: Int, innermost: Tree = Tree()) -> Tree {
        var t = innermost
        for _ in 0..<n { let p = Tree(); p.branches = ["k": t]; t = p }
        return t
    }

    /// `n` nested one-element `children` lists: 2n descents in PXF, `[` and
    /// `{`, and n in PB, where an element is just a submessage.
    private func listed(_ n: Int, innermost: Tree = Tree()) -> Tree {
        var t = innermost
        for _ in 0..<n { let p = Tree(); p.children = [t]; t = p }
        return t
    }

    /// A Tree holding a scalar map, whose `{` (PXF) or entry (PB) is a descent.
    private func tagged() -> Tree {
        let t = Tree()
        t.tags = ["k": "v"]
        return t
    }

    private func pxf(_ limit: Int = Hardening.maxNestingDepth, emitDefaults: Bool = false) -> PXFEncoder {
        let e = PXFEncoder()
        e.limits.maxNestingDepth = limit
        e.emitDefaults = emitDefaults
        return e
    }

    private func pb(_ limit: Int = Hardening.maxNestingDepth) -> PBEncoder {
        let e = PBEncoder()
        e.limits.maxNestingDepth = limit
        return e
    }

    private func readPXF(_ text: String, limit: Int = Hardening.maxNestingDepth) throws {
        let d = PXFDecoder()
        d.limits.maxNestingDepth = limit
        _ = try d.decode(Tree.self, from: Data(text.utf8))
    }

    private func readPB(_ bytes: Data, limit: Int = Hardening.maxNestingDepth) throws {
        let d = PBDecoder()
        d.limits.maxNestingDepth = limit
        _ = try d.decode(Tree.self, from: bytes)
    }

    /// The deepest `value` writes and reads back at `limit`; `over` is
    /// refused by the producer, and the text a producer one level more
    /// lenient writes for it is refused by the decoder.
    private func assertPXFBound(_ value: Tree, over: Tree, limit: Int = Hardening.maxNestingDepth,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try pxf(limit).encode(value)
        XCTAssertNoThrow(try readPXF(text, limit: limit), file: file, line: line)
        assertDepth(try pxf(limit).encode(over), limit: limit, file: file, line: line)
        let past = try pxf(limit + 1).encode(over)
        XCTAssertThrowsError(try readPXF(past, limit: limit), file: file, line: line) { err in
            guard case DecoderError.nestingDepthExceeded(limit + 1, limit: limit) = err else {
                return XCTFail("expected nestingDepthExceeded(\(limit + 1)), got \(err)", file: file, line: line)
            }
        }
    }

    private func assertPBBound(_ value: Tree, over: Tree, limit: Int = Hardening.maxNestingDepth,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try pb(limit).encode(value)
        XCTAssertNoThrow(try readPB(bytes, limit: limit), file: file, line: line)
        assertDepth(try pb(limit).encode(over), limit: limit, file: file, line: line)
        let past = try pb(limit + 1).encode(over)
        XCTAssertThrowsError(try readPB(past, limit: limit), file: file, line: line) { err in
            guard case DecoderError.nestingDepthExceeded(limit + 1, limit: limit) = err else {
                return XCTFail("expected nestingDepthExceeded(\(limit + 1)), got \(err)", file: file, line: line)
            }
        }
    }

    private func assertDepth<T>(_ expression: @autoclosure () throws -> T, limit: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { err in
            guard case EncodingError.invalidValue(_, let ctx) = err,
                  ctx.debugDescription.hasSuffix("nesting depth \(limit + 1) exceeds MaxNestingDepth=\(limit)") else {
                return XCTFail("expected a nesting-depth EncodingError at \(limit + 1), got \(err)", file: file, line: line)
            }
        }
    }

    // MARK: - PXFEncoder

    func testPXFNestedMessagesAt100And101() throws {
        try assertPXFBound(children(100), over: children(101))
    }

    func testPXFMapValuesAt100And101() throws {
        try assertPXFBound(branches(50), over: branches(50, innermost: children(1)))
    }

    func testPXFListsAt100And101() throws {
        try assertPXFBound(listed(50), over: listed(50, innermost: children(1)))
    }

    /// A scalar map opens a block of its own: 99 messages and a map is 100.
    func testPXFScalarMapAt100And101() throws {
        try assertPXFBound(children(99, innermost: tagged()), over: children(100, innermost: tagged()))
    }

    /// An empty list that is left out opens nothing; written as `[]`, it does.
    func testPXFEmptyListCountsOnlyWhenWritten() throws {
        let inner = Tree()
        inner.children = []
        XCTAssertNoThrow(try pxf().encode(children(100, innermost: inner)))
        assertDepth(try pxf(emitDefaults: true).encode(children(100, innermost: inner)), limit: 100)
    }

    /// The same for an empty map, written as `{}`.
    func testPXFEmptyMapCountsOnlyWhenWritten() throws {
        let inner = Tree()
        inner.tags = [:]
        XCTAssertNoThrow(try pxf().encode(children(100, innermost: inner)))
        assertDepth(try pxf(emitDefaults: true).encode(children(100, innermost: inner)), limit: 100)
    }

    func testPXFRaisedLimitPerCall() throws {
        let deep = children(150)
        assertDepth(try pxf().encode(deep), limit: 100)
        try assertPXFBound(deep, over: children(151), limit: 150)
        try assertPXFBound(branches(75), over: branches(75, innermost: children(1)), limit: 150)
    }

    /// A reference cycle meets the limit instead of exhausting the stack.
    func testPXFCycleMeetsTheLimit() {
        let loop = Tree()
        loop.child = loop
        assertDepth(try pxf().encode(loop), limit: 100)
        loop.child = nil
    }

    // MARK: - PBEncoder

    func testPBNestedMessagesAt100And101() throws {
        try assertPBBound(children(100), over: children(101))
    }

    func testPBMapValuesAt100And101() throws {
        try assertPBBound(branches(50), over: branches(50, innermost: children(1)))
    }

    /// A list element is one descent in PB, not two as in PXF.
    func testPBListsAt100And101() throws {
        try assertPBBound(listed(100), over: listed(101))
    }

    /// A scalar map entry is a descent whatever its value's type.
    func testPBScalarMapAt100And101() throws {
        try assertPBBound(children(99, innermost: tagged()), over: children(100, innermost: tagged()))
    }

    func testPBRaisedLimitPerCall() throws {
        let deep = children(150)
        assertDepth(try pb().encode(deep), limit: 100)
        try assertPBBound(deep, over: children(151), limit: 150)
        try assertPBBound(branches(75), over: branches(75, innermost: children(1)), limit: 150)
    }

    func testPBCycleMeetsTheLimit() {
        let loop = Tree()
        loop.child = loop
        assertDepth(try pb().encode(loop), limit: 100)
        loop.child = nil
    }
}
