import XCTest
@testable import Protowire

/// Coverage for the full Go-aligned PXF escape set in the lexer, plus the
/// matching `PXFEncoder.quote` round-trip.
final class PXFLexerTests: XCTestCase {

    // MARK: - Escape set in lexString

    func testEscape_simpleEscapes() {
        // \" \\ \' \?  → " \ ' ?
        let lex = PXF.Lexer(string: #""\"\\\'\?""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .string)
        XCTAssertEqual(t.value, "\"\\'?")
    }

    func testEscape_letterEscapes() {
        // \a \b \f \v \n \r \t  → 0x07 0x08 0x0C 0x0B \n \r \t
        let lex = PXF.Lexer(string: #""\a\b\f\v\n\r\t""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .string)
        let bytes = Array(t.value.utf8)
        XCTAssertEqual(bytes, [0x07, 0x08, 0x0C, 0x0B, 0x0A, 0x0D, 0x09])
    }

    func testEscape_hexByte() {
        let lex = PXF.Lexer(string: #""\x41\x7f""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .string)
        XCTAssertEqual(t.value, "A\u{7F}")
    }

    func testEscape_hexByte_invalid() {
        let lex = PXF.Lexer(string: #""\xZZ""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .error)
        XCTAssertTrue(t.value.contains(#"\x"#))
    }

    func testEscape_octal() {
        // \101 = 0x41 = 'A', \040 = ' '
        let lex = PXF.Lexer(string: #""\101\040""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .string)
        XCTAssertEqual(t.value, "A ")
    }

    func testEscape_octal_invalid() {
        // Leading digit > 3 isn't accepted as octal escape
        let lex = PXF.Lexer(string: #""\401""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .error)
    }

    func testEscape_uHex4() {
        // é → é
        let lex = PXF.Lexer(string: #""é""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .string)
        XCTAssertEqual(t.value, "é")
    }

    func testEscape_UHex8() {
        // \U0001f600 → 😀
        let lex = PXF.Lexer(string: #""\U0001f600""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .string)
        XCTAssertEqual(t.value, "😀")
    }

    func testEscape_uHex4_invalid() {
        let lex = PXF.Lexer(string: #""\u12""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .error)
    }

    func testEscape_unknown() {
        let lex = PXF.Lexer(string: #""\q""#)
        let t = lex.next()
        XCTAssertEqual(t.kind, .error)
        XCTAssertTrue(t.value.contains("unknown escape"))
    }

    func testEscape_unterminatedAtBackslash() {
        let lex = PXF.Lexer(string: "\"\\")
        let t = lex.next()
        XCTAssertEqual(t.kind, .error)
        XCTAssertTrue(t.value.contains("unterminated"))
    }

    // MARK: - Encoder quote helper

    func testQuote_basic() {
        XCTAssertEqual(PXFEncoder.quote("hello"), #""hello""#)
    }

    func testQuote_specials() {
        // \" \\ \n \r \t plus a control byte → \xHH
        let s = "a\"b\\c\nd\re\tf\u{01}g"
        let q = PXFEncoder.quote(s)
        XCTAssertEqual(q, #""a\"b\\c\nd\re\tf\x01g""#)
    }

    func testQuote_unicodePassesThrough() {
        // UTF-8 bytes >= 0x20 pass through literally.
        XCTAssertEqual(PXFEncoder.quote("héllo"), #""héllo""#)
    }

    func testQuote_lexer_roundTrip() {
        // Quote → lex → original.
        let original = "tab\there\n\"quoted\"\\back\u{02}low"
        let quoted = PXFEncoder.quote(original)
        let t = PXF.Lexer(string: quoted).next()
        XCTAssertEqual(t.kind, .string)
        XCTAssertEqual(t.value, original)
    }

    // MARK: - Duration parser

    func testDuration_simple() {
        XCTAssertEqual(PXF.Parser.parseDuration("5s"), 5)
        XCTAssertEqual(PXF.Parser.parseDuration("300ms"), 0.3)
        XCTAssertEqual(PXF.Parser.parseDuration("1h"), 3600)
    }

    func testDuration_mixed() {
        XCTAssertEqual(PXF.Parser.parseDuration("1h30m"), 5400)
        XCTAssertEqual(PXF.Parser.parseDuration("2h45m30s"), 9930)
    }

    func testDuration_signed() {
        XCTAssertEqual(PXF.Parser.parseDuration("-1.5h"), -5400)
        XCTAssertEqual(PXF.Parser.parseDuration("+30s"), 30)
    }

    func testDuration_fractional() {
        if let d = PXF.Parser.parseDuration("1.5s") {
            XCTAssertEqual(d, 1.5, accuracy: 1e-9)
        } else { XCTFail("parseDuration returned nil") }
    }

    func testDuration_micro() {
        if let a = PXF.Parser.parseDuration("100us") { XCTAssertEqual(a, 1e-4, accuracy: 1e-12) }
        else { XCTFail("nil for 100us") }
        if let b = PXF.Parser.parseDuration("100µs") { XCTAssertEqual(b, 1e-4, accuracy: 1e-12) }
        else { XCTFail("nil for 100µs") }
    }

    func testDuration_zero() {
        XCTAssertEqual(PXF.Parser.parseDuration("0"), 0)
    }

    func testDuration_invalid() {
        XCTAssertNil(PXF.Parser.parseDuration(""))
        XCTAssertNil(PXF.Parser.parseDuration("abc"))
        XCTAssertNil(PXF.Parser.parseDuration("5x"))     // bad unit
        XCTAssertNil(PXF.Parser.parseDuration("h"))      // missing number
        XCTAssertNil(PXF.Parser.parseDuration("5"))      // missing unit (and not the special "0")
    }
}
