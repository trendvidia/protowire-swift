// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

extension PXF {
    public struct Result {
        private var nullFields: Set<String> = []
        private var presentFields: Set<String> = []

        internal init() {}

        internal mutating func markNull(path: String) {
            nullFields.insert(path)
            presentFields.insert(path)
        }

        internal mutating func markPresent(path: String) {
            presentFields.insert(path)
        }

        /// Reports whether the field at the given path was explicitly set to null.
        public func isNull(_ path: String) -> Bool {
            return nullFields.contains(path)
        }

        /// Reports whether the field at the given path was not mentioned in the input.
        public func isAbsent(_ path: String) -> Bool {
            return !presentFields.contains(path)
        }

        /// Reports whether the field at the given path was set to a concrete (non-null) value.
        public func isSet(_ path: String) -> Bool {
            return presentFields.contains(path) && !nullFields.contains(path)
        }

        /// Returns the paths of all fields explicitly set to null, sorted.
        public var allNullFields: [String] {
            return nullFields.sorted()
        }

        /// All paths with a concrete (non-null) value, sorted.
        public var allSetFields: [String] {
            return presentFields.subtracting(nullFields).sorted()
        }
    }
}
