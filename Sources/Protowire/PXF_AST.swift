// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

extension PXF {
    // MARK: - AST Nodes

    public struct Comment: Equatable {
        public var pos: Position
        public var text: String
    }

    public struct Document: Equatable {
        public var typeURL: String?
        /// Generic `@<name> *(prefix) [{ ... }]` directives in source order
        /// (draft §3.4.2). Excludes `@type`, `@dataset`, `@proto`.
        public var directives: [Directive]
        /// `@dataset` directives in source order (draft §3.4.4). A document
        /// with any `@dataset` MUST NOT have `@type` or top-level body entries.
        public var datasets: [DatasetDirective]
        /// `@proto` directives in source order (draft §3.4.5).
        public var protos: [ProtoDirective]
        /// Byte offset where the schema-typed body begins, after all leading directives.
        public var bodyOffset: Int
        public var entries: [Entry]
        public var leadingComments: [Comment]

        public init(typeURL: String? = nil,
                    directives: [Directive] = [],
                    datasets: [DatasetDirective] = [],
                    protos: [ProtoDirective] = [],
                    bodyOffset: Int = 0,
                    entries: [Entry] = [],
                    leadingComments: [Comment] = []) {
            self.typeURL = typeURL
            self.directives = directives
            self.datasets = datasets
            self.protos = protos
            self.bodyOffset = bodyOffset
            self.entries = entries
            self.leadingComments = leadingComments
        }

        public static func == (lhs: Document, rhs: Document) -> Bool {
            guard lhs.typeURL == rhs.typeURL && lhs.leadingComments == rhs.leadingComments &&
                  lhs.directives == rhs.directives && lhs.datasets == rhs.datasets &&
                  lhs.protos == rhs.protos && lhs.bodyOffset == rhs.bodyOffset &&
                  lhs.entries.count == rhs.entries.count else { return false }
            for i in 0..<lhs.entries.count {
                if !lhs.entries[i].isEqual(to: rhs.entries[i]) { return false }
            }
            return true
        }
    }

    /// Top-of-document `@<name> *(<prefix-id>) [{ ... }]` entry (draft §3.4.2).
    /// Side-channel metadata that sits alongside the schema-typed body —
    /// e.g. chameleon's `@header chameleon.v1.LayerHeader { id = "x" }`.
    public struct Directive: Equatable {
        public var pos: Position
        public var name: String
        public var prefixes: [String]
        /// Back-compat single-prefix sugar: populated when exactly one
        /// prefix identifier was supplied. Empty for zero or 2+ prefixes;
        /// new code should read `prefixes` directly.
        public var type: String
        /// Raw inner bytes of the block; `nil` when the directive has no `{ ... }`.
        public var body: Data?
        public var leadingComments: [Comment]

        public init(pos: Position, name: String, prefixes: [String] = [],
                    type: String = "", body: Data? = nil, leadingComments: [Comment] = []) {
            self.pos = pos
            self.name = name
            self.prefixes = prefixes
            self.type = type
            self.body = body
            self.leadingComments = leadingComments
        }
    }

    /// `@dataset <type> ( col1, col2, ... ) row*` entry at document root
    /// (draft §3.4.4). Carries many instances of one message type in a
    /// single document — the protowire-native CSV. `type` MAY be empty
    /// when an anonymous `@proto` precedes the `@dataset`.
    public struct DatasetDirective: Equatable {
        public var pos: Position
        public var type: String
        public var columns: [String]
        public var rows: [DatasetRow]
        public var leadingComments: [Comment]

        public init(pos: Position, type: String = "", columns: [String] = [],
                    rows: [DatasetRow] = [], leadingComments: [Comment] = []) {
            self.pos = pos
            self.type = type
            self.columns = columns
            self.rows = rows
            self.leadingComments = leadingComments
        }
    }

    /// One parenthesised cell tuple in a `@dataset` directive. `cells` has the
    /// same length as the containing `DatasetDirective.columns`. A `nil` entry
    /// denotes an absent field; a `NullVal` denotes present-but-null; any other
    /// value denotes a present field.
    public struct DatasetRow: Equatable {
        public var pos: Position
        public var cells: [AnyValue?]

        public init(pos: Position, cells: [AnyValue?] = []) {
            self.pos = pos
            self.cells = cells
        }

        public static func == (lhs: DatasetRow, rhs: DatasetRow) -> Bool {
            guard lhs.pos == rhs.pos, lhs.cells.count == rhs.cells.count else { return false }
            for i in 0..<lhs.cells.count {
                switch (lhs.cells[i], rhs.cells[i]) {
                case (nil, nil): continue
                case (.some(let a), .some(let b)):
                    if !a.value.isEqual(to: b.value) { return false }
                default: return false
                }
            }
            return true
        }
    }

    /// Lexical body shape of a `@proto` directive (draft §3.4.5).
    public enum ProtoShape: String, Equatable {
        case anonymous, named, source, descriptor
    }

    /// `@proto <body>` entry at document root (draft §3.4.5). `body` holds raw
    /// bytes interpreted per `shape`: for anonymous/named, the bytes between
    /// `{` and matching `}`; for source, the dedented triple-quoted string
    /// contents; for descriptor, the base64-decoded FileDescriptorSet.
    public struct ProtoDirective: Equatable {
        public var pos: Position
        public var shape: ProtoShape
        /// Dotted message type name; non-empty only when `shape == .named`.
        public var typeName: String
        public var body: Data
        public var leadingComments: [Comment]

        public init(pos: Position, shape: ProtoShape, typeName: String = "",
                    body: Data = Data(), leadingComments: [Comment] = []) {
            self.pos = pos
            self.shape = shape
            self.typeName = typeName
            self.body = body
            self.leadingComments = leadingComments
        }
    }

    /// Type-erased `Value` wrapper for collections that need `Equatable`
    /// (e.g. `DatasetRow.cells`). `Value` itself is a protocol so it can't
    /// participate directly.
    public struct AnyValue: Equatable {
        public let value: Value
        public init(_ value: Value) { self.value = value }
        public static func == (lhs: AnyValue, rhs: AnyValue) -> Bool {
            lhs.value.isEqual(to: rhs.value)
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
