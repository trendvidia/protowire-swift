// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// A namespace for Protobuf-related utilities and types.
public enum PB {
    /// Errors that can occur during Protobuf decoding.
    public enum Error: Swift.Error { 
        /// Indicates that the data being decoded is corrupt or invalid.
        case corruptData 
    }
    enum MapKey: Int, CodingKey { case key = 1, value = 2 }
}

// MARK: - Protocols

protocol _PBArray { static var elementType: Decodable.Type { get }; init(elements: [Any]) }
extension Array: _PBArray where Element: Decodable {
    static var elementType: Decodable.Type { Element.self }
    init(elements: [Any]) { self = elements.compactMap { $0 as? Element } }
}

protocol _PBMap { static var keyType: Decodable.Type { get }; static var valueType: Decodable.Type { get }; init(entries: [(Any, Any)]) }
extension Dictionary: _PBMap where Key: Decodable, Value: Decodable {
    static var keyType: Decodable.Type { Key.self }; static var valueType: Decodable.Type { Value.self }
    init(entries: [(Any, Any)]) {
        var dict: [Key: Value] = [:]
        for (k, v) in entries { if let key = k as? Key, let val = v as? Value { dict[key] = val } }
        self = dict
    }
}

protocol _PBOptional { var pbWrapped: Encodable? { get }; static var pbWrappedType: Any.Type { get } }
extension Optional: _PBOptional where Wrapped: Encodable {
    var pbWrapped: Encodable? { self.map { $0 } }
    static var pbWrappedType: Any.Type { Wrapped.self }
}

// MARK: - Encoder

/// An encoder that serializes `Encodable` types into Protobuf binary format.
///
/// A field follows proto3 implicit presence, as in the reference: a non-optional
/// scalar, string, bytes, list or map at its zero value writes nothing. An
/// `Optional` holding a value is written at zero too, which is how a type marks
/// a proto3 `optional` field. A non-optional message is always written, and a
/// nil one is absent. List elements and map entries keep their zeros, and a
/// nil element or map value is written as its type's zero value (for a message,
/// the empty message), since neither is nullable on the wire.
///
/// A field's number is its `CodingKey`'s `intValue`, so a type needs Int
/// CodingKeys. Encoding a key without one throws `EncodingError.invalidValue`.
///
/// A signed integer is a plain varint (proto3 `int32` / `int64`). A field of
/// type `SInt32` or `SInt64` is zigzag-encoded (`sint32` / `sint64`).
public final class PBEncoder {
    /// The limits for each encode call; only `maxNestingDepth` applies. A
    /// value nested deeper than a decoder at that limit reads is an error,
    /// counted as the decoder counts it: the root is depth 0, and every
    /// submessage and every map entry is one descent, so a map entry with a
    /// message value is two (HARDENING.md § Recursion). Raise it only
    /// together with every reader's limit.
    public var limits = Hardening.Limits()

    /// Initializes a new `PBEncoder`.
    public init() {}
    
    /// Encodes a value into Protobuf binary format.
    /// - Parameter v: The value to encode.
    /// - Returns: The encoded data.
    /// - Throws: An error if encoding fails.
    public func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = _PBEncoder(depth: 0, maxDepth: limits.maxNestingDepth); try v.encode(to: e); return e.data
    }
}

private final class _PBEncoder: Encoder {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]; var data = Data()
    /// The decoder's depth inside the bytes this encoder writes.
    let depth: Int
    let maxDepth: Int

    init(depth: Int, maxDepth: Int) {
        self.depth = depth
        self.maxDepth = maxDepth
    }

    /// An encoder for the same level: an enum's number or a packed list.
    func peer() -> _PBEncoder { _PBEncoder(depth: depth, maxDepth: maxDepth) }

    /// An encoder for a submessage or map entry, one descent down. It is
    /// refused before anything is written into it, so an empty message past
    /// the limit counts and a reference cycle stops here.
    func descend(_ value: Any, _ key: CodingKey) throws -> _PBEncoder {
        let next = depth + 1
        if next > maxDepth {
            throw EncodingError.invalidValue(value, .init(codingPath: [key],
                debugDescription: "pb: nesting depth \(next) exceeds MaxNestingDepth=\(maxDepth)"))
        }
        return _PBEncoder(depth: next, maxDepth: maxDepth)
    }
    func container<K>(keyedBy t: K.Type) -> KeyedEncodingContainer<K> { return KeyedEncodingContainer(KeyedContainer<K>(encoder: self)) }
    func unkeyedContainer() -> UnkeyedEncodingContainer { fatalError() }
    func singleValueContainer() -> SingleValueEncodingContainer { return self }

    struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        var encoder: _PBEncoder; var codingPath: [CodingKey] = []
        mutating func encodeNil(forKey k: Key) throws {}

        // proto3 implicit presence: a non-optional field at its zero value is
        // not on the wire, as in the reference. `-0.0 == 0`, so a negative
        // zero is skipped too, which is what the reference does.
        mutating func encode(_ v: Bool, forKey k: Key) throws { if v { try bool(v, k) } }
        mutating func encode(_ v: String, forKey k: Key) throws { if !v.isEmpty { try string(v, k) } }
        mutating func encode(_ v: Int, forKey k: Key) throws { if v != 0 { try i64(Int64(v), k) } }
        mutating func encode(_ v: Int8, forKey k: Key) throws { if v != 0 { try i64(Int64(v), k) } }
        mutating func encode(_ v: Int16, forKey k: Key) throws { if v != 0 { try i64(Int64(v), k) } }
        mutating func encode(_ v: Int32, forKey k: Key) throws { if v != 0 { try i64(Int64(v), k) } }
        mutating func encode(_ v: Int64, forKey k: Key) throws { if v != 0 { try i64(v, k) } }
        mutating func encode(_ v: UInt, forKey k: Key) throws { if v != 0 { try u64(UInt64(v), k) } }
        mutating func encode(_ v: UInt8, forKey k: Key) throws { if v != 0 { try u64(UInt64(v), k) } }
        mutating func encode(_ v: UInt16, forKey k: Key) throws { if v != 0 { try u64(UInt64(v), k) } }
        mutating func encode(_ v: UInt32, forKey k: Key) throws { if v != 0 { try u64(UInt64(v), k) } }
        mutating func encode(_ v: UInt64, forKey k: Key) throws { if v != 0 { try u64(v, k) } }
        mutating func encode(_ v: Float, forKey k: Key) throws { if v != 0 { try f32(v, k) } }
        mutating func encode(_ v: Double, forKey k: Key) throws { if v != 0 { try f64(v, k) } }

        // An `Optional` that holds a value is written whatever the value:
        // this is how a type says a proto3 `optional` field is set. A
        // synthesized `encode(to:)` calls these for an `Optional` property.
        mutating func encodeIfPresent(_ v: Bool?, forKey k: Key) throws { if let v { try bool(v, k) } }
        mutating func encodeIfPresent(_ v: String?, forKey k: Key) throws { if let v { try string(v, k) } }
        mutating func encodeIfPresent(_ v: Int?, forKey k: Key) throws { if let v { try i64(Int64(v), k) } }
        mutating func encodeIfPresent(_ v: Int8?, forKey k: Key) throws { if let v { try i64(Int64(v), k) } }
        mutating func encodeIfPresent(_ v: Int16?, forKey k: Key) throws { if let v { try i64(Int64(v), k) } }
        mutating func encodeIfPresent(_ v: Int32?, forKey k: Key) throws { if let v { try i64(Int64(v), k) } }
        mutating func encodeIfPresent(_ v: Int64?, forKey k: Key) throws { if let v { try i64(v, k) } }
        mutating func encodeIfPresent(_ v: UInt?, forKey k: Key) throws { if let v { try u64(UInt64(v), k) } }
        mutating func encodeIfPresent(_ v: UInt8?, forKey k: Key) throws { if let v { try u64(UInt64(v), k) } }
        mutating func encodeIfPresent(_ v: UInt16?, forKey k: Key) throws { if let v { try u64(UInt64(v), k) } }
        mutating func encodeIfPresent(_ v: UInt32?, forKey k: Key) throws { if let v { try u64(UInt64(v), k) } }
        mutating func encodeIfPresent(_ v: UInt64?, forKey k: Key) throws { if let v { try u64(v, k) } }
        mutating func encodeIfPresent(_ v: Float?, forKey k: Key) throws { if let v { try f32(v, k) } }
        mutating func encodeIfPresent(_ v: Double?, forKey k: Key) throws { if let v { try f64(v, k) } }
        mutating func encodeIfPresent<T: Encodable>(_ v: T?, forKey k: Key) throws { if let v { try write(v, k, set: true) } }

        mutating func encode<T: Encodable>(_ v: T, forKey k: Key) throws { try write(v, k, set: false) }

        /// Writes one value. `set` means it is written at zero too: it is an
        /// `Optional` holding a value, a repeated element, or a map entry's
        /// key or value, none of which can be read back without their record.
        mutating func write(_ v: Encodable, _ k: Key, set: Bool) throws {
            if let o = v as? _PBOptional {
                if let wrapped = o.pbWrapped { try write(wrapped, k, set: true) }
                return
            }
            switch v {
            case let x as Data: if set || !x.isEmpty { try tag(k, .bytes); Protowire.appendBytes(&encoder.data, x) }
            case let x as _PBZigZag: if set || !x.pbIsZero { try tag(k, .varint); Protowire.appendVarint(&encoder.data, x.pbZigZag) }
            case let x as String: if set || !x.isEmpty { try string(x, k) }
            case let x as Bool: if set || x { try bool(x, k) }
            case let x as Int: if set || x != 0 { try i64(Int64(x), k) }
            case let x as Int8: if set || x != 0 { try i64(Int64(x), k) }
            case let x as Int16: if set || x != 0 { try i64(Int64(x), k) }
            case let x as Int32: if set || x != 0 { try i64(Int64(x), k) }
            case let x as Int64: if set || x != 0 { try i64(x, k) }
            case let x as UInt: if set || x != 0 { try u64(UInt64(x), k) }
            case let x as UInt8: if set || x != 0 { try u64(UInt64(x), k) }
            case let x as UInt16: if set || x != 0 { try u64(UInt64(x), k) }
            case let x as UInt32: if set || x != 0 { try u64(UInt64(x), k) }
            case let x as UInt64: if set || x != 0 { try u64(x, k) }
            case let x as Float: if set || x != 0 { try f32(x, k) }
            case let x as Double: if set || x != 0 { try f64(x, k) }
            default: try writeComposite(v, k, set: set)
            }
        }

        private mutating func writeComposite(_ v: Encodable, _ k: Key, set: Bool) throws {
            let m = Mirror(reflecting: v)
            if m.displayStyle == .enum {
                let sub = encoder.peer(); try v.encode(to: sub)
                if set || sub.data != Data([0]) { try tag(k, .varint); encoder.data.append(sub.data) }
                return
            }
            if m.displayStyle == .collection {
                // An empty list has no wire form, set or not.
                if m.children.isEmpty { return }
                if let at = type(of: v) as? _PBArray.Type, isPackable(at.elementType) {
                    let sub = encoder.peer()
                    for c in m.children {
                        if let z = c.value as? _PBZigZag { Protowire.appendVarint(&sub.data, z.pbZigZag) }
                        else if let e = c.value as? Encodable { try e.encode(to: sub) }
                    }
                    try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data); return
                }
                for c in m.children { if let e = c.value as? Encodable { try writeElement(e, k) } }
                return
            }
            if m.displayStyle == .dictionary {
                for c in m.children {
                    let p = Mirror(reflecting: c.value).children
                    var key: Encodable?, val: Encodable?
                    for sc in p { if sc.label == "key" { key = sc.value as? Encodable } else if sc.label == "value" { val = sc.value as? Encodable } }
                    if let key = key, let val = val {
                        let sub = try encoder.descend(v, k); try sub.encodeEntry(key: key, value: val)
                        try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data)
                    }
                }
                return
            }
            // A message is written even when it is empty, because a
            // non-optional message field is a set one: the reference writes
            // the same record for a struct value, and only a nil is absent.
            let sub = try encoder.descend(v, k); try v.encode(to: sub); try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data)
        }

        /// A list element or map value. Neither is nullable on the wire, so a
        /// nil is written as its type's zero value, as the reference writes a
        /// nil one: a list keeps its length and a map entry its value field.
        mutating func writeElement(_ v: Encodable, _ k: Key) throws {
            if let o = v as? _PBOptional, o.pbWrapped == nil {
                try writeZero(type(of: o).pbWrappedType, k)
            } else {
                try write(v, k, set: true)
            }
        }

        /// The zero value of `t`, written as set. A message's is the empty
        /// message, which is also what any type not listed here is taken for.
        private mutating func writeZero(_ t: Any.Type, _ k: Key) throws {
            switch t {
            case is Data.Type: try tag(k, .bytes); Protowire.appendBytes(&encoder.data, Data())
            case is String.Type: try string("", k)
            case is Bool.Type: try bool(false, k)
            case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type: try i64(0, k)
            case is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type: try u64(0, k)
            case is SInt32.Type, is SInt64.Type: try u64(0, k) // zigzag(0) is 0
            case is Float.Type: try f32(0, k)
            case is Double.Type: try f64(0, k)
            case let o as _PBOptional.Type: try writeZero(o.pbWrappedType, k)
            case is any RawRepresentable.Type: try u64(0, k)
            default: try tag(k, .bytes); Protowire.appendBytes(&encoder.data, Data())
            }
        }

        /// A value with no tag is not protobuf, so a key with no field number
        /// is an error: a type with synthesized string CodingKeys has none.
        private mutating func tag(_ k: Key, _ t: Protowire.WireType) throws {
            guard let n = k.intValue else {
                throw EncodingError.invalidValue(k.stringValue, .init(codingPath: codingPath + [k],
                    debugDescription: "PB: key \"\(k.stringValue)\" has no field number; protobuf needs Int CodingKeys"))
            }
            guard let number = Int32(exactly: n) else {
                throw EncodingError.invalidValue(n, .init(codingPath: codingPath + [k],
                    debugDescription: "PB: field number \(n) does not fit an Int32"))
            }
            Protowire.appendTag(&encoder.data, number: number, type: t)
        }
        private mutating func bool(_ v: Bool, _ k: Key) throws { try tag(k, .varint); Protowire.appendVarint(&encoder.data, v ? 1 : 0) }
        private mutating func string(_ v: String, _ k: Key) throws { try tag(k, .bytes); Protowire.appendString(&encoder.data, v) }
        private mutating func i64(_ v: Int64, _ k: Key) throws { try tag(k, .varint); Protowire.appendVarint(&encoder.data, UInt64(bitPattern: v)) }
        private mutating func u64(_ v: UInt64, _ k: Key) throws { try tag(k, .varint); Protowire.appendVarint(&encoder.data, v) }
        private mutating func f32(_ v: Float, _ k: Key) throws { try tag(k, .fixed32); Protowire.appendFixed32(&encoder.data, v.bitPattern) }
        private mutating func f64(_ v: Double, _ k: Key) throws { try tag(k, .fixed64); Protowire.appendFixed64(&encoder.data, v.bitPattern) }

        mutating func nestedContainer<N: CodingKey>(keyedBy t: N.Type, forKey k: Key) -> KeyedEncodingContainer<N> { fatalError() }
        mutating func nestedUnkeyedContainer(forKey k: Key) -> UnkeyedEncodingContainer { fatalError() }
        mutating func superEncoder() -> Encoder { encoder }
        mutating func superEncoder(forKey k: Key) -> Encoder { encoder }
    }

    struct UnkeyedContainer: UnkeyedEncodingContainer {
        var encoder: _PBEncoder; var codingPath: [CodingKey] = []; var count: Int = 0
        mutating func encodeNil() throws {}
        mutating func encode<T: Encodable>(_ v: T) throws {
            throw EncodingError.invalidValue(v, .init(codingPath: codingPath,
                debugDescription: "PB: top-level unkeyed encoding is not supported"))
        }
        mutating func nestedContainer<N: CodingKey>(keyedBy t: N.Type) -> KeyedEncodingContainer<N> { fatalError() }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { fatalError() }
        mutating func superEncoder() -> Encoder { encoder }
    }

    func encodeEntry(key: Encodable, value: Encodable) throws {
        // Both fields, zero or not (protowire#295).
        var c = KeyedContainer<PB.MapKey>(encoder: self); try c.writeElement(key, .key); try c.writeElement(value, .value)
    }
}

extension _PBEncoder: SingleValueEncodingContainer {
    func encodeNil() throws {}
    func encode(_ v: Bool) throws { Protowire.appendVarint(&data, v ? 1 : 0) }
    func encode(_ v: String) throws { Protowire.appendString(&data, v) }
    func encode(_ v: Double) throws { Protowire.appendFixed64(&data, v.bitPattern) }
    func encode(_ v: Float) throws { Protowire.appendFixed32(&data, v.bitPattern) }
    func encode(_ v: Int) throws { Protowire.appendVarint(&data, UInt64(bitPattern: Int64(v))) }
    func encode(_ v: Int8) throws { Protowire.appendVarint(&data, UInt64(bitPattern: Int64(v))) }
    func encode(_ v: Int16) throws { Protowire.appendVarint(&data, UInt64(bitPattern: Int64(v))) }
    func encode(_ v: Int32) throws { Protowire.appendVarint(&data, UInt64(bitPattern: Int64(v))) }
    func encode(_ v: Int64) throws { Protowire.appendVarint(&data, UInt64(bitPattern: v)) }
    func encode(_ v: UInt) throws { Protowire.appendVarint(&data, UInt64(v)) }
    func encode(_ v: UInt8) throws { Protowire.appendVarint(&data, UInt64(v)) }
    func encode(_ v: UInt16) throws { Protowire.appendVarint(&data, UInt64(v)) }
    func encode(_ v: UInt32) throws { Protowire.appendVarint(&data, UInt64(v)) }
    func encode(_ v: UInt64) throws { Protowire.appendVarint(&data, v) }
    func encode<T: Encodable>(_ v: T) throws { try v.encode(to: self) }
}

// MARK: - Decoder

/// A decoder that deserializes `Decodable` types from Protobuf binary format.
public final class PBDecoder {
    /// The limits for each decode call; the `Hardening` constants by default.
    public var limits = Hardening.Limits()

    /// Initializes a new `PBDecoder`.
    public init() {}
    
    /// Decodes a value of the given type from Protobuf binary format.
    /// - Parameters:
    ///   - t: The type of value to decode.
    ///   - d: The data to decode from.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ t: T.Type, from d: Data) throws -> T {
        try limits.checkMessageSize(d.count)
        let dec = try _PBDecoder(data: d, limits: limits)
        return try T(from: dec)
    }
}

/// A field's record on the wire: the wire type its tag gives, and its value.
private struct PBRecord {
    let wire: Protowire.WireType
    let data: Data
}

/// The wire types a field of a Swift type is read from (#97,
/// trendvidia/protowire#614): the one `PBEncoder` writes it with and, for a
/// list of numbers, the packed form. A record with any other wire type is
/// not that field's value, so it is skipped as protobuf skips an unknown
/// field, and the field is left as it was.
private struct PBWireTypes {
    let wire: Protowire.WireType
    let packed: Bool

    init(_ t: Any.Type) {
        if !(t is Data.Type), let at = t as? _PBArray.Type {
            wire = pbWireType(of: at.elementType)
            packed = wire != .bytes
        } else {
            wire = pbWireType(of: t)
            packed = false
        }
    }

    func accepts(_ w: Protowire.WireType) -> Bool { w == wire || (packed && w == .bytes) }
}

/// The wire type a single value of `t` is written with. A type this does
/// not name is a message, written length-delimited, as are a list or a map.
private func pbWireType(of t: Any.Type) -> Protowire.WireType {
    switch t {
    case is Data.Type, is String.Type: return .bytes
    case is Bool.Type, is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
         is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type,
         is SInt32.Type, is SInt64.Type: return .varint
    case is Float.Type: return .fixed32
    case is Double.Type: return .fixed64
    case let o as _PBDecodableOptional.Type: return pbWireType(of: o.pbDecodableWrappedType)
    // An enum, as the encoder's `writeZero` takes it: its raw value's.
    case let r as any RawRepresentable.Type: return pbWireType(of: rawValueType(r))
    default: return .bytes
    }
}

private func rawValueType<R: RawRepresentable>(_: R.Type) -> Any.Type { R.RawValue.self }

/// An `Optional` read for its wrapped type: a list element or map value.
protocol _PBDecodableOptional { static var pbDecodableWrappedType: Decodable.Type { get } }
extension Optional: _PBDecodableOptional where Wrapped: Decodable {
    static var pbDecodableWrappedType: Decodable.Type { Wrapped.self }
}

private final class _PBDecoder: Decoder, _PBLimited {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]
    let data: Data
    let depth: Int
    let limits: Hardening.Limits
    /// Stands in for a field absent from the wire: every value reads as zero.
    let absent: Bool
    /// Where a corrupt field sits, for its error: " in map entry", " in BigInt".
    let context: String
    private var _fields: [Int32: [PBRecord]]?
    private var _fieldsError: Error?

    init(data: Data, depth: Int = 0, limits: Hardening.Limits, absent: Bool = false, context: String = "") throws {
        if depth > limits.maxNestingDepth {
            throw DecoderError.nestingDepthExceeded(depth, limit: limits.maxNestingDepth)
        }
        self.data = data
        self.depth = depth
        self.limits = limits
        self.absent = absent
        self.context = context
    }

    /// The value of a field the wire does not carry: proto3 omits zeros, so
    /// absent reads as zero for a non-optional property.
    func zero<T: Decodable>(_ t: T.Type) throws -> T {
        if T.self == Data.self { return Data() as! T }
        if let at = T.self as? _PBArray.Type { return at.init(elements: []) as! T }
        if let mt = T.self as? _PBMap.Type { return mt.init(entries: []) as! T }
        return try T(from: _PBDecoder(data: Data(), depth: depth + 1, limits: limits, absent: true))
    }

    /// Lazily walks the buffer once, caching either the field map or the
    /// parse error. `fieldsError` exposes the latter so throwing entry points
    /// can surface truncation rather than silently treating it as "field absent".
    private var fields: [Int32: [PBRecord]] {
        if let f = _fields { return f }
        if _fieldsError != nil { return [:] }
        do {
            let f = try Self.parseFields(data, context: context)
            _fields = f
            return f
        } catch {
            _fieldsError = error
            return [:]
        }
    }

    fileprivate var fieldsError: Error? {
        _ = fields
        return _fieldsError
    }

    /// Splits the message into its records, each checked the way protobuf
    /// skips an unknown field: a value cut short, wire type 6 or 7, or an
    /// end-group that ends nothing is corrupt, whichever field it is on.
    private static func parseFields(_ data: Data, context: String) throws -> [Int32: [PBRecord]] {
        var f: [Int32: [PBRecord]] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            guard let (number, wire, valueStart) = try? PB.readTag(data, at: i),
                  number <= Protowire.maxValidNumber else {
                throw PB.Error.corruptData
            }
            let end: Data.Index
            do {
                end = try PB.skipValue(number: number, wire: wire, data, at: valueStart)
            } catch let failure as PB.SkipFailure {
                throw DecoderError.corruptField(number: number, reason: failure.rawValue, context: context)
            }
            // Wire types 0 to 5 are all that is left; a group is kept and
            // read by no type.
            if let w = Protowire.WireType(rawValue: Int8(wire)) {
                f[number, default: []].append(PBRecord(wire: w, data: Data(data[valueStart..<end])))
            }
            i = end
        }
        return f
    }

    /// The records of field `number` that a value of type `t` is read from.
    func records(_ number: Int32, for t: Any.Type) -> [PBRecord] {
        guard let all = fields[number] else { return [] }
        let accepted = PBWireTypes(t)
        return all.filter { accepted.accepts($0.wire) }
    }

    func container<K>(keyedBy t: K.Type) -> KeyedDecodingContainer<K> { return KeyedDecodingContainer(KeyedContainer<K>(decoder: self)) }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
            debugDescription: "PB: top-level unkeyed decoding is not supported"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer { return self }

    func decodeAny(_ type: Any.Type, from record: PBRecord) throws -> Any {
        guard let (v, _) = try decodeOne(type, from: record.data, wire: record.wire) else { throw PB.Error.corruptData }
        return v
    }

    /// One value of `type` at the start of `data`, which a record of `wire`
    /// holds, and the bytes it took; nil if the bytes are not one.
    func decodeOne(_ type: Any.Type, from data: Data, wire: Protowire.WireType) throws -> (Any, Int)? {
        switch type {
        case is Data.Type: return Protowire.consumeBytes(data).map { ($0.value, $0.length) }
        case is String.Type: return Protowire.consumeString(data).map { ($0.value, $0.length) }
        case is Float.Type: return Protowire.consumeFixed32(data).map { (Float(bitPattern: $0.value), $0.length) }
        case is Double.Type: return Protowire.consumeFixed64(data).map { (Double(bitPattern: $0.value), $0.length) }
        case is Bool.Type, is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
             is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type,
             is SInt32.Type, is SInt64.Type:
            guard let (v, n) = Protowire.consumeVarint(data) else { return nil }
            return (try integer(type, v), n)
        case let o as _PBDecodableOptional.Type:
            return try decodeOne(o.pbDecodableWrappedType, from: data, wire: wire)
        case let decType as any (Decodable & RawRepresentable).Type:
            // An enum reads its raw value from the record's own bytes.
            guard let end = try? PB.skipValue(number: 1, wire: UInt8(wire.rawValue), data, at: data.startIndex) else { return nil }
            let n = end - data.startIndex
            let sub = try _PBDecoder(data: data.prefix(n), depth: depth + 1, limits: limits)
            return (try decType.init(from: sub), n)
        case let decType as Decodable.Type:
            guard wire == .bytes, let (bytes, n) = Protowire.consumeBytes(data) else { return nil }
            let sub = try _PBDecoder(data: bytes, depth: depth + 1, limits: limits, context: messageContext(type))
            return (try decType.init(from: sub), n)
        default:
            return nil
        }
    }

    /// A varint as `type`. One too wide for the Swift type is an error, never
    /// a trap, and a zigzag one too wide for sint32 is too, as for int32.
    private func integer(_ type: Any.Type, _ v: UInt64) throws -> Any {
        switch type {
        case is Bool.Type: return v != 0
        case is Int.Type: return Int(Int64(bitPattern: v))
        case is Int8.Type: return try narrow(Int8(exactly: Int64(bitPattern: v)))
        case is Int16.Type: return try narrow(Int16(exactly: Int64(bitPattern: v)))
        case is Int32.Type: return try narrow(Int32(exactly: Int64(bitPattern: v)))
        case is Int64.Type: return Int64(bitPattern: v)
        case is UInt.Type: return try narrow(UInt(exactly: v))
        case is UInt8.Type: return try narrow(UInt8(exactly: v))
        case is UInt16.Type: return try narrow(UInt16(exactly: v))
        case is UInt32.Type: return try narrow(UInt32(exactly: v))
        case is SInt32.Type: return SInt32(try narrow(Int32(exactly: Protowire.decodeZigZag(v))))
        case is SInt64.Type: return SInt64(Protowire.decodeZigZag(v))
        default: return v
        }
    }

    private func narrow<T>(_ v: T?) throws -> T {
        guard let v else { throw PB.Error.corruptData }
        return v
    }

    struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        var decoder: _PBDecoder; var codingPath: [CodingKey] = []; var allKeys: [Key] { [] }
        func contains(_ k: Key) -> Bool {
            // If the field walker errored on truncated input, route every key through
            // the throwing decode/decodeNil paths so the error surfaces. Otherwise the
            // stdlib's default `decodeIfPresent` short-circuits on `!contains(k)`,
            // silently producing nil for what is actually corrupt data.
            if decoder.fieldsError != nil { return true }
            guard let n = k.intValue else { return false }
            return decoder.fields[Int32(n)] != nil
        }
        func decodeNil(forKey k: Key) throws -> Bool {
            if let err = decoder.fieldsError { throw err }
            return !contains(k)
        }

        /// The field's records that a `t` is read from. Records of another
        /// wire type are skipped, so a field with only those is absent.
        private func records(_ t: Any.Type, _ k: Key) throws -> [PBRecord] {
            if let err = decoder.fieldsError { throw err }
            guard let n = k.intValue else { throw PB.Error.corruptData }
            return decoder.records(Int32(n), for: t)
        }
        /// A scalar field, which reads as `zero` when it is not on the wire.
        private func scalar<T>(_ t: T.Type, _ k: Key, zero: T) throws -> T {
            guard let last = try records(t, k).last else { return zero }
            return try decoder.decodeAny(t, from: last) as! T
        }
        func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { try scalar(t, k, zero: false) }
        func decode(_ t: String.Type, forKey k: Key) throws -> String { try scalar(t, k, zero: "") }
        func decode(_ t: Int.Type, forKey k: Key) throws -> Int { try scalar(t, k, zero: 0) }
        func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { try scalar(t, k, zero: 0) }
        func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { try scalar(t, k, zero: 0) }
        func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { try scalar(t, k, zero: 0) }
        func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { try scalar(t, k, zero: 0) }
        func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { try scalar(t, k, zero: 0) }
        func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { try scalar(t, k, zero: 0) }
        func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { try scalar(t, k, zero: 0) }
        func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { try scalar(t, k, zero: 0) }
        func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { try scalar(t, k, zero: 0) }
        func decode(_ t: Float.Type, forKey k: Key) throws -> Float { try scalar(t, k, zero: 0) }
        func decode(_ t: Double.Type, forKey k: Key) throws -> Double { try scalar(t, k, zero: 0) }

        // An Optional property is nil unless a record of its wire type is
        // there. The stdlib's defaults would ask `contains`, which cannot
        // tell a skipped record from a read one.
        private func present<T>(_ t: T.Type, _ k: Key, _ read: () throws -> T) throws -> T? {
            try records(t, k).isEmpty ? nil : try read()
        }
        func decodeIfPresent(_ t: Bool.Type, forKey k: Key) throws -> Bool? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: String.Type, forKey k: Key) throws -> String? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Int.Type, forKey k: Key) throws -> Int? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Int8.Type, forKey k: Key) throws -> Int8? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Int16.Type, forKey k: Key) throws -> Int16? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Int32.Type, forKey k: Key) throws -> Int32? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Int64.Type, forKey k: Key) throws -> Int64? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: UInt.Type, forKey k: Key) throws -> UInt? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: UInt8.Type, forKey k: Key) throws -> UInt8? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: UInt16.Type, forKey k: Key) throws -> UInt16? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: UInt32.Type, forKey k: Key) throws -> UInt32? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: UInt64.Type, forKey k: Key) throws -> UInt64? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Float.Type, forKey k: Key) throws -> Float? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent(_ t: Double.Type, forKey k: Key) throws -> Double? { try present(t, k) { try decode(t, forKey: k) } }
        func decodeIfPresent<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T? { try present(t, k) { try decode(t, forKey: k) } }

        func decode<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T {
            let rs = try records(t, k)
            guard let last = rs.last else { return try decoder.zero(t) }
            if let at = T.self as? _PBArray.Type {
                let element = pbWireType(of: at.elementType)
                var elements: [Any] = []
                for r in rs {
                    if r.wire == .bytes && element != .bytes {
                        // The packed form: the elements back to back, each
                        // of which must be whole.
                        var rem = Protowire.consumeBytes(r.data)?.value ?? Data()
                        while !rem.isEmpty {
                            guard let (val, n) = try decoder.decodeOne(at.elementType, from: rem, wire: element) else {
                                throw PB.Error.corruptData
                            }
                            try decoder.limits.checkRepeated(count: elements.count)
                            elements.append(val); rem = rem.advanced(by: n)
                        }
                    } else {
                        try decoder.limits.checkRepeated(count: elements.count)
                        elements.append(try decoder.decodeAny(at.elementType, from: r))
                    }
                }
                return at.init(elements: elements) as! T
            }
            if let mt = T.self as? _PBMap.Type {
                var es: [(Any, Any)] = []
                for r in rs {
                    try decoder.limits.checkRepeated(count: es.count)
                    let eb = Protowire.consumeBytes(r.data)?.value ?? Data()
                    let sub = try _PBDecoder(data: eb, depth: decoder.depth + 1, limits: decoder.limits, context: " in map entry")
                    es.append((try sub.entryPart(1, mt.keyType), try sub.entryPart(2, mt.valueType)))
                }
                return mt.init(entries: es) as! T
            }
            return try decoder.decodeAny(T.self, from: last) as! T
        }

        func nestedContainer<N: CodingKey>(keyedBy t: N.Type, forKey k: Key) throws -> KeyedDecodingContainer<N> {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                debugDescription: "PB: nested keyed containers are decoded inline; this entry point is unused"))
        }
        func nestedUnkeyedContainer(forKey k: Key) throws -> UnkeyedDecodingContainer {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                debugDescription: "PB: nested unkeyed containers are decoded inline; this entry point is unused"))
        }
        func superDecoder() throws -> Decoder { decoder }
        func superDecoder(forKey k: Key) throws -> Decoder { decoder }
    }

    /// A map entry's key (1) or value (2). One the entry does not carry, or
    /// carries with another wire type, is its type's zero, as protobuf reads
    /// it: for a message, the empty one.
    func entryPart(_ tag: Int32, _ type: Decodable.Type) throws -> Any {
        if let err = fieldsError { throw err }
        guard let r = records(tag, for: type).last else { return try zero(type) }
        return try decodeAny(type, from: r)
    }
}

/// Where a big-number message's corrupt field sits, as protowire-go names it.
private func messageContext(_ t: Any.Type) -> String {
    switch t {
    case is Pxf_BigInt.Type: return " in BigInt"
    case is Pxf_Decimal.Type: return " in Decimal"
    case is Pxf_BigFloat.Type: return " in BigFloat"
    default: return ""
    }
}

extension _PBDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool { false }
    /// The value this decoder holds whole: an enum's raw value, or the one
    /// value a single-value type writes into its message.
    private func value<T>(_ t: T.Type, zero: T) throws -> T {
        if absent { return zero }
        guard let (v, _) = try decodeOne(t, from: data, wire: pbWireType(of: t)) else { throw PB.Error.corruptData }
        return v as! T
    }
    func decode(_ t: Bool.Type) throws -> Bool { try value(t, zero: false) }
    func decode(_ t: String.Type) throws -> String { try value(t, zero: "") }
    func decode(_ t: Double.Type) throws -> Double { try value(t, zero: 0) }
    func decode(_ t: Float.Type) throws -> Float { try value(t, zero: 0) }
    func decode(_ t: Int.Type) throws -> Int { try value(t, zero: 0) }
    func decode(_ t: Int8.Type) throws -> Int8 { try value(t, zero: 0) }
    func decode(_ t: Int16.Type) throws -> Int16 { try value(t, zero: 0) }
    func decode(_ t: Int32.Type) throws -> Int32 { try value(t, zero: 0) }
    func decode(_ t: Int64.Type) throws -> Int64 { try value(t, zero: 0) }
    func decode(_ t: UInt.Type) throws -> UInt { try value(t, zero: 0) }
    func decode(_ t: UInt8.Type) throws -> UInt8 { try value(t, zero: 0) }
    func decode(_ t: UInt16.Type) throws -> UInt16 { try value(t, zero: 0) }
    func decode(_ t: UInt32.Type) throws -> UInt32 { try value(t, zero: 0) }
    func decode(_ t: UInt64.Type) throws -> UInt64 { try value(t, zero: 0) }
    func decode<T: Decodable>(_ t: T.Type) throws -> T { return try T(from: self) }
}

// MARK: - Skipping a field, as protobuf does

extension PB {
    /// Why a field's value cannot be skipped, in protobuf-go's words
    /// (`protowire.ParseError`), so the error reads as protowire-go's does.
    enum SkipFailure: String, Swift.Error {
        case truncated = "unexpected EOF"
        case fieldNumber = "proto: invalid field number"
        case overflow = "proto: variable length integer overflow"
        case reserved = "proto: cannot parse reserved wire type"
        case endGroup = "proto: mismatching end group marker"
        case tooDeep = "proto: parse error"
    }

    /// How deep groups nest inside one skipped group, as protobuf-go's
    /// `protowire.ConsumeFieldValue` allows (`DefaultRecursionLimit`).
    static let maxGroupDepth = 10_000

    /// A varint at `i`, as protobuf-go's `ConsumeVarint` reads one: at most
    /// ten bytes, the tenth no more than 1.
    static func readVarint(_ d: Data, at i: Data.Index) throws -> (value: UInt64, end: Data.Index) {
        var v: UInt64 = 0
        var j = i
        for k in 0..<9 {
            guard j < d.endIndex else { throw SkipFailure.truncated }
            let b = d[j]
            j += 1
            v |= UInt64(b & 0x7f) << (7 * k)
            if b < 0x80 { return (v, j) }
        }
        guard j < d.endIndex else { throw SkipFailure.truncated }
        guard d[j] < 2 else { throw SkipFailure.overflow }
        return (v | UInt64(d[j]) << 63, j + 1)
    }

    /// A tag at `i`, as protobuf-go's `ConsumeTag` reads one: any wire type,
    /// and a field number from 1 to `Int32.max`.
    static func readTag(_ d: Data, at i: Data.Index) throws -> (number: Int32, wire: UInt8, end: Data.Index) {
        let (v, end) = try readVarint(d, at: i)
        guard let number = Int32(exactly: v >> 3), number >= 1 else { throw SkipFailure.fieldNumber }
        return (number, UInt8(v & 7), end)
    }

    /// The end of field `number`'s value, which starts at `i`, found as
    /// protobuf-go's `ConsumeFieldValue` finds it: wire types 6 and 7, an
    /// end-group that ends nothing or another group, and a value cut short
    /// are refused. A group is followed with a list rather than by recursion.
    static func skipValue(number: Int32, wire: UInt8, _ d: Data, at i: Data.Index) throws -> Data.Index {
        func fixed(_ width: Int) throws -> Data.Index {
            guard d.endIndex - i >= width else { throw SkipFailure.truncated }
            return i + width
        }
        switch wire {
        case 0: return try readVarint(d, at: i).end
        case 1: return try fixed(8)
        case 2:
            let (length, start) = try readVarint(d, at: i)
            guard length <= UInt64(d.endIndex - start) else { throw SkipFailure.truncated }
            return start + Int(length)
        case 5: return try fixed(4)
        case 3:
            var open: [Int32] = [number]
            var j = i
            while let innermost = open.last {
                let (inner, innerWire, next) = try readTag(d, at: j)
                j = next
                switch innerWire {
                case 4:
                    guard inner == innermost else { throw SkipFailure.endGroup }
                    open.removeLast()
                case 3:
                    guard open.count <= maxGroupDepth else { throw SkipFailure.tooDeep }
                    open.append(inner)
                default:
                    j = try skipValue(number: inner, wire: innerWire, d, at: j)
                }
            }
            return j
        case 4: throw SkipFailure.endGroup
        default: throw SkipFailure.reserved
        }
    }
}

private func isPackable(_ type: Any.Type) -> Bool {
    return type is Int.Type || type is Int8.Type || type is Int16.Type || type is Int32.Type || type is Int64.Type ||
           type is UInt.Type || type is UInt16.Type || type is UInt32.Type || type is UInt64.Type ||
           type is Bool.Type || type is Float.Type || type is Double.Type ||
           type is SInt32.Type || type is SInt64.Type ||
           "\(type)".contains("Status") // Heuristic for our test enum
}
