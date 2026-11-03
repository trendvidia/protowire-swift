// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
@testable import Protowire

/// Rules the spec corpus does not pin token by token. The duration table is
/// protowire-go's `TestLexDurationFractionalAndMicro`.
final class PXFSyntaxTests: XCTestCase {
    private func tokens(_ input: String) -> [(PXF.TokenKind, String)] {
        let lexer = PXF.Lexer(string: input)
        var out: [(PXF.TokenKind, String)] = []
        for _ in 0..<64 {
            let t = lexer.next()
            if t.kind == .eof { return out }
            out.append((t.kind, t.value))
        }
        XCTFail("no EOF within 64 tokens on \(input)")
        return out
    }

    private func parse(_ input: String) throws -> PXF.Document {
        try PXF.Parser(string: input).parseDocument()
    }

    func testDurationTokenTable() {
        let cases: [(String, [(PXF.TokenKind, String)])] = [
            // Draft §3.10 examples.
            ("30s", [(.duration, "30s")]),
            ("1h30m", [(.duration, "1h30m")]),
            ("500ms", [(.duration, "500ms")]),
            ("1.5h", [(.duration, "1.5h")]),
            ("2µs", [(.duration, "2µs")]),
            ("2us", [(.duration, "2us")]),
            // What time.Duration.String() writes for measured values.
            ("1.234567ms", [(.duration, "1.234567ms")]),
            ("1.5ms", [(.duration, "1.5ms")]),
            ("312.5µs", [(.duration, "312.5µs")]),
            ("1.234µs", [(.duration, "1.234µs")]),
            ("1h30m0.5s", [(.duration, "1h30m0.5s")]),
            ("-1.5s", [(.duration, "-1.5s")]),
            ("-312.5µs", [(.duration, "-312.5µs")]),
            ("0s", [(.duration, "0s")]),
            // Every unit, fractional.
            ("1.5ns", [(.duration, "1.5ns")]),
            ("1.5us", [(.duration, "1.5us")]),
            ("1.5µs", [(.duration, "1.5µs")]),
            ("1.5s", [(.duration, "1.5s")]),
            ("1.5m", [(.duration, "1.5m")]),
            // A fraction in any segment.
            ("1h30.5m", [(.duration, "1h30.5m")]),
            ("1.5h30.5m1.5s", [(.duration, "1.5h30.5m1.5s")]),
            ("1h30m500ms", [(.duration, "1h30m500ms")]),
            ("1ms234us567ns", [(.duration, "1ms234us567ns")]),
            ("250ms", [(.duration, "250ms")]),
            // A float when no unit follows.
            ("1.5", [(.float, "1.5")]),
            ("1.5e3", [(.float, "1.5e3")]),
            ("1.5E-3", [(.float, "1.5E-3")]),
            ("-1.5", [(.float, "-1.5")]),
            ("1.", [(.float, "1.")]),
            ("1.e3", [(.float, "1.e3")]),
            // An exponent is not a unit.
            ("1.5e3ms", [(.float, "1.5e3"), (.identifier, "ms")]),
            ("1e3s", [(.float, "1e3"), (.identifier, "s")]),
            // No digit after the "." is not a duration-segment.
            ("1.ms", [(.float, "1."), (.identifier, "ms")]),
            // A non-unit letter is an identifier after the number.
            ("1.5x", [(.float, "1.5"), (.identifier, "x")]),
            ("1.5 x", [(.float, "1.5"), (.identifier, "x")]),
            ("5x", [(.number, "5"), (.identifier, "x")]),
            // A unit letter that starts a longer word fails as one duration.
            ("1.5min", [(.error, "invalid duration: 1.5min")]),
            ("5min", [(.error, "invalid duration: 5min")]),
            // Only U+00B5 is micro-us. U+03BC is not in the grammar.
            ("2μs", [(.number, "2"), (.error, "unexpected character 'μ'"), (.identifier, "s")]),
            ("2µ", [(.error, "invalid duration: 2µ")]),
            ("2µm", [(.error, "invalid duration: 2µm")]),
            // The token ends where the value ends.
            ("1.5ms,", [(.duration, "1.5ms"), (.comma, ",")]),
            ("1.5ms]", [(.duration, "1.5ms"), (.rbracket, "]")]),
            ("1.5ms}", [(.duration, "1.5ms"), (.rbrace, "}")]),
            ("1.5ms#c", [(.duration, "1.5ms"), (.comment, "#c")]),
            ("1.5ms\n", [(.duration, "1.5ms"), (.newline, "\n")]),
            ("2µs 3", [(.duration, "2µs"), (.number, "3")]),
        ]
        XCTAssertEqual(cases.count, 47)
        for (input, want) in cases {
            let got = tokens(input)
            XCTAssertEqual(got.count, want.count, "\(input): \(got)")
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.0, w.0, input)
                XCTAssertEqual(g.1, w.1, input)
            }
        }
    }

    func testDurationPastSixtyFourBitNanosecondsIsRejected() {
        XCTAssertEqual(tokens("2562047h").first?.0, .duration)
        XCTAssertEqual(tokens("2562048h").first?.0, .error)
    }

    func testPrecisionSuffixStaysOnTheLiteral() throws {
        XCTAssertEqual(tokens("1.5p53").first?.0, .float)
        XCTAssertEqual(tokens("1.5p53").first?.1, "1.5p53")
        XCTAssertEqual(tokens("7p64").first?.0, .number)
        XCTAssertEqual(tokens("7p64").first?.1, "7p64")
        XCTAssertEqual(tokens("1e3p8").first?.1, "1e3p8")
        // No digit after the p: an identifier.
        let bare = tokens("7p")
        XCTAssertEqual(bare.count, 2)
        XCTAssertEqual(bare[0].1, "7")
        XCTAssertEqual(bare[1].1, "p")
        // A key takes no suffix.
        XCTAssertThrowsError(try parse("m { 1p8: \"x\" }"))
    }

    func testSignedLiterals() {
        XCTAssertEqual(tokens("+inf").first?.0, .float)
        XCTAssertEqual(tokens("-inf").first?.0, .float)
        XCTAssertEqual(tokens("+1").first?.0, .error)
        XCTAssertEqual(tokens("-x").first?.0, .error)
        XCTAssertEqual(tokens("-info").first?.0, .error)
    }

    func testRawLineFeedInASimpleString() throws {
        XCTAssertThrowsError(try parse("s = \"x\ny\""))
        XCTAssertNoThrow(try parse(#"s = "x\ny""#))
        // A dataset cell is a value like any other.
        XCTAssertThrowsError(try parse("@dataset a.B (x)\n(\"x\ny\")\n"))
    }

    func testTripleQuotedDedent() {
        func value(_ s: String) -> String? { tokens(s).first?.1 }
        XCTAssertEqual(value("\"\"\"\n  x\n  y\n  \"\"\""), "x\ny")
        // Closing quotes on a text line: nothing is stripped.
        XCTAssertEqual(value("\"\"\"\n  x\n  y\"\"\""), "  x\n  y")
        // A line short of the indent keeps what it has.
        XCTAssertEqual(value("\"\"\"\n    x\n  y\n    \"\"\""), "x\n  y")
        XCTAssertEqual(value("\"\"\"é\"\"\""), "é")
        XCTAssertEqual(value("\"\"\"\"\"\""), "")
        XCTAssertEqual(tokens("\"\"\"open").first?.0, .error)
    }

    func testUnterminatedLiteralsAreErrors() {
        XCTAssertEqual(tokens("/* open").first?.0, .error)
        XCTAssertEqual(tokens("b\"open").first?.0, .error)
        XCTAssertEqual(tokens("b\"ab\ncd\"").first?.0, .error)
    }

    func testBytesAlphabets() throws {
        func bytes(_ b64: String) throws -> Data? {
            ((try parse("b = b\"\(b64)\"").entries.first as? PXF.Assignment)?.value as? PXF.BytesVal)?.value
        }
        XCTAssertEqual(try bytes("+/+/"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(try bytes("-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(try bytes("QQ=="), Data([0x41]))
        XCTAssertEqual(try bytes("QQ"), Data([0x41]))
        XCTAssertThrowsError(try bytes("+_"))
        XCTAssertThrowsError(try bytes("Q"))
    }

    func testCommentKeepsItsBytes() throws {
        let doc = try parse("# café\n/* naïve */\nx = 1 # trailing é\ny = 2\n")
        XCTAssertEqual(doc.leadingComments.map(\.text), ["# café", "/* naïve */"])
        XCTAssertEqual((doc.entries[0] as? PXF.Assignment)?.trailingComment, "# trailing é")
        XCTAssertEqual(doc.entries[1].leadingComments, [])
    }

    // MARK: - Type entries

    private func firstBlock(_ input: String) throws -> PXF.BlockVal? {
        (try parse(input).entries.first as? PXF.Assignment)?.value as? PXF.BlockVal
    }

    func testTypeEntryIsKeptOutOfEntries() throws {
        let bare = try parse("p {\n  @type = \"t/a.B\"\n  x = 1\n}").entries.first as? PXF.Block
        XCTAssertEqual(bare?.typeURL, "t/a.B")
        XCTAssertEqual(bare?.entries.count, 1)

        let assigned = try firstBlock("p = {\n  @type = \"t/a.B\"\n}")
        XCTAssertEqual(assigned?.typeURL, "t/a.B")
        XCTAssertEqual(assigned?.entries.count, 0)

        let list = (try parse("l = [{ @type = \"a\" }, { x = 1 }]").entries.first as? PXF.Assignment)?.value as? PXF.ListVal
        XCTAssertEqual((list?.elements[0] as? PXF.BlockVal)?.typeURL, "a")
        XCTAssertNil((list?.elements[1] as? PXF.BlockVal)?.typeURL)

        let map = try firstBlock("m = { k: { @type = \"a\" } }")
        XCTAssertEqual(((map?.entries.first as? PXF.MapEntry)?.value as? PXF.BlockVal)?.typeURL, "a")
    }

    func testTypeEntryOutOfPlace() {
        XCTAssertThrowsError(try parse("p { x = 1 @type = \"a\" }"))
        XCTAssertThrowsError(try parse("p { @type = \"a\" @type = \"b\" }"))
        XCTAssertThrowsError(try parse("p { @type = a }"))
        XCTAssertThrowsError(try parse("x = 1\n@type = \"a\""))
        // The form the spec never had.
        XCTAssertThrowsError(try parse("p = @type a.B { x = 1 }"))
    }

    // MARK: - Map keys

    func testMapKeyRemembersItsToken() throws {
        let block = try firstBlock("m = { a: 1 \"b\": 2 3: 3 -4: 4 true: 5 false: 6 }")
        let got = block?.entries.compactMap { ($0 as? PXF.MapEntry).map { [$0.key, $0.keyKind.rawValue] } }
        XCTAssertEqual(got, [
            ["a", "IDENTIFIER"], ["b", "STRING"], ["3", "NUMBER"], ["-4", "NUMBER"], ["true", "BOOL"], ["false", "BOOL"],
        ])
    }

    func testBoolAndIntegerKeysTakeOnlyTheColonTail() {
        for input in ["m { true = 1 }", "m { true { } }", "m { 1 = 1 }", "m { 1 { } }"] {
            XCTAssertThrowsError(try parse(input), input)
        }
    }

    // MARK: - Dataset headers and cells

    func testColumnPathRules() {
        func error(_ columns: String) -> String? {
            do {
                _ = try parse("@dataset a.B (\(columns))\n")
                return nil
            } catch {
                return "\(error)"
            }
        }
        XCTAssertNil(error("a, b.c, b.d, ab, abc.d"))
        XCTAssertEqual(error("a, b, a"), #"[1:21] @dataset column "a" appears twice (draft §3.4.4)"#)
        XCTAssertEqual(error("a.b, a"), #"[1:20] @dataset column "a" overlaps column "a.b": a field and a path inside it cannot both be columns (draft §3.4.4)"#)
        XCTAssertEqual(error("a, a.b.c"), #"[1:18] @dataset column "a.b.c" overlaps column "a": a field and a path inside it cannot both be columns (draft §3.4.4)"#)
        XCTAssertEqual(error("a..b"), #"[1:15] @dataset column "a..b": a column path has an empty segment (draft §3.4.4)"#)
        XCTAssertEqual(error("a."), #"[1:15] @dataset column "a.": a column path has an empty segment (draft §3.4.4)"#)
    }

    func testCellsHoldAnyValue() throws {
        let doc = try parse("@dataset a.B (x, y, z)\n([1, 2], { n = 1 }, )\n")
        let cells = try XCTUnwrap(doc.datasets.first?.rows.first?.cells)
        XCTAssertTrue(cells[0]?.value is PXF.ListVal)
        XCTAssertTrue(cells[1]?.value is PXF.BlockVal)
        XCTAssertNil(cells[2])
    }
}
