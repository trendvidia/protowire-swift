// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

extension PXF {
    public struct Position: Equatable, CustomStringConvertible {
        public var line: Int
        public var column: Int

        public var description: String { "\(line):\(column)" }
    }
}
