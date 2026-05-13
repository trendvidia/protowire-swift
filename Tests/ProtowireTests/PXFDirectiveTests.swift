// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
//
// Parser-tier tests for the v1.0 directive grammar:
//   - `@<name> *(<prefix>) [{ ... }]`     (draft §3.4.2)
//   - `@entry  *(<prefix>) [{ ... }]`     (draft §3.4.3)
//   - `@dataset  <type> ( cols ) row*`    (draft §3.4.4)
//   - `@proto <body>` (4 shapes)          (draft §3.4.5)
//
// Mirrors the Go reference's directive_test.go + directive_proto_test.go
// and the Rust port's tests/directive.rs.
import XCTest
@testable import Protowire

final class PXFDirectiveTests: XCTestCase {

    // MARK: - Generic @<name> directive

    func testBareDirective_noPrefix_noBody() throws {
        let doc = try PXF.Parser(string: "@frob\nname = \"x\"\n").parseDocument()
        XCTAssertEqual(doc.directives.count, 1)
        let d = doc.directives[0]
        XCTAssertEqual(d.name, "frob")
        XCTAssertTrue(d.prefixes.isEmpty)
        XCTAssertNil(d.body)
        XCTAssertEqual(d.type, "")
        XCTAssertEqual(doc.entries.count, 1)
    }

    func testSinglePrefix_populatesLegacyType() throws {
        let doc = try PXF.Parser(string: "@header chameleon.v1.LayerHeader { id = \"x\" }\nbody = \"z\"\n").parseDocument()
        let d = doc.directives[0]
        XCTAssertEqual(d.name, "header")
        XCTAssertEqual(d.prefixes, ["chameleon.v1.LayerHeader"])
        XCTAssertEqual(d.type, "chameleon.v1.LayerHeader")
        XCTAssertNotNil(d.body)
        let body = String(data: d.body!, encoding: .utf8)!
        XCTAssertTrue(body.contains("id = \"x\""))
    }

    func testTwoPrefixes_leaveTypeEmpty() throws {
        let doc = try PXF.Parser(string: "@entry mylabel pkg.MsgType { x = 1 }\nname = \"z\"\n").parseDocument()
        let d = doc.directives[0]
        XCTAssertEqual(d.prefixes, ["mylabel", "pkg.MsgType"])
        XCTAssertEqual(d.type, "")
    }

    func testPrefixLookahead_stopsAtBodyKey() throws {
        let doc = try PXF.Parser(string: "@foo BarType\nbody_key = \"x\"\n").parseDocument()
        let d = doc.directives[0]
        XCTAssertEqual(d.prefixes, ["BarType"])
        XCTAssertEqual(doc.entries.count, 1)
    }

    func testMultipleDirectives_inSourceOrder() throws {
        let src = """
        @type some.MsgType
        @header pkg.Header { id = "h1" }
        @frob alpha beta
        name = "z"
        """
        let doc = try PXF.Parser(string: src).parseDocument()
        XCTAssertEqual(doc.typeURL, "some.MsgType")
        XCTAssertEqual(doc.directives.map { $0.name }, ["header", "frob"])
        XCTAssertEqual(doc.directives[1].prefixes, ["alpha", "beta"])
        XCTAssertGreaterThan(doc.bodyOffset, 0)
    }

    func testBlockBody_preservesRawBytes() throws {
        let doc = try PXF.Parser(string: "@hdr T { a = 1\n b = \"x\" }\nrest = 0\n").parseDocument()
        let d = doc.directives[0]
        XCTAssertNotNil(d.body)
        let body = String(data: d.body!, encoding: .utf8)!
        XCTAssertTrue(body.contains("a = 1"))
        XCTAssertTrue(body.contains("b = \"x\""))
        XCTAssertFalse(body.contains("}"))
    }

    func testNestedBracesInBody() throws {
        let doc = try PXF.Parser(string: "@nested T { inner { a = 1 } }\n").parseDocument()
        let body = String(data: doc.directives[0].body!, encoding: .utf8)!
        XCTAssertTrue(body.contains("inner { a = 1 }"))
    }

    func testBracesInsideStrings_notCounted() throws {
        let doc = try PXF.Parser(string: "@s T { a = \"}{\" }\n").parseDocument()
        XCTAssertNotNil(doc.directives[0].body)
    }

    func testLineCommentInsideBody() throws {
        let doc = try PXF.Parser(string: "@h T { a = 1 # trailing } comment\n  b = 2\n}\n").parseDocument()
        XCTAssertNotNil(doc.directives[0].body)
    }

    func testBlockCommentInsideBody() throws {
        let doc = try PXF.Parser(string: "@h T { a = 1 /* not a } close */ b = 2 }\n").parseDocument()
        XCTAssertNotNil(doc.directives[0].body)
    }

    func testAtTypeWithoutIdent_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@type =\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected type URL after @type"))
        }
    }

    func testBareAt_isIllegal() {
        XCTAssertThrowsError(try PXF.Parser(string: "@\n").parseDocument())
    }

    // MARK: - Future-reserved directive names (draft §3.4.6)

    func testFutureReservedDirective_rejected() {
        for name in ["table", "datasource", "view", "procedure", "function", "permissions"] {
            XCTAssertThrowsError(try PXF.Parser(string: "@\(name) foo\nx = 1\n").parseDocument()) { err in
                XCTAssertTrue("\(err)".contains("spec-reserved"), "for @\(name): got \(err)")
                XCTAssertTrue("\(err)".contains("@\(name)"))
            }
        }
    }

    func testSchema_isFutureReservedDirective() {
        XCTAssertTrue(PXF.Schema.isFutureReservedDirective("table"))
        XCTAssertTrue(PXF.Schema.isFutureReservedDirective("permissions"))
        XCTAssertFalse(PXF.Schema.isFutureReservedDirective("header"))
        XCTAssertFalse(PXF.Schema.isFutureReservedDirective("entry"))
        XCTAssertFalse(PXF.Schema.isFutureReservedDirective("dataset"))
        XCTAssertFalse(PXF.Schema.isFutureReservedDirective("proto"))
        XCTAssertFalse(PXF.Schema.isFutureReservedDirective("type"))
    }

    // MARK: - @dataset directive

    func testDataset_basicTwoColumnsTwoRows() throws {
        let src = "@dataset trades.v1.Trade ( px, qty )\n( 100, 5 )\n( 101, 7 )\n"
        let doc = try PXF.Parser(string: src).parseDocument()
        XCTAssertEqual(doc.datasets.count, 1)
        let t = doc.datasets[0]
        XCTAssertEqual(t.type, "trades.v1.Trade")
        XCTAssertEqual(t.columns, ["px", "qty"])
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[0].cells.count, 2)
    }

    func testDataset_emptyCell_meansAbsent() throws {
        let doc = try PXF.Parser(string: "@dataset x.Row ( a, b, c )\n( 1, , 3 )\n").parseDocument()
        let row = doc.datasets[0].rows[0]
        XCTAssertNotNil(row.cells[0])
        XCTAssertNil(row.cells[1])
        XCTAssertNotNil(row.cells[2])
    }

    func testDataset_nullCell_meansPresentNull() throws {
        let doc = try PXF.Parser(string: "@dataset x.Row ( a, b )\n( 1, null )\n").parseDocument()
        let row = doc.datasets[0].rows[0]
        XCTAssertTrue(row.cells[1]?.value is PXF.NullVal)
    }

    func testDataset_zeroRows_valid() throws {
        let doc = try PXF.Parser(string: "@dataset x.Row ( a, b )\n").parseDocument()
        XCTAssertEqual(doc.datasets.count, 1)
        XCTAssertTrue(doc.datasets[0].rows.isEmpty)
    }

    func testDataset_arityMismatch_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a, b )\n( 1, 2, 3 )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("3 cells, expected 2"))
        }
    }

    func testDataset_dottedColumn_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a.b )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("dotted column"))
        }
    }

    func testDataset_listCell_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a )\n( [1, 2] )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("list"))
        }
    }

    func testDataset_blockCell_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a )\n( { x = 1 } )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("block"))
        }
    }

    func testDataset_standalone_rejectsCoexistingAtTypeBefore() {
        XCTAssertThrowsError(try PXF.Parser(string: "@type other\n@dataset x.Row ( a )\n( 1 )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("cannot coexist with @type"))
        }
    }

    func testDataset_standalone_rejectsAtTypeAfterDataset() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a )\n@type other\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("cannot coexist with @type"))
        }
    }

    func testDataset_standalone_rejectsCoexistingBodyEntries() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a )\n( 1 )\nextra = 5\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("cannot coexist with top-level field entries"))
        }
    }

    func testDataset_missingType_isPermissive() throws {
        let doc = try PXF.Parser(string: "@dataset ( a )\n").parseDocument()
        XCTAssertEqual(doc.datasets.count, 1)
        XCTAssertEqual(doc.datasets[0].type, "")
    }

    func testDataset_missingLParen_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row a, b\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected '(' to start"))
        }
    }

    func testDataset_emptyColumnList_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("at least one field name"))
        }
    }

    func testDataset_badColumnToken_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a, 123 )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected column field name"))
        }
    }

    func testDataset_missingCommaInColumns_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a b )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected ',' or ')' in @dataset column list"))
        }
    }

    func testDataset_missingCommaInRow_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@dataset x.Row ( a, b )\n( 1 2 )\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected ',' or ')' in @dataset row"))
        }
    }

    // MARK: - @proto directive

    func testProto_anonymous_capturesRawBytes() throws {
        let doc = try PXF.Parser(string: "@proto { int32 id = 1; string name = 2; }\n").parseDocument()
        XCTAssertEqual(doc.protos.count, 1)
        let p = doc.protos[0]
        XCTAssertEqual(p.shape, .anonymous)
        XCTAssertEqual(p.typeName, "")
        let body = String(data: p.body, encoding: .utf8)!
        XCTAssertTrue(body.contains("int32 id = 1;"))
        XCTAssertTrue(body.contains("string name = 2;"))
    }

    func testProto_named_capturesRawBytes() throws {
        let doc = try PXF.Parser(string: "@proto trades.v1.Trade { double px = 1; int64 qty = 2; }\n").parseDocument()
        let p = doc.protos[0]
        XCTAssertEqual(p.shape, .named)
        XCTAssertEqual(p.typeName, "trades.v1.Trade")
        let body = String(data: p.body, encoding: .utf8)!
        XCTAssertTrue(body.contains("double px = 1;"))
    }

    func testProto_source_tripleQuoted() throws {
        let src = "@proto \"\"\"\n  syntax = \"proto3\";\n  message M { int32 id = 1; }\n  \"\"\"\n"
        let doc = try PXF.Parser(string: src).parseDocument()
        let p = doc.protos[0]
        XCTAssertEqual(p.shape, .source)
        let body = String(data: p.body, encoding: .utf8)!
        XCTAssertTrue(body.contains("syntax = \"proto3\";"))
    }

    func testProto_descriptor_base64() throws {
        let raw = Data([0x0a, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
        let b64 = raw.base64EncodedString()
        let doc = try PXF.Parser(string: "@proto b\"\(b64)\"\n").parseDocument()
        let p = doc.protos[0]
        XCTAssertEqual(p.shape, .descriptor)
        XCTAssertEqual(p.body, raw)
    }

    func testProto_namedWithoutBrace_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@proto trades.v1.Trade\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected '{'"))
        }
    }

    func testProto_badShape_rejected() {
        XCTAssertThrowsError(try PXF.Parser(string: "@proto =\n").parseDocument()) { err in
            XCTAssertTrue("\(err)".contains("expected '{', dotted identifier"))
        }
    }

    func testProto_anonymousBeforeDataset() throws {
        let src = """
        @proto { int32 id = 1; }
        @dataset ( id )
        ( 7 )
        """
        let doc = try PXF.Parser(string: src).parseDocument()
        XCTAssertEqual(doc.protos.count, 1)
        XCTAssertEqual(doc.protos[0].shape, .anonymous)
        XCTAssertEqual(doc.datasets.count, 1)
        XCTAssertEqual(doc.datasets[0].type, "")
        XCTAssertEqual(doc.datasets[0].rows.count, 1)
    }
}
