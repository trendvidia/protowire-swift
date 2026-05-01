import Foundation

extension PXF {
    public struct Position: Equatable, CustomStringConvertible {
        public var line: Int
        public var column: Int

        public var description: String { "\(line):\(column)" }
    }
}
