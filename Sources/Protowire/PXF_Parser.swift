// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
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
        /// A field assignment ('=') had a non-identifier key.
        case fieldAssignmentRequiresIdentifierKey(Position, got: TokenKind, key: String)
        /// A submessage block ('{') had a non-identifier key.
        case submessageBlockRequiresIdentifierKey(Position, got: TokenKind, key: String)
        /// A map entry (':' form) was used at document top level.
        case mapEntryNotAllowedAtTopLevel(Position)
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
        /// A future-reserved directive name was used (draft §3.4.6).
        case futureReservedDirective(Position, String)
        /// An unmatched `{` was encountered in a directive body.
        case unmatchedBrace(Position, String)
        /// `@dataset` coexists with `@type` (draft §3.4.4 standalone constraint).
        case datasetCoexistsWithType(Position)
        /// `@dataset` coexists with top-level field entries (draft §3.4.4).
        case datasetCoexistsWithBodyEntries(Position)
        /// `@dataset` column path contained a dot (draft §3.4.4).
        case datasetDottedColumn(Position, String)
        /// `@dataset` row had a different number of cells from the column count.
        case datasetArityMismatch(Position, got: Int, expected: Int)
        /// `@dataset` cell contained a list or block value (draft §3.4.4).
        case datasetCellRejected(Position, kind: String)
        /// Expected token at a specific parse position with a fixed error string.
        case directiveExpected(Position, String)

        /// A localized description of the error.
        public var description: String {
            switch self {
            case .expectedIdentifier(let pos, let got): return "[\(pos)] expected identifier, got \(got.rawValue)"
            case .expectedTypeURL(let pos, let got): return "[\(pos)] expected type URL after @type, got \(got.rawValue)"
            case .expectedEntryDelimiter(let pos, let got): return "[\(pos)] expected '=', ':', or '{', got \(got.rawValue)"
            case .fieldAssignmentRequiresIdentifierKey(let pos, let got, let key):
                return "[\(pos)] field assignment with '=' requires an identifier key, got \(got.rawValue) (\"\(key)\"); use ':' for map entries"
            case .submessageBlockRequiresIdentifierKey(let pos, let got, let key):
                return "[\(pos)] submessage block requires an identifier key, got \(got.rawValue) (\"\(key)\")"
            case .mapEntryNotAllowedAtTopLevel(let pos):
                return "[\(pos)] map entry (':' form) is only allowed inside a '{ … }' block; use '=' for top-level field assignments"
            case .expectedValue(let pos, let got): return "[\(pos)] expected value, got \(got.rawValue)"
            case .expectedClosingBracket(let pos, let got): return "[\(pos)] expected ']', got \(got.rawValue)"
            case .expectedClosingBrace(let pos, let got): return "[\(pos)] expected '}', got \(got.rawValue)"
            case .invalidBase64(let pos, let err): return "[\(pos)] invalid base64: \(err)"
            case .invalidTimestamp(let pos, let val): return "[\(pos)] invalid timestamp: \(val)"
            case .invalidDuration(let pos, let val): return "[\(pos)] invalid duration: \(val)"
            case .unexpectedEOF: return "unexpected EOF"
            case .futureReservedDirective(let pos, let name):
                return "[\(pos)] @\(name) is a spec-reserved directive name with no v1 semantics (draft §3.4.6)"
            case .unmatchedBrace(let pos, let label): return "[\(pos)] \(label): unmatched '{'"
            case .datasetCoexistsWithType(let pos):
                return "[\(pos)] @dataset directive cannot coexist with @type; the @dataset header declares the document's type (draft §3.4.4)"
            case .datasetCoexistsWithBodyEntries(let pos):
                return "[\(pos)] @dataset directive cannot coexist with top-level field entries; the document's payload is the @dataset rows (draft §3.4.4)"
            case .datasetDottedColumn(let pos, let name):
                return "[\(pos)] @dataset column \"\(name)\": dotted column paths are not supported in v1 (draft §3.4.4)"
            case .datasetArityMismatch(let pos, let got, let expected):
                return "[\(pos)] @dataset row has \(got) cells, expected \(expected) (column count)"
            case .datasetCellRejected(let pos, let kind):
                return "[\(pos)] @dataset cells cannot contain \(kind) values in v1 (draft §3.4.4)"
            case .directiveExpected(let pos, let what): return "[\(pos)] \(what)"
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
            var doc = Document(leadingComments: flushComments())

            // Top-of-document directives: @type, @<name>, @dataset, @proto
            // may interleave in any order. bodyOffset tracks the byte
            // right after the last directive token.
            directives: while true {
                switch current.kind {
                case .atType:
                    advance()
                    if current.kind != .identifier {
                        throw ParserError.expectedTypeURL(current.pos, got: current.kind)
                    }
                    doc.typeURL = current.value
                    doc.bodyOffset = lexer.pos
                    advance()
                case .atDirective:
                    let (d, end) = try parseDirective()
                    doc.directives.append(d)
                    doc.bodyOffset = end
                case .atDataset:
                    let (ds, end) = try parseDatasetDirective()
                    doc.datasets.append(ds)
                    doc.bodyOffset = end
                case .atProto:
                    let (pd, end) = try parseProtoDirective()
                    doc.protos.append(pd)
                    doc.bodyOffset = end
                default:
                    break directives
                }
            }

            // Standalone constraint (draft §3.4.4): a document containing
            // any @dataset directive MUST NOT also carry @type or
            // top-level field entries.
            if let firstDataset = doc.datasets.first {
                if doc.typeURL != nil {
                    throw ParserError.datasetCoexistsWithType(firstDataset.pos)
                }
                if current.kind != .eof {
                    throw ParserError.datasetCoexistsWithBodyEntries(current.pos)
                }
            }

            while current.kind != .eof {
                // Top-level: only field_entry is allowed. The document
                // represents a proto message, never a map<K,V>; map_entry
                // (`:` form) is reserved for the inside of a '{ ... }' block.
                // See docs/grammar.ebnf -> document.
                doc.entries.append(try parseEntry(allowMapEntry: false))
            }

            return doc
        }

        /// Parses `@<name> *(<prefix-id>) [{ ... }]`. The `.atDirective`
        /// token is current on entry. Returns the directive plus the byte
        /// offset immediately after its last token.
        private func parseDirective() throws -> (Directive, Int) {
            let leading = flushComments()
            let atPos = current.pos
            let name = current.value
            if Schema.isFutureReservedDirective(name) {
                throw ParserError.futureReservedDirective(atPos, name)
            }
            var prefixes: [String] = []
            // `@` + name. The lexer doesn't track byte offsets per token, so
            // estimate the end from `lexer.pos` post-advance.
            advance()
            var endOffset = lexer.pos

            // Zero-or-more prefix identifiers. One-token lookahead
            // disambiguates: an identifier followed by `=` or `:` is a
            // body field key, not a directive prefix.
            while current.kind == .identifier {
                let peek = peekKind()
                if peek == .equal || peek == .colon { break }
                prefixes.append(current.value)
                advance()
                endOffset = lexer.pos
            }

            var body: Data? = nil
            if current.kind == .lbrace {
                let open = lexer.pos - 1 // `{` was already consumed by lexer.next()
                guard let close = BraceScan.findMatchingBrace(lexer.input, open) else {
                    throw ParserError.unmatchedBrace(atPos, "directive @\(name)")
                }
                // Validate inner well-formedness by parsing the block.
                _ = try parseBlockVal(typeURL: nil, depth: 1)
                body = lexer.input.subdata(in: (open + 1)..<close)
                endOffset = close + 1
            }

            let typeField = prefixes.count == 1 ? prefixes[0] : ""
            return (Directive(pos: atPos, name: name, prefixes: prefixes,
                              type: typeField, body: body, leadingComments: leading),
                    endOffset)
        }

        /// Parses `@dataset <type> ( col1, col2, ... ) row*` per draft §3.4.4.
        /// `.atDataset` is current on entry.
        private func parseDatasetDirective() throws -> (DatasetDirective, Int) {
            let leading = flushComments()
            let atPos = current.pos
            advance() // consume @dataset

            // Optional row message type (dotted identifier). MAY be omitted
            // when an anonymous @proto precedes the @dataset.
            var type = ""
            if current.kind == .identifier {
                type = current.value
                advance()
            }

            if current.kind != .lparen {
                throw ParserError.directiveExpected(current.pos,
                    "expected '(' to start @dataset column list, got \(current.kind.rawValue)")
            }
            advance()

            if current.kind != .identifier {
                throw ParserError.directiveExpected(current.pos,
                    "@dataset column list must contain at least one field name, got \(current.kind.rawValue)")
            }
            var columns: [String] = []
            while true {
                if current.kind != .identifier {
                    throw ParserError.directiveExpected(current.pos,
                        "expected column field name, got \(current.kind.rawValue)")
                }
                let colName = current.value
                if colName.contains(".") {
                    throw ParserError.datasetDottedColumn(current.pos, colName)
                }
                columns.append(colName)
                advance()
                if current.kind == .comma { advance(); continue }
                if current.kind == .rparen { break }
                throw ParserError.directiveExpected(current.pos,
                    "expected ',' or ')' in @dataset column list, got \(current.kind.rawValue)")
            }
            var endOffset = lexer.pos // past `)`
            advance()

            var rows: [DatasetRow] = []
            while current.kind == .lparen {
                let (row, rowEnd) = try parseDatasetRow(expected: columns.count)
                rows.append(row)
                endOffset = rowEnd
            }

            return (DatasetDirective(pos: atPos, type: type, columns: columns,
                                     rows: rows, leadingComments: leading),
                    endOffset)
        }

        private func parseDatasetRow(expected: Int) throws -> (DatasetRow, Int) {
            let pos = current.pos
            advance() // consume (

            var cells: [AnyValue?] = []
            cells.append(try parseRowCell())
            while current.kind == .comma {
                advance()
                cells.append(try parseRowCell())
            }
            if current.kind != .rparen {
                throw ParserError.directiveExpected(current.pos,
                    "expected ',' or ')' in @dataset row, got \(current.kind.rawValue)")
            }
            let endOffset = lexer.pos
            advance()

            if cells.count != expected {
                throw ParserError.datasetArityMismatch(pos, got: cells.count, expected: expected)
            }
            return (DatasetRow(pos: pos, cells: cells), endOffset)
        }

        private func parseRowCell() throws -> AnyValue? {
            switch current.kind {
            case .comma, .rparen: return nil
            case .lbracket: throw ParserError.datasetCellRejected(current.pos, kind: "list")
            case .lbrace: throw ParserError.datasetCellRejected(current.pos, kind: "block")
            default:
                let v = try parseValue(depth: 0)
                return AnyValue(v)
            }
        }

        /// Parses `@proto <body>`. `.atProto` is current on entry.
        /// Distinguishes four lexically-determined shapes (draft §3.4.5).
        private func parseProtoDirective() throws -> (ProtoDirective, Int) {
            let leading = flushComments()
            let atPos = current.pos
            advance() // consume @proto

            switch current.kind {
            case .lbrace:
                let (body, end) = try captureBraceBody(label: "@proto (anonymous form)")
                return (ProtoDirective(pos: atPos, shape: .anonymous, body: body,
                                       leadingComments: leading), end)
            case .identifier:
                let typeName = current.value
                advance()
                if current.kind != .lbrace {
                    throw ParserError.directiveExpected(current.pos,
                        "expected '{' after @proto \(typeName), got \(current.kind.rawValue)")
                }
                let (body, end) = try captureBraceBody(label: "@proto \(typeName)")
                return (ProtoDirective(pos: atPos, shape: .named, typeName: typeName,
                                       body: body, leadingComments: leading), end)
            case .string:
                let bytes = current.value.data(using: .utf8) ?? Data()
                advance()
                let end = lexer.pos
                return (ProtoDirective(pos: atPos, shape: .source, body: bytes,
                                       leadingComments: leading), end)
            case .bytes:
                let raw = current.value
                let decoded: Data
                if let std = Data(base64Encoded: raw) {
                    decoded = std
                } else {
                    // URL-safe alphabet (allowed per draft §3.7).
                    var padded = raw.replacingOccurrences(of: "-", with: "+")
                                    .replacingOccurrences(of: "_", with: "/")
                    let rem = padded.count % 4
                    if rem != 0 { padded.append(String(repeating: "=", count: 4 - rem)) }
                    guard let url = Data(base64Encoded: padded) else {
                        throw ParserError.invalidBase64(current.pos, raw)
                    }
                    decoded = url
                }
                advance()
                let end = lexer.pos
                return (ProtoDirective(pos: atPos, shape: .descriptor, body: decoded,
                                       leadingComments: leading), end)
            default:
                throw ParserError.directiveExpected(current.pos,
                    "expected '{', dotted identifier, triple-quoted string, or b\"...\" after @proto, got \(current.kind.rawValue)")
            }
        }

        /// Slices the raw bytes between `{` and the matching `}` (both
        /// exclusive) without decoding the contents as PXF. Repositions
        /// the lexer past the closing `}` and primes the parser.
        private func captureBraceBody(label: String) throws -> (Data, Int) {
            let open = lexer.pos - 1 // `{` already consumed into `current`
            guard let close = BraceScan.findMatchingBrace(lexer.input, open) else {
                throw ParserError.unmatchedBrace(current.pos, label)
            }
            let body = lexer.input.subdata(in: (open + 1)..<close)
            lexer.repositionTo(close + 1)
            advance() // prime current token past `}`
            return (body, close + 1)
        }

        /// One-token lookahead with full state restore. Skips
        /// newlines/comments without disturbing pending-comment
        /// accumulation.
        private func peekKind() -> TokenKind {
            let state = lexer.save()
            let savedCurrent = current
            let savedCount = comments.count
            advance()
            let peeked = current.kind
            lexer.restore(state)
            current = savedCurrent
            if comments.count > savedCount {
                comments.removeLast(comments.count - savedCount)
            }
            return peeked
        }

        private func parseEntry(allowMapEntry: Bool = true, depth: Int = 0) throws -> Entry {
            let leading = flushComments()
            let pos = current.pos

            guard current.kind == .identifier || current.kind == .string || current.kind == .number else {
                throw ParserError.expectedIdentifier(pos, got: current.kind)
            }

            let keyKind = current.kind
            let key = current.value
            advance()

            switch current.kind {
            case .equal:
                // `=` denotes a field assignment on a proto message; the key
                // must be an identifier. Map-style keys (string / integer)
                // are only valid with `:`.
                guard keyKind == .identifier else {
                    throw ParserError.fieldAssignmentRequiresIdentifierKey(pos, got: keyKind, key: key)
                }
                advance()
                let val = try parseValue(depth: depth)
                return Assignment(pos: pos, key: key, value: val, leadingComments: leading)
            case .colon:
                // Map entry. Only allowed inside a '{ ... }' block, never at
                // document top level.
                guard allowMapEntry else {
                    throw ParserError.mapEntryNotAllowedAtTopLevel(pos)
                }
                advance()
                let val = try parseValue(depth: depth)
                return MapEntry(pos: pos, key: key, value: val, leadingComments: leading)
            case .lbrace:
                // `{ ... }` denotes a submessage field; same identifier-only
                // rule as `=` applies.
                guard keyKind == .identifier else {
                    throw ParserError.submessageBlockRequiresIdentifierKey(pos, got: keyKind, key: key)
                }
                advance()
                try checkDepth(depth + 1)
                let entries = try parseBody(depth: depth + 1)
                return Block(pos: pos, name: key, entries: entries, leadingComments: leading)
            default:
                throw ParserError.expectedEntryDelimiter(current.pos, got: current.kind)
            }
        }

        private func checkDepth(_ depth: Int) throws {
            if depth > Hardening.maxNestingDepth {
                throw DecoderError.nestingDepthExceeded(depth)
            }
        }

        private func parseValue(depth: Int) throws -> Value {
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
                return try parseList(depth: depth + 1)
            case .lbrace:
                return try parseBlockVal(typeURL: typeURL, depth: depth + 1)
            default:
                throw ParserError.expectedValue(pos, got: current.kind)
            }
        }

        private func parseList(depth: Int) throws -> Value {
            try checkDepth(depth)
            advance() // [
            var elements: [Value] = []
            while current.kind != .rbracket && current.kind != .eof {
                elements.append(try parseValue(depth: depth))
                if current.kind == .comma { advance() }
            }
            if current.kind != .rbracket { throw ParserError.expectedClosingBracket(current.pos, got: current.kind) }
            advance()
            return ListVal(pos: current.pos, elements: elements)
        }

        private func parseBlockVal(typeURL: String? = nil, depth: Int) throws -> Value {
            try checkDepth(depth)
            advance() // {
            let entries = try parseBody(depth: depth)
            return BlockVal(pos: current.pos, typeURL: typeURL, entries: entries)
        }

        private func parseBody(depth: Int) throws -> [Entry] {
            var entries: [Entry] = []
            while current.kind != .rbrace && current.kind != .eof {
                entries.append(try parseEntry(depth: depth))
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
