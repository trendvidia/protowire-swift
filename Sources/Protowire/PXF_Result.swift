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

        /// Returns the paths of all fields explicitly set to null.
        public var allNullFields: [String] {
            return Array(nullFields)
        }
    }
}
