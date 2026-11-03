// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
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

    func testQuote_matchesGoPercentQ() {
        XCTAssertEqual(PXF.Format.quote("\u{07}\u{08}\u{0C}\u{0B}"), #""\a\b\f\v""#)
        XCTAssertEqual(PXF.Format.quote("\u{7F}\u{01}"), #""\x7f\x01""#)
        XCTAssertEqual(PXF.Format.quote("é µ 😀"), "\"é µ 😀\"")
        XCTAssertEqual(PXF.Format.quote("\u{A0}\u{FEFF}"), #""\u00a0\ufeff""#)
        XCTAssertEqual(PXF.Format.quote("\u{E0000}"), #""\U000e0000""#)
    }

    func testTrailingCommentAndTypeEntry() throws {
        let input = """
        p {
          # about the type
          @type = "t/a.B" # the type
          x = 1 # the value
        }

        """
        let doc = try PXF.Parser(string: input).parseDocument()
        XCTAssertEqual(PXF.Format.formatDocument(doc), input)
    }

    func testMapKeySpelling() throws {
        func format(_ key: String) throws -> String {
            let doc = try PXF.Parser(string: "m = { \(key): 1 }").parseDocument()
            return PXF.Format.formatDocument(doc)
        }
        XCTAssertEqual(try format(#""true""#), "m = {\n  \"true\": 1\n}\n")
        XCTAssertEqual(try format("true"), "m = {\n  true: 1\n}\n")
        XCTAssertEqual(try format(#""null""#), "m = {\n  \"null\": 1\n}\n")
        XCTAssertEqual(try format(#""123""#), "m = {\n  \"123\": 1\n}\n")
        XCTAssertEqual(try format("123"), "m = {\n  123: 1\n}\n")
        XCTAssertEqual(try format(#""a.b""#), "m = {\n  a.b: 1\n}\n")
        XCTAssertEqual(try format(#"".e""#), "m = {\n  \".e\": 1\n}\n")
        XCTAssertEqual(try format(#""1.5""#), "m = {\n  \"1.5\": 1\n}\n")
    }

    func testEntryBuiltInCodeIsQuotedWhenItMustBe() {
        func format(_ key: String) -> String {
            let at = PXF.Position(line: 1, column: 1)
            let entry = PXF.MapEntry(pos: at, key: key, value: PXF.IntVal(pos: at, raw: "1"), leadingComments: [])
            var doc = PXF.Document()
            doc.entries = [PXF.Assignment(pos: at, key: "m", value: PXF.BlockVal(pos: at, entries: [entry]), leadingComments: [])]
            return PXF.Format.formatDocument(doc)
        }
        XCTAssertEqual(format("my key"), "m = {\n  \"my key\": 1\n}\n")
        XCTAssertEqual(format(""), "m = {\n  \"\": 1\n}\n")
        XCTAssertEqual(format("null"), "m = {\n  \"null\": 1\n}\n")
        XCTAssertEqual(format("a"), "m = {\n  a: 1\n}\n")
    }

    /// The spec's spelling pairs (protowire#306, #313): the input formats to
    /// the expected file, which is a fixed point, and both bind to the same
    /// string keys.
    private struct Labels: Decodable {
        var by_label: [String: String]
    }

    private func corpus(_ name: String) throws -> String {
        let url = Bundle.module.resourceURL!.appendingPathComponent("testdata/conformance/corpus/map-keys/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSpecSpellingPairs() throws {
        let cases: [(String, Set<String>)] = [
            ("fmt-keyword-keys", ["true", "false", "null", "123", "bare", "plain"]),
            ("fmt-dotted-keys", ["a.b", "c.d", ".e", "1.5"]),
        ]
        for (name, keys) in cases {
            let input = try corpus("\(name).pxf")
            let expected = try corpus("\(name).expected.pxf")
            let formatted = PXF.Format.formatDocument(try PXF.Parser(string: input).parseDocument())
            XCTAssertEqual(formatted, expected, name)
            XCTAssertEqual(PXF.Format.formatDocument(try PXF.Parser(string: expected).parseDocument()), expected, name)
            for text in [input, expected] {
                XCTAssertEqual(Set(try PXFDecoder().decode(Labels.self, from: text).by_label.keys), keys, name)
            }
        }
    }

    func testMarshallerSpellsKeysAsTheFormatterDoes() throws {
        struct Holder: Encodable {
            var by_label: [String: Int32]
        }
        let keys = ["true", "false", "null", "123", "plain", "a.b", ".e", "1.5", "my key"]
        let text = try PXFEncoder().encode(Holder(by_label: Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) })))
        let formatted = PXF.Format.formatDocument(try PXF.Parser(string: text).parseDocument())
        for line in ["\"true\": 1", "\"false\": 1", "\"null\": 1", "\"123\": 1", "plain: 1", "a.b: 1", "\".e\": 1", "\"1.5\": 1", "\"my key\": 1"] {
            XCTAssertTrue(text.contains(line), "\(line) in\n\(text)")
            XCTAssertTrue(formatted.contains(line), "\(line) in\n\(formatted)")
        }
    }
}
