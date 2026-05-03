import Foundation

extension PXF {
    /// Errors that can occur during PXF parsing.
    public enum ParserError: Error, CustomStringConvertible {
        /// An identifier was expected but another token was found.
        case expectedIdentifier(Position, got: TokenKind)
        /// A type URL was expected after `@type` but another token was found.
        case expectedTypeURL(Position, got: TokenKind)
        /// An entry delimiter ('=', ':', or '{') was expected.
        case expectedEntryDelimiter(Position, got: TokenKind)
        /// A value was expected.
        case expectedValue(Position, got: TokenKind)
        /// A closing bracket ']' was expected.
        case expectedClosingBracket(Position, got: TokenKind)
        /// A closing brace '}' was expected.
        case expectedClosingBrace(Position, got: TokenKind)
        /// Invalid base64 data was encountered in a bytes literal.
        case invalidBase64(Position, String)
        /// An invalid timestamp format was encountered.
        case invalidTimestamp(Position, String)
        /// An invalid duration format was encountered.
        case invalidDuration(Position, String)
        /// Unexpected end of file.
        case unexpectedEOF

        /// A localized description of the error.
        public var description: String {
            switch self {
            case .expectedIdentifier(let pos, let got): return "[\(pos)] expected identifier, got \(got.rawValue)"
            case .expectedTypeURL(let pos, let got): return "[\(pos)] expected type URL after @type, got \(got.rawValue)"
            case .expectedEntryDelimiter(let pos, let got): return "[\(pos)] expected '=', ':', or '{', got \(got.rawValue)"
            case .expectedValue(let pos, let got): return "[\(pos)] expected value, got \(got.rawValue)"
            case .expectedClosingBracket(let pos, let got): return "[\(pos)] expected ']', got \(got.rawValue)"
            case .expectedClosingBrace(let pos, let got): return "[\(pos)] expected '}', got \(got.rawValue)"
            case .invalidBase64(let pos, let err): return "[\(pos)] invalid base64: \(err)"
            case .invalidTimestamp(let pos, let val): return "[\(pos)] invalid timestamp: \(val)"
            case .invalidDuration(let pos, let val): return "[\(pos)] invalid duration: \(val)"
            case .unexpectedEOF: return "unexpected EOF"
            }
        }
    }

    /// A parser that transforms tokens into a PXF document AST.
    public final class Parser {
        private let lexer: Lexer
        private var current: Token
        private var comments: [Comment] = []

        /// Initializes a new `Parser` with the given input data.
        /// - Parameter input: The data to parse.
        public init(input: Data) {
            self.lexer = Lexer(input: input)
            self.current = Token(kind: .error, value: "", pos: Position(line: 0, column: 0))
            advance()
        }

        /// Initializes a new `Parser` with the given input string.
        /// - Parameter string: The string to parse.
        public convenience init(string: String) {
            self.init(input: string.data(using: .utf8) ?? Data())
        }

        private func advance() {
            while true {
                current = lexer.next()
                if current.kind == .newline { continue }
                if current.kind == .comment {
                    comments.append(Comment(pos: current.pos, text: current.value))
                    continue
                }
                break
            }
        }

        private func flushComments() -> [Comment] {
            let c = comments
            comments = []
            return c
        }

        /// Parses the entire input as a PXF document.
        /// - Returns: The parsed `Document`.
        /// - Throws: A `ParserError` if parsing fails.
        public func parseDocument() throws -> Document {
            var doc = Document(typeURL: nil, entries: [], leadingComments: flushComments())

            if current.kind == .atType {
                advance()
                if current.kind != .identifier {
                    throw ParserError.expectedTypeURL(current.pos, got: current.kind)
                }
                doc.typeURL = current.value
                advance()
            }

            while current.kind != .eof {
                doc.entries.append(try parseEntry())
            }

            return doc
        }

        private func parseEntry() throws -> Entry {
            let leading = flushComments()
            let pos = current.pos

            guard current.kind == .identifier || current.kind == .string || current.kind == .number else {
                throw ParserError.expectedIdentifier(pos, got: current.kind)
            }

            let key = current.value
            advance()

            switch current.kind {
            case .equal:
                advance()
                let val = try parseValue()
                return Assignment(pos: pos, key: key, value: val, leadingComments: leading)
            case .colon:
                advance()
                let val = try parseValue()
                return MapEntry(pos: pos, key: key, value: val, leadingComments: leading)
            case .lbrace:
                advance()
                let entries = try parseBody()
                return Block(pos: pos, name: key, entries: entries, leadingComments: leading)
            default:
                throw ParserError.expectedEntryDelimiter(current.pos, got: current.kind)
            }
        }

        private func parseValue() throws -> Value {
            let pos = current.pos

            var typeURL: String?
            if current.kind == .atType {
                advance()
                if current.kind != .identifier {
                    throw ParserError.expectedTypeURL(current.pos, got: current.kind)
                }
                typeURL = current.value
                advance()
            }

            switch current.kind {
            case .string:
                let v = StringVal(pos: pos, value: current.value)
                advance()
                return v
            case .number:
                let v = IntVal(pos: pos, raw: current.value)
                advance()
                return v
            case .float:
                let v = FloatVal(pos: pos, raw: current.value)
                advance()
                return v
            case .bool:
                let v = BoolVal(pos: pos, value: current.value == "true")
                advance()
                return v
            case .bytes:
                guard let data = Data(base64Encoded: current.value) else {
                    throw ParserError.invalidBase64(pos, current.value)
                }
                let v = BytesVal(pos: pos, value: data)
                advance()
                return v
            case .null:
                let v = NullVal(pos: pos)
                advance()
                return v
            case .timestamp:
                // Use ISO8601 parser
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let date = formatter.date(from: current.value) ?? ISO8601DateFormatter().date(from: current.value) else {
                    throw ParserError.invalidTimestamp(pos, current.value)
                }
                let v = TimestampVal(pos: pos, value: date, raw: current.value)
                advance()
                return v
            case .duration:
                guard let dur = Parser.parseDuration(current.value) else {
                    throw ParserError.invalidDuration(pos, current.value)
                }
                let v = DurationVal(pos: pos, value: dur, raw: current.value)
                advance()
                return v
            case .identifier:
                let v = IdentVal(pos: pos, name: current.value)
                advance()
                return v
            case .lbracket:
                return try parseList()
            case .lbrace:
                return try parseBlockVal(typeURL: typeURL)
            default:
                throw ParserError.expectedValue(pos, got: current.kind)
            }
        }

        private func parseList() throws -> Value {
            advance() // [
            var elements: [Value] = []
            while current.kind != .rbracket && current.kind != .eof {
                elements.append(try parseValue())
                if current.kind == .comma { advance() }
            }
            if current.kind != .rbracket { throw ParserError.expectedClosingBracket(current.pos, got: current.kind) }
            advance()
            return ListVal(pos: current.pos, elements: elements)
        }

        private func parseBlockVal(typeURL: String? = nil) throws -> Value {
            advance() // {
            let entries = try parseBody()
            return BlockVal(pos: current.pos, typeURL: typeURL, entries: entries)
        }

        private func parseBody() throws -> [Entry] {
            var entries: [Entry] = []
            while current.kind != .rbrace && current.kind != .eof {
                entries.append(try parseEntry())
            }
            if current.kind != .rbrace { throw ParserError.expectedClosingBrace(current.pos, got: current.kind) }
            advance()
            return entries
        }

        /// Parses a Go-style duration string into a `TimeInterval` (seconds).
        ///
        /// Accepts an optional leading sign followed by one or more
        /// `<number><unit>` segments where unit ∈ `ns`, `us` (or `µs`), `ms`,
        /// `s`, `m`, `h`. Numbers may be fractional. Examples: `300ms`,
        /// `-1.5h`, `2h45m`, `1h30m45.5s`.
        ///
        /// Mirrors Go's `time.ParseDuration`.
        static func parseDuration(_ s: String) -> TimeInterval? {
            if s.isEmpty { return nil }
            let scalars = Array(s.unicodeScalars)
            var i = 0
            var sign: TimeInterval = 1

            if scalars[i] == "-" { sign = -1; i += 1 }
            else if scalars[i] == "+" { i += 1 }
            if i >= scalars.count { return nil }

            // "0" alone is a valid zero duration.
            if i + 1 == scalars.count && scalars[i] == "0" { return 0 }

            var total: TimeInterval = 0
            while i < scalars.count {
                // Parse leading integer digits and optional fractional part.
                let numStart = i
                while i < scalars.count, scalars[i].value >= 0x30, scalars[i].value <= 0x39 {
                    i += 1
                }
                if i < scalars.count, scalars[i] == "." {
                    i += 1
                    while i < scalars.count, scalars[i].value >= 0x30, scalars[i].value <= 0x39 {
                        i += 1
                    }
                }
                if i == numStart { return nil }
                guard let n = Double(String(String.UnicodeScalarView(scalars[numStart..<i]))) else {
                    return nil
                }

                // Parse 1- or 2-character ASCII unit, or `µs` (two scalars).
                let unitStart = i
                while i < scalars.count, isUnitScalar(scalars[i]) {
                    i += 1
                }
                if i == unitStart { return nil }
                let unit = String(String.UnicodeScalarView(scalars[unitStart..<i]))

                let multiplier: TimeInterval
                switch unit {
                case "ns": multiplier = 1e-9
                case "us", "µs": multiplier = 1e-6
                case "ms": multiplier = 1e-3
                case "s":  multiplier = 1
                case "m":  multiplier = 60
                case "h":  multiplier = 3600
                default: return nil
                }
                total += n * multiplier
            }
            return sign * total
        }

        private static func isUnitScalar(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 0x61 && s.value <= 0x7A) || s == "µ"
        }
    }
}
