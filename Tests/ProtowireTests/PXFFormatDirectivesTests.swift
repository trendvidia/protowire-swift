// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// `PXF.Format.formatDocument` keeps every directive, with its dataset rows,
/// in document order (trendvidia/protowire#558, protowire-swift#90). Ported
/// from protowire-go's `format_directives_test.go`; the expected texts are
/// the ones protowire-go's `FormatDocument` writes for the same sources.
final class PXFFormatDirectivesTests: XCTestCase {

    /// Formats `src`, checks that the output parses to the same directives
    /// and is a fixed point of formatting, and returns it.
    private func formatRoundTrip(_ src: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let doc = try PXF.Parser(string: src).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        let again = try PXF.Parser(string: out).parseDocument()
        XCTAssertEqual(directiveShape(doc), directiveShape(again), out, file: file, line: line)
        XCTAssertEqual(out, PXF.Format.formatDocument(again), "formatting is a fixed point", file: file, line: line)
        return out
    }

    /// What a document's directives say, without positions.
    private func directiveShape(_ doc: PXF.Document) -> [String] {
        var out: [String] = ["type=\(doc.typeURL ?? "")"]
        for d in doc.directives {
            out.append("@\(d.name) \(d.prefixes) body=\(d.body.map { String(decoding: $0, as: UTF8.self) } ?? "<none>")")
        }
        for d in doc.datasets {
            out.append("@dataset \(d.type) \(d.columns)")
            for r in d.rows {
                out.append(r.cells.map { cell -> String in
                    guard let cell else { return "<absent>" }
                    var s = ""
                    PXF.Format.formatValue(cell.value, level: 0, into: &s)
                    return s
                }.joined(separator: " | "))
            }
        }
        for d in doc.protos {
            out.append("@proto \(d.shape) \(d.typeName) \(String(decoding: d.body, as: UTF8.self))")
        }
        out.append("entries=\(doc.entries.count)")
        return out
    }

    // The issue's input A formatted to nothing.
    func testDataset() throws {
        let src = "@dataset trades.v1.Trade (id, px)\n(1, 2.5)\n(2, 3.5)\n"
        XCTAssertEqual(try formatRoundTrip(src), src)
    }

    // An empty cell is an absent field and null a present one; both stay.
    func testDatasetAbsentAndNullCells() throws {
        let src = "@dataset trades.v1.Trade (id, px, note)\n(1, 2.5, )\n(2, , null)\n"
        XCTAssertEqual(try formatRoundTrip(src), src)
    }

    // The issue's input B lost its @entry.
    func testEntryDirective() throws {
        let src = "@type a.v1.M\n@entry x { a = 1 }\n\nname = \"n\"\n"
        XCTAssertEqual(try formatRoundTrip(src), src)
    }

    func testEntryAndNamedDirective() throws {
        let src = "@type a.v1.M\n@entry x { a = 1 }\n@header h.v1.H\n\nname = \"n\"\n"
        XCTAssertEqual(try formatRoundTrip(src), src)
    }

    func testProtoShapes() throws {
        let cases: [(src: String, want: String?)] = [
            ("@proto { string id = 1; }\n@dataset (id)\n(\"a\")\n", nil),
            ("@proto a.v1.R { string id = 1; }\n@dataset a.v1.R (id)\n(\"a\")\n", nil),
            ("@proto \"\"\"syntax = \"proto3\"; message R { string id = 1; }\"\"\"\n@dataset R (id)\n(\"a\")\n", nil),
            // @type moves to the front: it binds no @proto, so this changes nothing.
            ("@proto b\"CgA=\"\n@type a.v1.M\n\nx = 1\n", "@type a.v1.M\n@proto b\"CgA=\"\n\nx = 1\n"),
        ]
        for c in cases {
            XCTAssertEqual(try formatRoundTrip(c.src), c.want ?? c.src, c.src)
        }
    }

    // An anonymous @proto binds the next typed directive, so a @proto written
    // after a dataset in the source stays after it.
    func testDirectivesKeepSourceOrder() throws {
        let src = "@dataset t.v1.T (id)\n(1)\n@proto { string id = 1; }\n@dataset (id)\n(\"a\")\n"
        XCTAssertEqual(try formatRoundTrip(src), src)
    }

    func testDirectiveComments() throws {
        let out = try formatRoundTrip("# about the rows\n@dataset t.v1.T (id)\n(1)\n# second\n@dataset t.v1.U (id)\n(2)\n")
        XCTAssertTrue(out.contains("# about the rows\n@dataset t.v1.T (id)"), out)
        XCTAssertTrue(out.contains("# second\n@dataset t.v1.U (id)"), out)
    }

    // A document whose only directive is @type formats as it always has.
    func testOnlyTypeUnchanged() throws {
        let doc = try PXF.Parser(string: "# c\n@type a.v1.M\n\nx = 1\n").parseDocument()
        XCTAssertEqual(PXF.Format.formatDocument(doc), "@type a.v1.M\n\n# c\nx = 1\n")
    }
}
