// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// A proto3 `sint32` field: an `Int32` that the protobuf wire writes
/// zigzag-encoded, so a small negative number takes one byte instead of ten.
///
/// Use it as a property's type where the message declares `sint32`, and
/// `SInt32?` where it declares `optional sint32`. `PBEncoder` and `PBDecoder`
/// recognise it by type, as a singular field, a repeated element (packed) and
/// a map key or value. Every other coder, `PXFEncoder` and `PXFDecoder`
/// included, sees a plain integer, since it encodes as a single `Int32`.
///
/// The Go reference spells the same field `int32` with the `zigzag` tag
/// option (`protowire:"2,zigzag"`).
public struct SInt32: Codable, Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public var value: Int32

    public init(_ value: Int32) { self.value = value }
    public init(integerLiteral value: Int32) { self.value = value }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int32.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public static func < (a: SInt32, b: SInt32) -> Bool { a.value < b.value }
    public var description: String { String(value) }
}

/// A proto3 `sint64` field: an `Int64` that the protobuf wire writes
/// zigzag-encoded. Everything said of `SInt32` holds, with 64 bits.
///
/// The Go reference spells the same field `int64` with the `zigzag` tag
/// option (`protowire:"1,zigzag"`).
public struct SInt64: Codable, Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public var value: Int64

    public init(_ value: Int64) { self.value = value }
    public init(integerLiteral value: Int64) { self.value = value }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int64.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public static func < (a: SInt64, b: SInt64) -> Bool { a.value < b.value }
    public var description: String { String(value) }
}

/// A value the protobuf wire writes as a zigzag varint.
protocol _PBZigZag {
    /// The value's zigzag encoding, ready for `appendVarint`.
    var pbZigZag: UInt64 { get }
    var pbIsZero: Bool { get }
}

extension SInt32: _PBZigZag {
    // zigzag32 of an Int32 equals zigzag64 of it widened: both are
    // (n << 1) ^ (n >> 31) for a value that fits 32 bits.
    var pbZigZag: UInt64 { Protowire.encodeZigZag(Int64(value)) }
    var pbIsZero: Bool { value == 0 }
}

extension SInt64: _PBZigZag {
    var pbZigZag: UInt64 { Protowire.encodeZigZag(value) }
    var pbIsZero: Bool { value == 0 }
}
