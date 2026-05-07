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
        private let input: Data
        private var pos: Int = 0
        private var line: Int = 1
        private var col: Int = 1

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

            if isDigit(ch) || ch == 45 { // 0-9, -
                return lexNumber(startPos)
            }
            if isIdentifierStart(ch) {
                return lexIdentifierOrKeyword(startPos)
            }

            advance()
            return Token(kind: .error, value: "unexpected character: \(UnicodeScalar(ch))", pos: startPos)
        }

        private func lexLineComment(_ pos: Position) -> Token {
            var val = ""
            while self.pos < input.count && peek() != 10 {
                val.append(Character(UnicodeScalar(advance())))
            }
            return Token(kind: .comment, value: val, pos: pos)
        }

        private func lexBlockComment(_ pos: Position) -> Token {
            var val = ""
            advance() // /
            advance() // *
            while self.pos < input.count {
                if peek() == 42 && peekAt(1) == 47 { // */
                    advance()
                    advance()
                    break
                }
                val.append(Character(UnicodeScalar(advance())))
            }
            return Token(kind: .comment, value: val, pos: pos)
        }

        private func lexString(_ pos: Position) -> Token {
            advance() // "
            var bytes: [UInt8] = []
            while self.pos < input.count {
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
            var val = ""
            while self.pos < input.count {
                if peek() == 34 && peekAt(1) == 34 && peekAt(2) == 34 {
                    advance()
                    advance()
                    advance()
                    break
                }
                val.append(Character(UnicodeScalar(advance())))
            }
            return Token(kind: .string, value: val, pos: pos)
        }

        private func lexBytes(_ pos: Position) -> Token {
            advance() // b
            advance() // "
            var val = ""
            while self.pos < input.count {
                let ch = peek()
                if ch == 34 { // "
                    advance()
                    break
                }
                val.append(Character(UnicodeScalar(advance())))
            }
            return Token(kind: .bytes, value: val, pos: pos)
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
            if name == "type" {
                return Token(kind: .atType, value: "@type", pos: pos)
            }
            return Token(kind: .error, value: "unknown directive: @\(name)", pos: pos)
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
            if peek() == 45 { // -
                neg = true
                advance()
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

            // Float
            if peek() == 46 || peek() == 101 || peek() == 69 { // . or e or E
                return lexFloat(pos, startIdx)
            }

            // Duration
            if isDurationUnit(peek()) {
                return lexDuration(pos, startIdx)
            }

            let val = String(data: input.subdata(in: startIdx..<self.pos), encoding: .utf8) ?? ""
            return Token(kind: .number, value: val, pos: pos)
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
            let val = String(data: input.subdata(in: start..<self.pos), encoding: .utf8) ?? ""
            return Token(kind: .float, value: val, pos: pos)
        }

        private func lexTimestamp(_ pos: Position, _ start: Int) -> Token {
            while self.pos < input.count {
                let ch = peek()
                if ch == 32 || ch == 10 || ch == 9 || ch == 13 || ch == 44 || ch == 93 || ch == 125 || ch == 35 { // space, \n, tab, \r, comma, ], }, #
                    break
                }
                if ch == 47 && (peekAt(1) == 47 || peekAt(1) == 42) { // / followed by / or *
                    break
                }
                advance()
            }
            let val = String(data: input.subdata(in: start..<self.pos), encoding: .utf8) ?? ""
            return Token(kind: .timestamp, value: val, pos: pos)
        }

        private func lexDuration(_ pos: Position, _ start: Int) -> Token {
            while self.pos < input.count && (isDigit(peek()) || isLowerAlpha(peek())) {
                advance()
            }
            let val = String(data: input.subdata(in: start..<self.pos), encoding: .utf8) ?? ""
            return Token(kind: .duration, value: val, pos: pos)
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
