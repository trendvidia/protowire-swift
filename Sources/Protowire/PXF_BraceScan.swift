// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

extension PXF {
    /// Byte-level brace matching used by directive parsing to slice raw
    /// body content out of the input without re-lexing it as PXF.
    /// Mirrors the lexer's string / comment handling so braces inside
    /// literals don't confuse the brace count.
    internal enum BraceScan {
        /// Returns the offset of the `}` matching the `{` at `openOffset`,
        /// or `nil` on unterminated input.
        static func findMatchingBrace(_ input: Data, _ openOffset: Int) -> Int? {
            var depth = 1
            var i = openOffset + 1
            while i < input.count {
                let ch = input[i]
                switch ch {
                case 0x7B: // {
                    depth += 1
                    i += 1
                case 0x7D: // }
                    depth -= 1
                    if depth == 0 { return i }
                    i += 1
                case 0x22: // "
                    guard let j = skipString(input, i) else { return nil }
                    i = j
                case 0x62 where i + 1 < input.count && input[i + 1] == 0x22: // b"
                    guard let j = skipBytes(input, i) else { return nil }
                    i = j
                case 0x23: // #
                    i = skipEOL(input, i + 1)
                case 0x2F where i + 1 < input.count && input[i + 1] == 0x2F: // //
                    i = skipEOL(input, i + 2)
                case 0x2F where i + 1 < input.count && input[i + 1] == 0x2A: // /*
                    var j = i + 2
                    var closed = false
                    while j + 1 < input.count {
                        if input[j] == 0x2A && input[j + 1] == 0x2F { j += 2; closed = true; break }
                        j += 1
                    }
                    if !closed { return nil }
                    i = j
                default:
                    i += 1
                }
            }
            return nil
        }

        private static func skipString(_ input: Data, _ i: Int) -> Int? {
            if i + 2 < input.count && input[i + 1] == 0x22 && input[i + 2] == 0x22 {
                // triple-quoted
                var j = i + 3
                while j + 2 < input.count {
                    if input[j] == 0x22 && input[j + 1] == 0x22 && input[j + 2] == 0x22 {
                        return j + 3
                    }
                    j += 1
                }
                return nil
            }
            var k = i + 1
            while k < input.count {
                if input[k] == 0x5C { // \
                    if k + 1 >= input.count { return nil }
                    k += 2
                    continue
                }
                if input[k] == 0x22 { return k + 1 }
                if input[k] == 0x0A { return nil }
                k += 1
            }
            return nil
        }

        private static func skipBytes(_ input: Data, _ i: Int) -> Int? {
            var j = i + 2
            while j < input.count {
                if input[j] == 0x22 { return j + 1 }
                if input[j] == 0x0A { return nil }
                j += 1
            }
            return nil
        }

        private static func skipEOL(_ input: Data, _ i: Int) -> Int {
            var k = i
            while k < input.count && input[k] != 0x0A { k += 1 }
            return k
        }
    }
}
