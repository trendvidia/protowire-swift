// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// The schema-free half of keyed repeated fields: `field_entry = (identifier
/// | string), (assignment_tail | block_tail)`. The AST keeps the unquoted
/// name and whether it was quoted, and the formatter reproduces it.
final class PXFKeyedGrammarTests: XCTestCase {

    func testQuotedBlockName_keepsValueAndQuotedness() throws {
        let doc = try PXF.Parser(string: #"regions { "us-east-1" { replicas = 3 } }"#).parseDocument()
        let regions = try XCTUnwrap(doc.entries.first as? PXF.Block)
        XCTAssertFalse(regions.nameQuoted)
        let entry = try XCTUnwrap(regions.entries.first as? PXF.Block)
        XCTAssertEqual(entry.name, "us-east-1")
        XCTAssertTrue(entry.nameQuoted)
    }

    func testQuotedAssignmentName_keepsValueAndQuotedness() throws {
        let doc = try PXF.Parser(string: #"regions { "us-east-1" = { replicas = 3 } bare = 1 }"#).parseDocument()
        let regions = try XCTUnwrap(doc.entries.first as? PXF.Block)
        let quoted = try XCTUnwrap(regions.entries[0] as? PXF.Assignment)
        XCTAssertEqual(quoted.key, "us-east-1")
        XCTAssertTrue(quoted.keyQuoted)
        XCTAssertFalse(try XCTUnwrap(regions.entries[1] as? PXF.Assignment).keyQuoted)
    }

    func testQuotedName_isAcceptedAtTopLevel() throws {
        let doc = try PXF.Parser(string: #""a" = 1"#).parseDocument()
        XCTAssertEqual(try XCTUnwrap(doc.entries.first as? PXF.Assignment).key, "a")
    }

    func testEscapesInName_areDecoded() throws {
        let doc = try PXF.Parser(string: #""a\"b" { }"#).parseDocument()
        XCTAssertEqual(try XCTUnwrap(doc.entries.first as? PXF.Block).name, "a\"b")
    }

    func testQuotedness_takesPartInEquality() throws {
        let bare = try PXF.Parser(string: "a { }").parseDocument()
        let quoted = try PXF.Parser(string: #""a" { }"#).parseDocument()
        XCTAssertNotEqual(bare, quoted)
    }

    func testFormat_reproducesQuoting() throws {
        let input = """
        regions {
          "us-east-1" {
            replicas = 3
          }
          "plain" = {
            replicas = 1
          }
          bare {
            replicas = 2
          }
        }

        """
        let doc = try PXF.Parser(string: input).parseDocument()
        XCTAssertEqual(PXF.Format.formatDocument(doc), input)
    }

    func testIntegerNames_stillTakeOnlyTheMapTail() {
        for input in ["m { 1 = 2 }", "m { 1 { } }"] {
            XCTAssertThrowsError(try PXF.Parser(string: input).parseDocument(), input) { error in
                XCTAssertTrue("\(error)".contains("requires an identifier or string key"), "\(error)")
            }
        }
    }

    func testMapEntries_areUnchanged() throws {
        let doc = try PXF.Parser(string: #"m { "a": 1 b: 2 7: 3 }"#).parseDocument()
        let m = try XCTUnwrap(doc.entries.first as? PXF.Block)
        XCTAssertEqual(m.entries.compactMap { ($0 as? PXF.MapEntry)?.key }, ["a", "b", "7"])
        XCTAssertThrowsError(try PXF.Parser(string: #""a": 1"#).parseDocument())
    }
}
