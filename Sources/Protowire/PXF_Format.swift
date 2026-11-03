// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

extension PXF {
    /// Comment-preserving formatter: AST `Document` → PXF text.
    ///
    /// Unlike `PXFEncoder` (which works from an `Encodable` value and loses
    /// comments), this formats directly from a parsed AST. The natural
    /// pairing is `PXF.Parser.parseDocument()` on the way in.
    ///
    /// Mirrors `protowire-go/encoding/pxf/format.go` and
    /// `protowire-csharp/src/Protowire.Pxf/Format.cs`.
    public enum Format {

        /// Pretty-prints a parsed `Document`, preserving comments.
        public static func formatDocument(_ doc: Document) -> String {
            var out = ""
            if let typeURL = doc.typeURL, !typeURL.isEmpty {
                out += "@type \(typeURL)\n\n"
            }
            writeComments(doc.leadingComments, level: 0, into: &out)
            formatEntries(doc.entries, level: 0, into: &out)
            return out
        }

        // MARK: - Internals

        private static func formatEntries(_ entries: [Entry], level: Int, into out: inout String) {
            for entry in entries {
                if let a = entry as? Assignment {
                    writeComments(a.leadingComments, level: level, into: &out)
                    writeIndent(level, into: &out)
                    out += "\(entryName(a.key, quoted: a.keyQuoted)) = "
                    formatValue(a.value, level: level, into: &out)
                    if let trailing = a.trailingComment, !trailing.isEmpty {
                        out += " \(trailing)"
                    }
                    out += "\n"
                } else if let m = entry as? MapEntry {
                    writeComments(m.leadingComments, level: level, into: &out)
                    writeIndent(level, into: &out)
                    out += mapKeyQuoted(m) ? quote(m.key) : m.key
                    out += ": "
                    formatValue(m.value, level: level, into: &out)
                    if let trailing = m.trailingComment, !trailing.isEmpty {
                        out += " \(trailing)"
                    }
                    out += "\n"
                } else if let b = entry as? Block {
                    writeComments(b.leadingComments, level: level, into: &out)
                    writeIndent(level, into: &out)
                    out += "\(entryName(b.name, quoted: b.nameQuoted)) {\n"
                    formatTypeEntry(b.typeURL, b.typeEntryLeadingComments, b.typeEntryTrailingComment, level: level + 1, into: &out)
                    formatEntries(b.entries, level: level + 1, into: &out)
                    writeIndent(level, into: &out)
                    out += "}\n"
                }
            }
        }

        /// An entry name as the source spelled it: this formatter has no
        /// schema, so a quoted name stays quoted. `canonicalizeKeyed` is what
        /// unquotes one.
        private static func entryName(_ name: String, quoted: Bool) -> String {
            quoted ? quote(name) : name
        }

        private static func formatTypeEntry(_ url: String?, _ leading: [Comment], _ trailing: String?,
                                            level: Int, into out: inout String) {
            guard let url else { return }
            writeComments(leading, level: level, into: &out)
            writeIndent(level, into: &out)
            out += "@type = \(quote(url))"
            if let trailing, !trailing.isEmpty { out += " \(trailing)" }
            out += "\n"
        }

        private static func formatValue(_ value: Value, level: Int, into out: inout String) {
            switch value {
            case let v as StringVal:
                out += quote(v.value)
            case let v as IntVal:
                out += v.raw
            case let v as FloatVal:
                out += v.raw
            case let v as BoolVal:
                out += v.value ? "true" : "false"
            case let v as BytesVal:
                out += "b\"\(v.value.base64EncodedString())\""
            case is NullVal:
                out += "null"
            case let v as IdentVal:
                out += v.name
            case let v as TimestampVal:
                out += v.raw
            case let v as DurationVal:
                out += v.raw
            case let v as ListVal:
                out += "[\n"
                for (i, elem) in v.elements.enumerated() {
                    writeIndent(level + 1, into: &out)
                    formatValue(elem, level: level + 1, into: &out)
                    if i + 1 < v.elements.count { out += "," }
                    out += "\n"
                }
                writeIndent(level, into: &out)
                out += "]"
            case let v as BlockVal:
                out += "{\n"
                formatTypeEntry(v.typeURL, v.typeEntryLeadingComments, v.typeEntryTrailingComment, level: level + 1, into: &out)
                formatEntries(v.entries, level: level + 1, into: &out)
                writeIndent(level, into: &out)
                out += "}"
            default:
                break
            }
        }

        private static func writeIndent(_ level: Int, into out: inout String) {
            for _ in 0..<level {
                out += "  "
            }
        }

        private static func writeComments(_ comments: [Comment], level: Int, into out: inout String) {
            for c in comments {
                writeIndent(level, into: &out)
                out += "\(c.text)\n"
            }
        }

        /// How a map key is spelled on the way out. A key the document quoted
        /// stays quoted unless it is identifier-safe. A bare key stays bare,
        /// because `true`, `0` and `123` denote a bool or integer key and
        /// quotes would change what they denote (draft -01 § Entries and
        /// Keys). An entry built in code has no spelling of its own, so it is
        /// bare when its key lexes as one bare map-key token.
        private static func mapKeyQuoted(_ m: MapEntry) -> Bool {
            m.keyKind == .string ? !identSafeEntryName(m.key) : !lexesAsBareMapKey(m.key)
        }

        private static func lexesAsBareMapKey(_ s: String) -> Bool {
            let lexer = Lexer(string: s)
            let token = lexer.next()
            switch token.kind {
            case .identifier, .bool:
                return token.value == s && lexer.next().kind == .eof
            case .number:
                return token.value == s && !s.contains("p") && lexer.next().kind == .eof
            default:
                return false
            }
        }

        /// A string as the reference's formatter writes it: Go's `%q`. It
        /// differs from `PXFEncoder.quote`, which is the marshaller's, on
        /// `\a \b \f \v`, U+007F and non-printable Unicode, which it
        /// escapes rather than writes.
        static func quote(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\u{07}": out += "\\a"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{0B}": out += "\\v"
                default:
                    if isPrintable(scalar) {
                        out.unicodeScalars.append(scalar)
                    } else if scalar.value < 0x80 {
                        out += "\\x" + hex(scalar.value, width: 2)
                    } else if scalar.value < 0x10000 {
                        out += "\\u" + hex(scalar.value, width: 4)
                    } else {
                        out += "\\U" + hex(scalar.value, width: 8)
                    }
                }
            }
            return out + "\""
        }

        private static func hex(_ value: UInt32, width: Int) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: width - digits.count) + digits
        }

        /// Go's `strconv.IsPrint`: letters, marks, numbers, punctuation and
        /// symbols, plus the ASCII space.
        private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
            if scalar == " " { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned,
                 .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
    }
}
