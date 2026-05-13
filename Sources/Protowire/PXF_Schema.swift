// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

extension PXF {
    /// PXF directive-name reservations per draft §3.4.6.
    ///
    /// The full reserved-directive-name set is 13 names: the four value
    /// keywords (`null`, `true`, `false`) — rejected at the lexer because
    /// they tokenise as their value form, never as a directive — plus the
    /// seven names with parser-layer or future significance:
    ///
    /// - `type`, `dataset`, `proto` — own production, lexed as dedicated tokens
    /// - `entry` — spec-registered named directive (draft §3.4.3)
    /// - `table`, `datasource`, `view`, `procedure`, `function`, `permissions`
    ///   — future-reserved; v1 decoders MUST reject them so applications
    ///   cannot squat the names before the spec allocates semantics.
    public enum Schema {
        /// True when `name` is reserved for future allocation by draft
        /// §3.4.6 and MUST be rejected by v1 decoders. Names with their
        /// own lexer production (`type`, `dataset`, `proto`) and the
        /// registered `entry` are not included here — they're handled
        /// either at the lexer or by the named-directive shape.
        public static func isFutureReservedDirective(_ name: String) -> Bool {
            switch name {
            case "table", "datasource", "view", "procedure", "function", "permissions":
                return true
            default:
                return false
            }
        }
    }
}
