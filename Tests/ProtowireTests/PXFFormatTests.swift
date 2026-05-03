import XCTest
@testable import Protowire

/// Round-trip tests for `PXF.Format.formatDocument` — the comment-preserving
/// AST formatter that mirrors the Go `format.go` and the C# `Format.cs`.
final class PXFFormatTests: XCTestCase {

    func testFormat_basicAssignment() throws {
        let doc = try PXF.Parser(string: #"name = "Alice""#).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertEqual(out, "name = \"Alice\"\n")
    }

    func testFormat_typeURL() throws {
        let input = "@type example.v1.User\n\nname = \"Alice\"\n"
        let doc = try PXF.Parser(string: input).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertTrue(out.hasPrefix("@type example.v1.User\n\n"))
        XCTAssertTrue(out.contains("name = \"Alice\"\n"))
    }

    func testFormat_preservesLeadingComments() throws {
        let input = """
        # leading comment
        name = "Alice"
        """
        let doc = try PXF.Parser(string: input).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertTrue(out.contains("# leading comment\n"))
        XCTAssertTrue(out.contains("name = \"Alice\"\n"))
    }

    func testFormat_nestedBlock() throws {
        let input = """
        outer {
          inner {
            x = 1
          }
        }
        """
        let doc = try PXF.Parser(string: input).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertEqual(out, "outer {\n  inner {\n    x = 1\n  }\n}\n")
    }

    func testFormat_list() throws {
        let input = "items = [1, 2, 3]"
        let doc = try PXF.Parser(string: input).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertEqual(out, "items = [\n  1,\n  2,\n  3\n]\n")
    }

    func testFormat_quotedMapKey() throws {
        let input = """
        labels = {
          env: "prod"
          "hello world": "v"
        }
        """
        let doc = try PXF.Parser(string: input).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertTrue(out.contains("env: \"prod\""))
        XCTAssertTrue(out.contains("\"hello world\": \"v\""))
    }

    func testFormat_specialCharsInString() throws {
        // Round-trip a string with quote, newline, control byte through
        // parse → format. The lexer should decode escapes; the formatter
        // should re-encode them via PXFEncoder.quote.
        let raw = #"name = "a\"b\nc\x01""#
        let doc = try PXF.Parser(string: raw).parseDocument()
        let out = PXF.Format.formatDocument(doc)
        XCTAssertEqual(out, "name = \"a\\\"b\\nc\\x01\"\n")
    }
}
