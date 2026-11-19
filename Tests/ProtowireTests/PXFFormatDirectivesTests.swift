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
            // The triple quotes go on lines of their own (protowire-go#303).
            ("@proto \"\"\"syntax = \"proto3\"; message R { string id = 1; }\"\"\"\n@dataset R (id)\n(\"a\")\n",
             "@proto \"\"\"\nsyntax = \"proto3\"; message R { string id = 1; }\n\"\"\"\n@dataset R (id)\n(\"a\")\n"),
            // @type moves to the front: it binds no @proto, so this changes nothing.
            ("@proto b\"CgA=\"\n@type a.v1.M\n\nx = 1\n", "@type a.v1.M\n@proto b\"CgA=\"\n\nx = 1\n"),
        ]
        for c in cases {
            XCTAssertEqual(try formatRoundTrip(c.src), c.want ?? c.src, c.src)
        }
    }

    // A triple-quoted @proto is written with its delimiters on lines of their
    // own, and its body reads back byte for byte (protowire-go#303).
    func testProtoSourceLayout() throws {
        // The line breaks around the body stay.
        let src = "@proto \"\"\"\n  syntax = \"proto3\";\n  package fmt.v1;\n  message Doc { string name = 1; }\n\"\"\"\n@type fmt.v1.Doc\n"
        XCTAssertEqual(try formatRoundTrip(src),
                       "@type fmt.v1.Doc\n@proto \"\"\"\n  syntax = \"proto3\";\n  package fmt.v1;\n  message Doc { string name = 1; }\n\"\"\"\n")

        let cases: [(name: String, src: String, body: String)] = [
            // Written on the closing delimiter's line, the last quote would
            // open the closing """ early, and the output would not parse.
            ("body ends in a quote", "@proto \"\"\"\n  syntax = \"proto3\";\n  import \"google/protobuf/empty.proto\"\n  \"\"\"\n",
             "syntax = \"proto3\";\nimport \"google/protobuf/empty.proto\""),
            // Written on the closing delimiter's line, a last line of only
            // whitespace would be taken for the delimiter's indent and dropped.
            ("whitespace-only last line", "@proto \"\"\"syntax = \"proto3\";\n  \n\"\"\"\n", "syntax = \"proto3\";\n  "),
            ("leading line break", "@proto \"\"\"\n\nsyntax = \"proto3\";\"\"\"\n", "\nsyntax = \"proto3\";"),
            ("trailing line break", "@proto \"\"\"syntax = \"proto3\";\n\n\"\"\"\n", "syntax = \"proto3\";\n"),
            ("empty body", "@proto \"\"\"\"\"\"\n", ""),
        ]
        for c in cases {
            let doc = try PXF.Parser(string: c.src).parseDocument()
            XCTAssertEqual(doc.protos.count, 1, c.name)
            XCTAssertEqual(String(decoding: doc.protos.first?.body ?? Data(), as: UTF8.self), c.body, "\(c.name): body as read")
            let out = try formatRoundTrip(c.src)
            XCTAssertEqual(out, "@proto \"\"\"\n" + c.body + "\n\"\"\"\n", c.name)
            let again = try PXF.Parser(string: out).parseDocument()
            XCTAssertEqual(again.protos.first?.body, doc.protos.first?.body, "\(c.name): body after a re-parse")
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
