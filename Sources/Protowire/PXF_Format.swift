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
                    out += "\(a.key) = "
                    formatValue(a.value, level: level, into: &out)
                    if let trailing = a.trailingComment, !trailing.isEmpty {
                        out += " \(trailing)"
                    }
                    out += "\n"
                } else if let m = entry as? MapEntry {
                    writeComments(m.leadingComments, level: level, into: &out)
                    writeIndent(level, into: &out)
                    if needsQuoting(m.key) {
                        out += PXFEncoder.quote(m.key)
                    } else {
                        out += m.key
                    }
                    out += ": "
                    formatValue(m.value, level: level, into: &out)
                    if let trailing = m.trailingComment, !trailing.isEmpty {
                        out += " \(trailing)"
                    }
                    out += "\n"
                } else if let b = entry as? Block {
                    writeComments(b.leadingComments, level: level, into: &out)
                    writeIndent(level, into: &out)
                    out += "\(b.name) {\n"
                    formatEntries(b.entries, level: level + 1, into: &out)
                    writeIndent(level, into: &out)
                    out += "}\n"
                }
            }
        }

        private static func formatValue(_ value: Value, level: Int, into out: inout String) {
            switch value {
            case let v as StringVal:
                out += PXFEncoder.quote(v.value)
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

        /// Map keys must be quoted unless they look like a plain identifier
        /// (letter or `_`, then letters / digits / `_`). Empty strings are
        /// always quoted.
        private static func needsQuoting(_ s: String) -> Bool {
            if s.isEmpty { return true }
            for (i, ch) in s.unicodeScalars.enumerated() {
                let v = ch.value
                let okAlpha = (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || v == 0x5F
                let okDigit = i > 0 && v >= 0x30 && v <= 0x39
                if !(okAlpha || okDigit) { return true }
            }
            return false
        }
    }
}
