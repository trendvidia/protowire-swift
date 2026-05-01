import Foundation

extension PXF {
    // MARK: - AST Nodes

    public struct Comment: Equatable {
        public var pos: Position
        public var text: String
    }

    public struct Document: Equatable {
        public var typeURL: String?
        public var entries: [Entry]
        public var leadingComments: [Comment]

        public static func == (lhs: Document, rhs: Document) -> Bool {
            guard lhs.typeURL == rhs.typeURL && lhs.leadingComments == rhs.leadingComments &&
                  lhs.entries.count == rhs.entries.count else { return false }
            for i in 0..<lhs.entries.count {
                if !lhs.entries[i].isEqual(to: rhs.entries[i]) { return false }
            }
            return true
        }
    }

    public protocol Entry {
        var pos: Position { get }
        var leadingComments: [Comment] { get }
    }

    public struct Assignment: Entry, Equatable {
        public var pos: Position
        public var key: String
        public var value: Value
        public var leadingComments: [Comment]
        public var trailingComment: String?

        public static func == (lhs: Assignment, rhs: Assignment) -> Bool {
            return lhs.pos.line == rhs.pos.line && lhs.pos.column == rhs.pos.column &&
                   lhs.key == rhs.key && lhs.value.isEqual(to: rhs.value) &&
                   lhs.leadingComments == rhs.leadingComments && lhs.trailingComment == rhs.trailingComment
        }
    }

    public struct MapEntry: Entry, Equatable {
        public var pos: Position
        public var key: String
        public var value: Value
        public var leadingComments: [Comment]
        public var trailingComment: String?

        public static func == (lhs: MapEntry, rhs: MapEntry) -> Bool {
            return lhs.pos.line == rhs.pos.line && lhs.pos.column == rhs.pos.column &&
                   lhs.key == rhs.key && lhs.value.isEqual(to: rhs.value) &&
                   lhs.leadingComments == rhs.leadingComments && lhs.trailingComment == rhs.trailingComment
        }
    }

    public struct Block: Entry, Equatable {
        public var pos: Position
        public var name: String
        public var entries: [Entry]
        public var leadingComments: [Comment]

        public static func == (lhs: Block, rhs: Block) -> Bool {
            guard lhs.pos.line == rhs.pos.line && lhs.pos.column == rhs.pos.column &&
                  lhs.name == rhs.name && lhs.leadingComments == rhs.leadingComments &&
                  lhs.entries.count == rhs.entries.count else { return false }
            
            for i in 0..<lhs.entries.count {
                if !lhs.entries[i].isEqual(to: rhs.entries[i]) { return false }
            }
            return true
        }
    }

    public protocol Value {
        var pos: Position { get }
        func isEqual(to other: Value) -> Bool
    }

    public struct StringVal: Value, Equatable {
        public var pos: Position
        public var value: String
        public func isEqual(to other: Value) -> Bool { (other as? StringVal) == self }
    }

    public struct IntVal: Value, Equatable {
        public var pos: Position
        public var raw: String
        public func isEqual(to other: Value) -> Bool { (other as? IntVal) == self }
    }

    public struct FloatVal: Value, Equatable {
        public var pos: Position
        public var raw: String
        public func isEqual(to other: Value) -> Bool { (other as? FloatVal) == self }
    }

    public struct BoolVal: Value, Equatable {
        public var pos: Position
        public var value: Bool
        public func isEqual(to other: Value) -> Bool { (other as? BoolVal) == self }
    }

    public struct BytesVal: Value, Equatable {
        public var pos: Position
        public var value: Data
        public func isEqual(to other: Value) -> Bool { (other as? BytesVal) == self }
    }

    public struct NullVal: Value, Equatable {
        public var pos: Position
        public func isEqual(to other: Value) -> Bool { other is NullVal }
    }

    public struct IdentVal: Value, Equatable {
        public var pos: Position
        public var name: String
        public func isEqual(to other: Value) -> Bool { (other as? IdentVal) == self }
    }

    public struct TimestampVal: Value, Equatable {
        public var pos: Position
        public var value: Date
        public var raw: String
        public func isEqual(to other: Value) -> Bool { (other as? TimestampVal) == self }
    }

    public struct DurationVal: Value, Equatable {
        public var pos: Position
        public var value: TimeInterval
        public var raw: String
        public func isEqual(to other: Value) -> Bool { (other as? DurationVal) == self }
    }

    public struct ListVal: Value, Equatable {
        public var pos: Position
        public var elements: [Value]

        public func isEqual(to other: Value) -> Bool {
            guard let other = other as? ListVal, self.elements.count == other.elements.count else { return false }
            for i in 0..<self.elements.count {
                if !self.elements[i].isEqual(to: other.elements[i]) { return false }
            }
            return true
        }
        
        public static func == (lhs: ListVal, rhs: ListVal) -> Bool { lhs.isEqual(to: rhs) }
    }

    public struct BlockVal: Value, Equatable {
        public var pos: Position
        public var typeURL: String?
        public var entries: [Entry]

        public func isEqual(to other: Value) -> Bool {
            guard let other = other as? BlockVal, self.typeURL == other.typeURL && self.entries.count == other.entries.count else { return false }
            for i in 0..<self.entries.count {
                if !self.entries[i].isEqual(to: other.entries[i]) { return false }
            }
            return true
        }
        
        public static func == (lhs: BlockVal, rhs: BlockVal) -> Bool { lhs.isEqual(to: rhs) }
    }
}

// Helper for heterogeneous comparison
extension PXF.Entry {
    func isEqual(to other: PXF.Entry) -> Bool {
        if let lhs = self as? PXF.Assignment, let rhs = other as? PXF.Assignment { return lhs == rhs }
        if let lhs = self as? PXF.MapEntry, let rhs = other as? PXF.MapEntry { return lhs == rhs }
        if let lhs = self as? PXF.Block, let rhs = other as? PXF.Block { return lhs == rhs }
        return false
    }
}
