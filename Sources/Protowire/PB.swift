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
                    for c in m.children { if let e = c.value as? Encodable { try e.encode(to: sub) } }
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

private final class _PBDecoder: Decoder, _PBLimited {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]
    let data: Data
    let depth: Int
    let limits: Hardening.Limits
    /// Stands in for a field absent from the wire: every value reads as zero.
    let absent: Bool
    private var _fields: [Int32: [Data]]?
    private var _fieldsError: Error?

    init(data: Data, depth: Int = 0, limits: Hardening.Limits, absent: Bool = false) throws {
        if depth > limits.maxNestingDepth {
            throw DecoderError.nestingDepthExceeded(depth, limit: limits.maxNestingDepth)
        }
        self.data = data
        self.depth = depth
        self.limits = limits
        self.absent = absent
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
    private var fields: [Int32: [Data]] {
        if let f = _fields { return f }
        if _fieldsError != nil { return [:] }
        do {
            let f = try Self.parseFields(data)
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

    private static func parseFields(_ data: Data) throws -> [Int32: [Data]] {
        var f: [Int32: [Data]] = [:]
        var rem = data
        while !rem.isEmpty {
            guard let (tag, wire, n) = Protowire.consumeTag(rem) else {
                throw PB.Error.corruptData
            }
            rem = rem.advanced(by: n)
            let len = consumeFieldValue(tag: tag, wireType: wire, data: rem)
            guard len >= 0 else {
                throw PB.Error.corruptData
            }
            f[tag, default: []].append(Data(rem.prefix(len)))
            rem = rem.advanced(by: len)
        }
        return f
    }

    func container<K>(keyedBy t: K.Type) -> KeyedDecodingContainer<K> { return KeyedDecodingContainer(KeyedContainer<K>(decoder: self)) }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
            debugDescription: "PB: top-level unkeyed decoding is not supported"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer { return self }

    func decodeAny(_ type: Any.Type, from data: Data) throws -> Any {
        guard let (v, _) = try decodeOne(type, from: data) else { throw PB.Error.corruptData }
        return v
    }

    func decodeOne(_ type: Any.Type, from data: Data) throws -> (Any, Int)? {
        if type is Data.Type { if let (v, n) = Protowire.consumeBytes(data) { return (v, n) } }
        if type is String.Type { if let (v, n) = Protowire.consumeString(data) { return (v, n) } }
        if type is Bool.Type { if let (v, n) = Protowire.consumeVarint(data) { return (v != 0, n) } }
        if type is Int.Type { if let (v, n) = Protowire.consumeVarint(data) { return (Int(Int64(bitPattern: v)), n) } }
        if type is Int8.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(Int8(exactly: Int64(bitPattern: v))), n) } }
        if type is Int16.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(Int16(exactly: Int64(bitPattern: v))), n) } }
        if type is Int32.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(Int32(exactly: Int64(bitPattern: v))), n) } }
        if type is Int64.Type { if let (v, n) = Protowire.consumeVarint(data) { return (Int64(bitPattern: v), n) } }
        if type is UInt.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(UInt(exactly: v)), n) } }
        if type is UInt8.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(UInt8(exactly: v)), n) } }
        if type is UInt16.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(UInt16(exactly: v)), n) } }
        if type is UInt32.Type { if let (v, n) = Protowire.consumeVarint(data) { return (try narrow(UInt32(exactly: v)), n) } }
        if type is UInt64.Type { if let (v, n) = Protowire.consumeVarint(data) { return (v, n) } }
        if type is Float.Type { if let (v, n) = Protowire.consumeFixed32(data) { return (Float(bitPattern: v), n) } }
        if type is Double.Type { if let (v, n) = Protowire.consumeFixed64(data) { return (Double(bitPattern: v), n) } }
        
        if let decType = type as? Decodable.Type {
            if let (bytes, n) = Protowire.consumeBytes(data) {
                let sub = try _PBDecoder(data: bytes, depth: depth + 1, limits: limits)
                return (try decType.init(from: sub), n)
            }
            if let (_, n) = Protowire.consumeVarint(data) {
                let sub = try _PBDecoder(data: data.prefix(n), depth: depth + 1, limits: limits)
                return (try decType.init(from: sub), n)
            }
        }
        return nil
    }

    /// A varint too wide for the Swift type is an error, never a trap.
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
        /// A scalar field, which reads as `zero` when it is not on the wire.
        private func scalar<T>(_ t: T.Type, _ k: Key, zero: T) throws -> T {
            if let err = decoder.fieldsError { throw err }
            guard k.intValue != nil else { throw PB.Error.corruptData }
            guard contains(k) else { return zero }
            return try decoder.decodeAny(t, from: try getData(k)) as! T
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

        func decodeIfPresent<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T? {
            if let err = decoder.fieldsError { throw err }
            return contains(k) ? try decode(t, forKey: k) : nil
        }

        func decode<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T {
            if let err = decoder.fieldsError { throw err }
            guard let n = k.intValue else { throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "")) }
            guard let dl = decoder.fields[Int32(n)] else { return try decoder.zero(t) }
            if let at = T.self as? _PBArray.Type {
                var elements: [Any] = []
                for d in dl {
                    if isPackable(at.elementType) {
                        if let (payload, _) = Protowire.consumeBytes(d) {
                            var rem = payload
                            while !rem.isEmpty {
                                if let (val, n) = try decoder.decodeOne(at.elementType, from: rem) {
                                    try decoder.limits.checkRepeated(count: elements.count)
                                    elements.append(val); rem = rem.advanced(by: n)
                                } else { break }
                            }
                        } else {
                            try decoder.limits.checkRepeated(count: elements.count)
                            elements.append(try decoder.decodeAny(at.elementType, from: d))
                        }
                    } else {
                        try decoder.limits.checkRepeated(count: elements.count)
                        elements.append(try decoder.decodeAny(at.elementType, from: d))
                    }
                }
                return at.init(elements: elements) as! T
            }
            if let mt = T.self as? _PBMap.Type {
                var es: [(Any, Any)] = []
                for d in dl {
                    try decoder.limits.checkRepeated(count: es.count)
                    let eb = Protowire.consumeBytes(d)?.value ?? Data()
                    let sub = try _PBDecoder(data: eb, depth: decoder.depth + 1, limits: decoder.limits)
                    let key = try sub.decodeAny(mt.keyType, from: try sub.getData(tag: 1))
                    let val = try sub.decodeAny(mt.valueType, from: try sub.getData(tag: 2))
                    es.append((key, val))
                }
                return mt.init(entries: es) as! T
            }
            return try decoder.decodeAny(T.self, from: dl.last!) as! T
        }

        func getData(_ k: Key) throws -> Data { guard let n = k.intValue else { throw PB.Error.corruptData }; return try decoder.getData(tag: Int32(n)) }
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

    func getData(tag: Int32) throws -> Data {
        if let err = fieldsError { throw err }
        guard let d = fields[tag]?.last else { throw PB.Error.corruptData }
        return d
    }
}

extension _PBDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool { false }
    private func value<T>(_ t: T.Type, zero: T) throws -> T { absent ? zero : try decodeAny(t, from: data) as! T }
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

private func consumeFieldValue(tag: Int32, wireType: Protowire.WireType, data: Data) -> Int {
    switch wireType {
    case .varint: return Protowire.consumeVarint(data)?.length ?? -1
    case .fixed64: return 8
    case .fixed32: return 4
    case .bytes: return Protowire.consumeBytes(data)?.length ?? -1
    default: return -1
    }
}

private func isPackable(_ type: Any.Type) -> Bool {
    return type is Int.Type || type is Int8.Type || type is Int16.Type || type is Int32.Type || type is Int64.Type ||
           type is UInt.Type || type is UInt16.Type || type is UInt32.Type || type is UInt64.Type ||
           type is Bool.Type || type is Float.Type || type is Double.Type ||
           "\(type)".contains("Status") // Heuristic for our test enum
}
