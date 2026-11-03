// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// A namespace for PXF (Protowire Exchange Format) related types and utilities.
public enum PXF {
    /// Represents the different kinds of tokens that can be encountered during PXF lexing.
    public enum TokenKind: String {
        /// An error token.
        case error = "ERROR"
        /// End of file token.
        case eof = "EOF"
        /// Newline token.
        case newline = "NEWLINE"
        /// Comment token.
        case comment = "COMMENT"
        
        /// An identifier token.
        case identifier = "IDENTIFIER"
        /// A string literal token.
        case string = "STRING"
        /// A number literal token.
        case number = "NUMBER"
        /// A float literal token.
        case float = "FLOAT"
        /// A bytes literal token.
        case bytes = "BYTES"
        /// A boolean literal token.
        case bool = "BOOL"
        /// A null literal token.
        case null = "NULL"
        /// A timestamp literal token.
        case timestamp = "TIMESTAMP"
        /// A duration literal token.
        case duration = "DURATION"
        
        /// The '=' character.
        case equal = "="
        /// The '{' character.
        case lbrace = "{"
        /// The '}' character.
        case rbrace = "}"
        /// The '[' character.
        case lbracket = "["
        /// The ']' character.
        case rbracket = "]"
        /// The '(' character.
        case lparen = "("
        /// The ')' character.
        case rparen = ")"
        /// The ':' character.
        case colon = ":"
        /// The ',' character.
        case comma = ","
        /// The '.' character.
        case dot = "."
        /// The '@' character.
        case at = "@"
        /// The '@type' directive.
        case atType = "@type"
        /// The '@dataset' directive (draft §3.4.4).
        case atDataset = "@dataset"
        /// The '@proto' directive (draft §3.4.5).
        case atProto = "@proto"
        /// A generic '@<name>' directive (draft §3.4.2). `value` carries the bare name (no leading `@`).
        case atDirective = "@<name>"
    }

    /// A token produced by the PXF lexer.
    public struct Token {
        /// The kind of the token.
        public var kind: TokenKind
        /// The literal value of the token.
        public var value: String
        /// The position of the token in the input.
        public var pos: Position
    }

    /// A lexer that scans PXF input and produces tokens.
    public final class Lexer {
        /// Raw input bytes; exposed so the parser can slice raw body
        /// content out of <c>{ ... }</c>-bounded directives without
        /// re-lexing it as PXF.
        internal let input: Data
        internal private(set) var pos: Int = 0
        /// The line and column the scanner is at.
        internal var position: Position { Position(line: line, column: col) }
        private var line: Int = 1
        private var col: Int = 1

        /// Opaque lexer state used for one-token lookahead.
        internal struct State {
            let pos: Int
            let line: Int
            let col: Int
        }

        internal func save() -> State { State(pos: pos, line: line, col: col) }
        internal func restore(_ s: State) { pos = s.pos; line = s.line; col = s.col }

        /// Repositions the scanner to absolute offset `target`. Used by
        /// `parseProtoDirective` after slicing a brace-bounded body out
        /// of the input directly: the interior is protobuf source rather
        /// than PXF. Walks the input one byte at a time so line/col stay
        /// accurate.
        internal func repositionTo(_ target: Int) {
            precondition(target >= pos, "lexer cannot reposition backwards")
            while pos < target && pos < input.count {
                advance()
            }
        }

        /// Initializes a new `Lexer` with the given input data.
        /// - Parameter input: The data to lex.
        public init(input: Data) {
            self.input = input
        }

        /// Initializes a new `Lexer` with the given input string.
        /// - Parameter string: The string to lex.
        public convenience init(string: String) {
            self.init(input: string.data(using: .utf8) ?? Data())
        }

        private func peek() -> UInt8 {
            guard pos < input.count else { return 0 }
            return input[pos]
        }

        private func peekAt(_ offset: Int) -> UInt8 {
            let i = pos + offset
            guard i < input.count else { return 0 }
            return input[i]
        }

        @discardableResult
        private func advance() -> UInt8 {
            guard pos < input.count else { return 0 }
            let ch = input[pos]
            pos += 1
            if ch == 10 { // \n
                line += 1
                col = 1
            } else {
                col += 1
            }
            return ch
        }

        private var currentPos: Position {
            Position(line: line, column: col)
        }

        private func skipSpaces() {
            while pos < input.count {
                let ch = input[pos]
                if ch == 32 || ch == 9 || ch == 13 { // space, tab, \r
                    advance()
                } else {
                    break
                }
            }
        }

        /// Returns the next token from the input.
        /// - Returns: The next `Token`.
        public func next() -> Token {
            skipSpaces()
            if pos >= input.count {
                return Token(kind: .eof, value: "", pos: currentPos)
            }

            let startPos = currentPos
            let ch = peek()

            switch ch {
            case 10: // \n
                advance()
                return Token(kind: .newline, value: "\n", pos: startPos)
            case 35: // #
                return lexLineComment(startPos)
            case 47: // /
                if peekAt(1) == 47 { // //
                    return lexLineComment(startPos)
                } else if peekAt(1) == 42 { // /*
                    return lexBlockComment(startPos)
                }
            case 34: // "
                if peekAt(1) == 34 && peekAt(2) == 34 { // """
                    return lexTripleString(startPos)
                }
                return lexString(startPos)
            case 98: // b
                if peekAt(1) == 34 { // b"
                    return lexBytes(startPos)
                }
            case 123: // {
                advance()
                return Token(kind: .lbrace, value: "{", pos: startPos)
            case 125: // }
                advance()
                return Token(kind: .rbrace, value: "}", pos: startPos)
            case 91: // [
                advance()
                return Token(kind: .lbracket, value: "[", pos: startPos)
            case 93: // ]
                advance()
                return Token(kind: .rbracket, value: "]", pos: startPos)
            case 40: // (
                advance()
                return Token(kind: .lparen, value: "(", pos: startPos)
            case 41: // )
                advance()
                return Token(kind: .rparen, value: ")", pos: startPos)
            case 61: // =
                advance()
                return Token(kind: .equal, value: "=", pos: startPos)
            case 58: // :
                advance()
                return Token(kind: .colon, value: ":", pos: startPos)
            case 44: // ,
                advance()
                return Token(kind: .comma, value: ",", pos: startPos)
            case 46: // .
                advance()
                return Token(kind: .dot, value: ".", pos: startPos)
            case 64: // @
                return lexDirective(startPos)
            default:
                break
            }

            if isDigit(ch) || ch == 45 || ch == 43 { // 0-9, -, +
                return lexNumber(startPos)
            }
            if isIdentifierStart(ch) {
                return lexIdentifierOrKeyword(startPos)
            }

            return lexIllegalRune(startPos)
        }

        /// Consumes the character no token can start with and names it, as
        /// one diagnostic for a multi-byte character rather than one per
        /// byte. An invalid encoding names its lead byte.
        private func lexIllegalRune(_ pos: Position) -> Token {
            let lead = peek()
            let size = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if self.pos + size <= input.count,
               let text = String(data: input.subdata(in: self.pos..<(self.pos + size)), encoding: .utf8) {
                for _ in 0..<size { advance() }
                return Token(kind: .error, value: "unexpected character '\(text)'", pos: pos)
            }
            advance()
            return Token(kind: .error, value: "unexpected byte 0x" + String(lead, radix: 16), pos: pos)
        }

        private func text(_ start: Int, _ end: Int) -> String {
            String(decoding: input.subdata(in: start..<end), as: UTF8.self)
        }

        private func lexLineComment(_ pos: Position) -> Token {
            let start = self.pos
            while self.pos < input.count && peek() != 10 {
                advance()
            }
            return Token(kind: .comment, value: text(start, self.pos), pos: pos)
        }

        private func lexBlockComment(_ pos: Position) -> Token {
            let start = self.pos
            advance() // /
            advance() // *
            while self.pos + 1 < input.count {
                if peek() == 42 && peekAt(1) == 47 { // */
                    advance()
                    advance()
                    return Token(kind: .comment, value: text(start, self.pos), pos: pos)
                }
                advance()
            }
            return Token(kind: .error, value: "unterminated block comment", pos: pos)
        }

        private func lexString(_ pos: Position) -> Token {
            advance() // "
            var bytes: [UInt8] = []
            while self.pos < input.count {
                if peek() == 10 {
                    // A simple string holds no raw line feed (draft -01 §
                    // String Literals).
                    return Token(kind: .error, value: #"newline in string literal: write it as \n, or use a """triple-quoted""" string"#, pos: pos)
                }
                let ch = advance()
                if ch == 0x22 { // "
                    guard let val = String(data: Data(bytes), encoding: .utf8) else {
                        return Token(kind: .error, value: "invalid UTF-8 in string literal", pos: pos)
                    }
                    return Token(kind: .string, value: val, pos: pos)
                }
                if ch != 0x5C { // \
                    bytes.append(ch)
                    continue
                }
                if self.pos >= input.count {
                    return Token(kind: .error, value: "unterminated escape sequence", pos: pos)
                }
                let esc = advance()
                switch esc {
                case 0x22, 0x5C, 0x27, 0x3F: // " \ ' ?
                    bytes.append(esc)
                case 0x61: bytes.append(0x07) // \a
                case 0x62: bytes.append(0x08) // \b
                case 0x66: bytes.append(0x0C) // \f
                case 0x6E: bytes.append(0x0A) // \n
                case 0x72: bytes.append(0x0D) // \r
                case 0x74: bytes.append(0x09) // \t
                case 0x76: bytes.append(0x0B) // \v
                case 0x78: // \xHH
                    guard let b = readHexByte() else {
                        return Token(kind: .error, value: #"invalid \x escape: expected 2 hex digits"#, pos: pos)
                    }
                    bytes.append(b)
                case 0x30, 0x31, 0x32, 0x33: // \nnn (leading 0-3 keeps it within a byte)
                    guard let b = readOctRest(first: esc) else {
                        return Token(kind: .error, value: "invalid octal escape: expected 3 octal digits", pos: pos)
                    }
                    bytes.append(b)
                case 0x75: // \uHHHH
                    guard let scalar = readHexRune(4) else {
                        return Token(kind: .error, value: #"invalid \u escape: expected 4 hex digits forming a valid codepoint"#, pos: pos)
                    }
                    appendUTF8(scalar, to: &bytes)
                case 0x55: // \UHHHHHHHH
                    guard let scalar = readHexRune(8) else {
                        return Token(kind: .error, value: #"invalid \U escape: expected 8 hex digits forming a valid codepoint"#, pos: pos)
                    }
                    appendUTF8(scalar, to: &bytes)
                default:
                    let escStr = String(decoding: [esc], as: UTF8.self)
                    return Token(kind: .error, value: "unknown escape sequence \\\(escStr)", pos: pos)
                }
            }
            return Token(kind: .error, value: "unterminated string", pos: pos)
        }

        private func lexTripleString(_ pos: Position) -> Token {
            advance() // "
            advance() // "
            advance() // "
            let start = self.pos
            while self.pos + 2 < input.count {
                if peek() == 34 && peekAt(1) == 34 && peekAt(2) == 34 {
                    let raw = Array(input.subdata(in: start..<self.pos))
                    advance()
                    advance()
                    advance()
                    return Token(kind: .string, value: Lexer.dedent(raw), pos: pos)
                }
                advance()
            }
            return Token(kind: .error, value: "unterminated triple-quoted string", pos: pos)
        }

        /// A triple-quoted body: drops the line feed after the opening
        /// quotes and, when the closing quotes sit on a line of their own,
        /// that line, whose indent is stripped from every other line. Works
        /// on bytes because Swift treats CR LF as one `Character`.
        private static func dedent(_ raw: [UInt8]) -> String {
            var body = raw[...]
            if body.first == 10 { body = body.dropFirst() }
            var lines = body.split(separator: 10, omittingEmptySubsequences: false)
            if let last = lines.last,
               String(decoding: last, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let indent = Array(last)
                lines.removeLast()
                lines = lines.map { $0.starts(with: indent) ? $0.dropFirst(indent.count) : $0 }
            }
            return String(decoding: Array(lines.joined(separator: [10])), as: UTF8.self)
        }

        /// The longest `b"…"` body this lexer validates by decoding it; the
        /// parser refuses a longer one under `MaxBytesLiteralLength`.
        internal var maxBase64Length = Hardening.Limits().maxBase64Length

        private func lexBytes(_ pos: Position) -> Token {
            advance() // b
            advance() // "
            let start = self.pos
            while self.pos < input.count {
                let ch = peek()
                if ch == 34 { // "
                    let raw = text(start, self.pos)
                    advance()
                    // Past the limit the literal is refused from its length:
                    // decoding it first is the cost the limit exists to avoid.
                    guard raw.utf8.count > maxBase64Length || Lexer.decodeBase64(raw) != nil else {
                        return Token(kind: .error, value: "invalid base64 in bytes literal", pos: pos)
                    }
                    return Token(kind: .bytes, value: raw, pos: pos)
                }
                if ch == 10 {
                    return Token(kind: .error, value: "unterminated bytes literal", pos: pos)
                }
                advance()
            }
            return Token(kind: .error, value: "unterminated bytes literal", pos: pos)
        }

        /// Standard or URL-safe base64, with or without padding (RFC 4648
        /// § 5, draft §3.7). One literal uses one alphabet.
        static func decodeBase64(_ raw: String) -> Data? {
            let urlSafe = raw.contains("-") || raw.contains("_")
            if urlSafe && (raw.contains("+") || raw.contains("/")) { return nil }
            let stripped = raw.hasSuffix("==") ? raw.dropLast(2) : raw.hasSuffix("=") ? raw.dropLast(1) : raw[...]
            if stripped.count != raw.count && raw.count % 4 != 0 { return nil }
            if stripped.count % 4 == 1 { return nil }
            var std = String(stripped)
            if urlSafe {
                std = std.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            }
            std += String(repeating: "=", count: (4 - std.count % 4) % 4)
            return Data(base64Encoded: std)
        }

        // MARK: - Escape helpers

        /// Reads exactly two hex digits and returns the assembled byte.
        private func readHexByte() -> UInt8? {
            guard pos + 1 < input.count,
                  let hi = Self.hexVal(input[pos]),
                  let lo = Self.hexVal(input[pos + 1]) else {
                return nil
            }
            advance(); advance()
            return UInt8(hi << 4 | lo)
        }

        /// Reads exactly `n` hex digits and returns the assembled Unicode scalar.
        /// Validity (range, surrogates) is checked here.
        private func readHexRune(_ n: Int) -> Unicode.Scalar? {
            guard pos + n <= input.count else { return nil }
            var value: UInt32 = 0
            for _ in 0..<n {
                guard let v = Self.hexVal(input[pos]) else { return nil }
                value = value << 4 | UInt32(v)
                advance()
            }
            return Unicode.Scalar(value)
        }

        /// Reads two more octal digits after the leading one already consumed
        /// (\nnn — exactly 3 octal digits). The caller restricts `first` to 0-3
        /// so the resulting byte cannot overflow.
        private func readOctRest(first: UInt8) -> UInt8? {
            guard pos + 1 < input.count,
                  let d1 = Self.octVal(input[pos]),
                  let d2 = Self.octVal(input[pos + 1]) else {
                return nil
            }
            advance(); advance()
            return UInt8((Int(first) - 0x30) << 6 | d1 << 3 | d2)
        }

        private func appendUTF8(_ scalar: Unicode.Scalar, to bytes: inout [UInt8]) {
            for byte in String(scalar).utf8 {
                bytes.append(byte)
            }
        }

        private static func hexVal(_ ch: UInt8) -> Int? {
            switch ch {
            case 0x30...0x39: return Int(ch - 0x30)         // 0-9
            case 0x61...0x66: return Int(ch - 0x61) + 10    // a-f
            case 0x41...0x46: return Int(ch - 0x41) + 10    // A-F
            default: return nil
            }
        }

        private static func octVal(_ ch: UInt8) -> Int? {
            (ch >= 0x30 && ch <= 0x37) ? Int(ch - 0x30) : nil
        }

        private func lexDirective(_ pos: Position) -> Token {
            advance() // @
            var name = ""
            while self.pos < input.count && isIdentifierPart(peek()) {
                name.append(Character(UnicodeScalar(advance())))
            }
            if name.isEmpty {
                return Token(kind: .error, value: "bare '@' without directive name", pos: pos)
            }
            switch name {
            case "type":    return Token(kind: .atType,     value: "@type",    pos: pos)
            case "dataset": return Token(kind: .atDataset,  value: "@dataset", pos: pos)
            case "proto":   return Token(kind: .atProto,    value: "@proto",   pos: pos)
            default:        return Token(kind: .atDirective, value: name,       pos: pos)
            }
        }

        private func lexIdentifierOrKeyword(_ pos: Position) -> Token {
            var val = ""
            while self.pos < input.count && isIdentifierPart(peek()) {
                val.append(Character(UnicodeScalar(advance())))
            }
            if val == "true" || val == "false" {
                return Token(kind: .bool, value: val, pos: pos)
            }
            if val == "null" {
                return Token(kind: .null, value: val, pos: pos)
            }
            return Token(kind: .identifier, value: val, pos: pos)
        }

        private func lexNumber(_ pos: Position) -> Token {
            let startIdx = self.pos
            var neg = false
            let sign = peek()
            if sign == 45 || sign == 43 { // - or +
                advance()
                // +inf and -inf are the only signed identifier literals, and
                // a '+' is valid for nothing else.
                if hasIdent("inf") {
                    advance()
                    advance()
                    advance()
                    return Token(kind: .float, value: text(startIdx, self.pos), pos: pos)
                }
                if sign == 43 {
                    return Token(kind: .error, value: #""+" is valid only in "+inf""#, pos: pos)
                }
                if !isDigit(peek()) {
                    return Token(kind: .error, value: #""-" must be followed by a digit or "inf""#, pos: pos)
                }
                neg = true
            }

            let digitStart = self.pos
            while self.pos < input.count && isDigit(peek()) {
                advance()
            }
            let digitCount = self.pos - digitStart

            // Timestamp: 4 digits followed by '-'
            if !neg && digitCount == 4 && peek() == 45 {
                return lexTimestamp(pos, startIdx)
            }

            // A fraction needs a digit after the '.'. Floats and durations
            // both admit one, so it is consumed first and what follows tells
            // them apart: "1.5ms" is one duration, which is what every
            // port's marshaller writes for a measured latency.
            var fraction = false
            if peek() == 46 && isDigit(peekAt(1)) {
                fraction = true
                advance()
                while self.pos < input.count && isDigit(peek()) {
                    advance()
                }
            }

            if atDurationUnit() {
                return lexDuration(pos, startIdx)
            }

            if fraction || peek() == 46 || peek() == 101 || peek() == 69 { // . or e or E
                return lexFloat(pos, startIdx)
            }

            lexPrecision()
            return Token(kind: .number, value: text(startIdx, self.pos), pos: pos)
        }

        /// Consumes a number's precision suffix, `p` and one or more digits
        /// (draft -01 § PXF Annotations), so `IntVal.raw` and `FloatVal.raw`
        /// keep it. A `p` with no digit after it starts an identifier. Which
        /// fields may carry a suffix is the decoder's call.
        private func lexPrecision() {
            guard peek() == 112, isDigit(peekAt(1)) else { return } // p
            advance()
            while self.pos < input.count && isDigit(peek()) {
                advance()
            }
        }

        private func lexFloat(_ pos: Position, _ start: Int) -> Token {
            if peek() == 46 { // .
                advance()
                while self.pos < input.count && isDigit(peek()) {
                    advance()
                }
            }
            if peek() == 101 || peek() == 69 { // e or E
                advance()
                if peek() == 43 || peek() == 45 { // + or -
                    advance()
                }
                while self.pos < input.count && isDigit(peek()) {
                    advance()
                }
            }
            lexPrecision()
            return Token(kind: .float, value: text(start, self.pos), pos: pos)
        }

        private func lexTimestamp(_ pos: Position, _ start: Int) -> Token {
            while self.pos < input.count {
                let ch = peek()
                if ch == 32 || ch == 10 || ch == 9 || ch == 13 || ch == 44 || ch == 93 || ch == 125 || ch == 41 || ch == 35 { // space, \n, tab, \r, comma, ], }, ), #
                    break
                }
                if ch == 47 && (peekAt(1) == 47 || peekAt(1) == 42) { // / followed by / or *
                    break
                }
                advance()
            }
            return Token(kind: .timestamp, value: text(start, self.pos), pos: pos)
        }

        /// A time unit opens here: an ASCII unit letter, or U+00B5 MICRO
        /// SIGN. U+03BC GREEK SMALL LETTER MU is not in the grammar.
        private func atDurationUnit() -> Bool {
            guard self.pos < input.count else { return false }
            return isDurationUnit(peek()) || atMicroSign()
        }

        private func atMicroSign() -> Bool {
            peek() == 0xC2 && peekAt(1) == 0xB5
        }

        /// The scan is deliberately loose, so that `5min` is one invalid
        /// duration rather than a duration and an identifier.
        private func lexDuration(_ pos: Position, _ start: Int) -> Token {
            while self.pos < input.count {
                if isDigit(peek()) || isLowerAlpha(peek()) || (peek() == 46 && isDigit(peekAt(1))) {
                    advance()
                } else if atMicroSign() {
                    advance()
                    advance()
                } else {
                    break
                }
            }
            let raw = text(start, self.pos)
            guard Parser.parseDuration(raw) != nil else {
                return Token(kind: .error, value: "invalid duration: \(raw)", pos: pos)
            }
            return Token(kind: .duration, value: raw, pos: pos)
        }

        /// Whether the input here reads exactly `word`, not a prefix of a
        /// longer identifier. Does not advance.
        private func hasIdent(_ word: String) -> Bool {
            let bytes = Array(word.utf8)
            guard self.pos + bytes.count <= input.count else { return false }
            for (i, b) in bytes.enumerated() where peekAt(i) != b { return false }
            return self.pos + bytes.count == input.count || !isIdentifierPart(peekAt(bytes.count))
        }

        private func isIdentifierStart(_ ch: UInt8) -> Bool {
            return (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90) || ch == 95 // a-z, A-Z, _
        }

        private func isIdentifierPart(_ ch: UInt8) -> Bool {
            return isIdentifierStart(ch) || (ch >= 48 && ch <= 57) || ch == 46 // a-z, A-Z, _, 0-9, .
        }

        private func isDigit(_ ch: UInt8) -> Bool {
            return ch >= 48 && ch <= 57 // 0-9
        }

        private func isDurationUnit(_ ch: UInt8) -> Bool {
            return ch == 104 || ch == 109 || ch == 115 || ch == 110 || ch == 117 // h, m, s, n, u
        }

        private func isLowerAlpha(_ ch: UInt8) -> Bool {
            return ch >= 97 && ch <= 122 // a-z
        }
    }

    /// A protocol for resolving type URLs into concrete types.
    public protocol TypeResolver {
        /// Resolves a type URL into a `Decodable` type.
        /// - Parameter typeURL: The type URL to resolve.
        /// - Returns: The resolved type, or `nil` if it cannot be resolved.
        func resolve(typeURL: String) -> Decodable.Type?
    }
}
