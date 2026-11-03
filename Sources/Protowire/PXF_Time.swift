// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

// `google.protobuf.Timestamp` and `Duration` through the Codable bridge. A
// `Date` keeps a Double and a `TimeInterval` cannot read a duration literal,
// so SwiftProtobuf's own types are what a field holds to keep every
// nanosecond. They are not Codable there, so the conformances are added here,
// the way `Pxf_BigInt` has its own: PXF reads and writes the literal, and PB,
// or a PXF block, the message form.
//
// The conformances are retroactive: SwiftProtobuf owns the types and the
// standard library owns the protocols. If SwiftProtobuf ever adds its own,
// the two conflict, which is what `@retroactive` acknowledges.

extension Google_Protobuf_Timestamp: @retroactive Decodable {
    private enum CodingKeys: Int, CodingKey {
        case seconds = 1, nanos = 2
    }

    /// Reads an RFC 3339 literal, every fractional digit kept, or the message
    /// form: PB, or a PXF block. Like protowire-go, the literal is read as
    /// written and the message form's fields are stored as they are.
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        if let holder = decoder as? _PXFValueHolder {
            guard let literal = holder.value as? PXF.TimestampVal else {
                throw DecodingError.typeMismatch(Google_Protobuf_Timestamp.self, .init(codingPath: decoder.codingPath,
                    debugDescription: "Expected a timestamp literal for google.protobuf.Timestamp, got \(type(of: holder.value))"))
            }
            guard let (s, n) = PXF.WellKnown.parseTimestamp(literal.raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "invalid timestamp \"\(PXF.clip(literal.raw))\""))
            }
            (seconds, nanos) = (s, n)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decodeIfPresent(Int64.self, forKey: .seconds) ?? 0
        // A plain varint: its low 32 bits, read as signed, as in protowire-go.
        nanos = Int32(truncatingIfNeeded: try c.decodeIfPresent(Int64.self, forKey: .nanos) ?? 0)
    }
}

extension Google_Protobuf_Duration: @retroactive Decodable {
    private enum CodingKeys: Int, CodingKey {
        case seconds = 1, nanos = 2
    }

    /// Reads a duration literal (`1.5ms`, `1h2m`) as `time.ParseDuration`
    /// does, in integers, or the message form, as `Google_Protobuf_Timestamp`
    /// does. A literal past int64 nanoseconds, about 292 years, is refused.
    public init(from decoder: Swift.Decoder) throws {
        self.init()
        if let holder = decoder as? _PXFValueHolder {
            guard let literal = holder.value as? PXF.DurationVal else {
                throw DecodingError.typeMismatch(Google_Protobuf_Duration.self, .init(codingPath: decoder.codingPath,
                    debugDescription: "Expected a duration literal for google.protobuf.Duration, got \(type(of: holder.value))"))
            }
            guard let (s, n) = PXF.WellKnown.parseDuration(literal.raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "invalid duration \"\(PXF.clip(literal.raw))\""))
            }
            (seconds, nanos) = (s, n)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decodeIfPresent(Int64.self, forKey: .seconds) ?? 0
        nanos = Int32(truncatingIfNeeded: try c.decodeIfPresent(Int64.self, forKey: .nanos) ?? 0)
    }
}

// Encodable writes the message form, zero fields left out. PXFEncoder takes
// the literal instead: a Timestamp's through _PXFLiteral, and a Duration's
// through `pxfLiteral` whenever it fits one.

extension Google_Protobuf_Timestamp: @retroactive Encodable, _PXFLiteral {
    private enum EncodingKeys: Int, CodingKey {
        case seconds = 1, nanos = 2
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        if seconds != 0 { try c.encode(seconds, forKey: .seconds) }
        if nanos != 0 { try c.encode(nanos, forKey: .nanos) }
    }

    /// `time.Time.Format(time.RFC3339Nano)` in UTC, as protowire-go writes
    /// every Timestamp, whatever its range.
    var pxfLiteral: String {
        PXF.WellKnown.timestampLiteral(seconds: seconds, nanos: nanos)
    }
}

extension Google_Protobuf_Duration: @retroactive Encodable {
    private enum EncodingKeys: Int, CodingKey {
        case seconds = 1, nanos = 2
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        if seconds != 0 { try c.encode(seconds, forKey: .seconds) }
        if nanos != 0 { try c.encode(nanos, forKey: .nanos) }
    }

    /// `time.Duration.String()`, or nil past int64 nanoseconds, where
    /// protowire-go writes the message form so the value survives.
    var pxfLiteral: String? {
        PXF.WellKnown.durationLiteral(seconds: seconds, nanos: nanos)
    }
}
