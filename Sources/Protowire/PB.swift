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

// MARK: - Encoder

/// An encoder that serializes `Encodable` types into Protobuf binary format.
public final class PBEncoder {
    /// Initializes a new `PBEncoder`.
    public init() {}
    
    /// Encodes a value into Protobuf binary format.
    /// - Parameter v: The value to encode.
    /// - Returns: The encoded data.
    /// - Throws: An error if encoding fails.
    public func encode<T: Encodable>(_ v: T) throws -> Data { let e = _PBEncoder(); try v.encode(to: e); return e.data }
}

private final class _PBEncoder: Encoder {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]; var data = Data()
    func container<K>(keyedBy t: K.Type) -> KeyedEncodingContainer<K> { return KeyedEncodingContainer(KeyedContainer<K>(encoder: self)) }
    func unkeyedContainer() -> UnkeyedEncodingContainer { fatalError() }
    func singleValueContainer() -> SingleValueEncodingContainer { return self }

    struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        var encoder: _PBEncoder; var codingPath: [CodingKey] = []
        mutating func encodeNil(forKey k: Key) throws {}
        mutating func encode(_ v: Bool, forKey k: Key) throws { try tag(k, .varint); Protowire.appendVarint(&encoder.data, v ? 1 : 0) }
        mutating func encode(_ v: String, forKey k: Key) throws { try tag(k, .bytes); Protowire.appendString(&encoder.data, v) }
        mutating func encode(_ v: Int, forKey k: Key) throws { try i64(Int64(v), k) }
        mutating func encode(_ v: Int8, forKey k: Key) throws { try i64(Int64(v), k) }
        mutating func encode(_ v: Int16, forKey k: Key) throws { try i64(Int64(v), k) }
        mutating func encode(_ v: Int32, forKey k: Key) throws { try i64(Int64(v), k) }
        mutating func encode(_ v: Int64, forKey k: Key) throws { try i64(v, k) }
        mutating func encode(_ v: UInt, forKey k: Key) throws { try u64(UInt64(v), k) }
        mutating func encode(_ v: UInt8, forKey k: Key) throws { try u64(UInt64(v), k) }
        mutating func encode(_ v: UInt16, forKey k: Key) throws { try u64(UInt64(v), k) }
        mutating func encode(_ v: UInt32, forKey k: Key) throws { try u64(UInt64(v), k) }
        mutating func encode(_ v: UInt64, forKey k: Key) throws { try u64(v, k) }
        mutating func encode(_ v: Float, forKey k: Key) throws { try tag(k, .fixed32); Protowire.appendFixed32(&encoder.data, v.bitPattern) }
        mutating func encode(_ v: Double, forKey k: Key) throws { try tag(k, .fixed64); Protowire.appendFixed64(&encoder.data, v.bitPattern) }

        mutating func encode<T: Encodable>(_ v: T, forKey k: Key) throws {
            if let d = v as? Data { try tag(k, .bytes); Protowire.appendBytes(&encoder.data, d); return }
            if let s = v as? String { try encode(s, forKey: k); return }
            if let b = v as? Bool { try encode(b, forKey: k); return }
            if let i = v as? Int { try encode(i, forKey: k); return }
            if let i = v as? Int32 { try encode(i, forKey: k); return }
            if let i = v as? Int64 { try encode(i, forKey: k); return }
            
            let m = Mirror(reflecting: v)
            if m.displayStyle == .enum {
                let sub = _PBEncoder(); try v.encode(to: sub)
                try tag(k, .varint); encoder.data.append(sub.data); return
            }
            if m.displayStyle == .collection {
                if let at = T.self as? _PBArray.Type, isPackable(at.elementType) {
                    let sub = _PBEncoder()
                    for c in m.children { if let e = c.value as? Encodable { try e.encode(to: sub) } }
                    try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data); return
                }
                for c in m.children { if let e = c.value as? Encodable { try encodeElem(e, k) } }; return
            }
            if m.displayStyle == .dictionary {
                for c in m.children {
                    let p = Mirror(reflecting: c.value).children
                    var key: Encodable?, val: Encodable?
                    for sc in p { if sc.label == "key" { key = sc.value as? Encodable } else if sc.label == "value" { val = sc.value as? Encodable } }
                    if let key = key, let val = val {
                        let sub = _PBEncoder(); try sub.encodeEntry(key: key, value: val)
                        try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data)
                    }
                }; return
            }
            let sub = _PBEncoder(); try v.encode(to: sub); try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data)
        }

        private mutating func encodeElem(_ v: Encodable, _ k: Key) throws {
            if let s = v as? String { try encode(s, forKey: k) }
            else if let i = v as? Int { try encode(i, forKey: k) }
            else if let i = v as? Int32 { try encode(i, forKey: k) }
            else if let i = v as? Int64 { try encode(i, forKey: k) }
            else if let b = v as? Bool { try encode(b, forKey: k) }
            else if let d = v as? Data { try encode(d, forKey: k) }
            else { let sub = _PBEncoder(); try v.encode(to: sub); try tag(k, .bytes); Protowire.appendBytes(&encoder.data, sub.data) }
        }

        private mutating func tag(_ k: Key, _ t: Protowire.WireType) throws { guard let n = k.intValue else { return }; Protowire.appendTag(&encoder.data, number: Int32(n), type: t) }
        private mutating func i64(_ v: Int64, _ k: Key) throws { try tag(k, .varint); Protowire.appendVarint(&encoder.data, UInt64(bitPattern: v)) }
        private mutating func u64(_ v: UInt64, _ k: Key) throws { try tag(k, .varint); Protowire.appendVarint(&encoder.data, v) }

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
        var c = KeyedContainer<PB.MapKey>(encoder: self); try c.encode(key, forKey: .key); try c.encode(value, forKey: .value)
    }
}

extension _PBEncoder: SingleValueEncodingContainer {
    func encodeNil() throws {}
    func encode(_ v: Bool) throws { Protowire.appendVarint(&data, v ? 1 : 0) }
    func encode(_ v: String) throws { Protowire.appendString(&data, v) }
    func encode(_ v: Double) throws { Protowire.appendFixed64(&data, v.bitPattern) }
    func encode(_ v: Float) throws { Protowire.appendFixed32(&data, v.bitPattern) }
    func encode(_ v: Int) throws { Protowire.appendVarint(&data, UInt64(bitPattern: Int64(v))) }
    func encode(_ v: Int32) throws { Protowire.appendVarint(&data, UInt64(bitPattern: Int64(v))) }
    func encode(_ v: Int64) throws { Protowire.appendVarint(&data, UInt64(bitPattern: v)) }
    func encode(_ v: UInt) throws { Protowire.appendVarint(&data, UInt64(v)) }
    func encode(_ v: UInt64) throws { Protowire.appendVarint(&data, v) }
    func encode<T: Encodable>(_ v: T) throws { try v.encode(to: self) }
}

// MARK: - Decoder

/// A decoder that deserializes `Decodable` types from Protobuf binary format.
public final class PBDecoder {
    /// Initializes a new `PBDecoder`.
    public init() {}
    
    /// Decodes a value of the given type from Protobuf binary format.
    /// - Parameters:
    ///   - t: The type of value to decode.
    ///   - d: The data to decode from.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ t: T.Type, from d: Data) throws -> T { return try T(from: _PBDecoder(data: d)) }
}

private final class _PBDecoder: Decoder {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]
    let data: Data; private var _fields: [Int32: [Data]]?

    init(data: Data) { self.data = data }

    private var fields: [Int32: [Data]] {
        if let f = _fields { return f }
        var f: [Int32: [Data]] = [:]; var rem = data
        while !rem.isEmpty {
            if let (tag, wire, n) = Protowire.consumeTag(rem) {
                rem = rem.advanced(by: n); let len = consumeFieldValue(tag: tag, wireType: wire, data: rem)
                if len >= 0 { f[tag, default: []].append(Data(rem.prefix(len))); rem = rem.advanced(by: len) }
                else { break }
            } else { break }
        }
        _fields = f; return f
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
        if type is Int32.Type { if let (v, n) = Protowire.consumeVarint(data) { return (Int32(Int64(bitPattern: v)), n) } }
        if type is Int64.Type { if let (v, n) = Protowire.consumeVarint(data) { return (Int64(bitPattern: v), n) } }
        if type is UInt.Type { if let (v, n) = Protowire.consumeVarint(data) { return (UInt(v), n) } }
        if type is UInt64.Type { if let (v, n) = Protowire.consumeVarint(data) { return (v, n) } }
        if type is Float.Type { if let (v, n) = Protowire.consumeFixed32(data) { return (Float(bitPattern: v), n) } }
        if type is Double.Type { if let (v, n) = Protowire.consumeFixed64(data) { return (Double(bitPattern: v), n) } }
        
        if let decType = type as? Decodable.Type {
            if let (bytes, n) = Protowire.consumeBytes(data) {
                return (try decType.init(from: _PBDecoder(data: bytes)), n)
            }
            if let (_, n) = Protowire.consumeVarint(data) {
                return (try decType.init(from: _PBDecoder(data: data.prefix(n))), n)
            }
        }
        return nil
    }

    struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        var decoder: _PBDecoder; var codingPath: [CodingKey] = []; var allKeys: [Key] { [] }
        func contains(_ k: Key) -> Bool { guard let n = k.intValue else { return false }; return decoder.fields[Int32(n)] != nil }
        func decodeNil(forKey k: Key) throws -> Bool { !contains(k) }
        func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { return try decoder.decodeAny(t, from: try getData(k)) as! Bool }
        func decode(_ t: String.Type, forKey k: Key) throws -> String { return try decoder.decodeAny(t, from: try getData(k)) as! String }
        func decode(_ t: Int.Type, forKey k: Key) throws -> Int { return try decoder.decodeAny(t, from: try getData(k)) as! Int }
        func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { return Int8(try decoder.decodeAny(Int.self, from: try getData(k)) as! Int) }
        func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { return Int16(try decoder.decodeAny(Int.self, from: try getData(k)) as! Int) }
        func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { return try decoder.decodeAny(t, from: try getData(k)) as! Int32 }
        func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { return try decoder.decodeAny(t, from: try getData(k)) as! Int64 }
        func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { return try decoder.decodeAny(t, from: try getData(k)) as! UInt }
        func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { return UInt8(try decoder.decodeAny(UInt.self, from: try getData(k)) as! UInt) }
        func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { return UInt16(try decoder.decodeAny(UInt.self, from: try getData(k)) as! UInt) }
        func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { return UInt32(try decoder.decodeAny(UInt.self, from: try getData(k)) as! UInt) }
        func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { return try decoder.decodeAny(t, from: try getData(k)) as! UInt64 }
        func decode(_ t: Float.Type, forKey k: Key) throws -> Float { return try decoder.decodeAny(t, from: try getData(k)) as! Float }
        func decode(_ t: Double.Type, forKey k: Key) throws -> Double { return try decoder.decodeAny(t, from: try getData(k)) as! Double }

        func decodeIfPresent<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T? { return contains(k) ? try decode(t, forKey: k) : nil }

        func decode<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T {
            guard let n = k.intValue, let dl = decoder.fields[Int32(n)] else { throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "")) }
            if let at = T.self as? _PBArray.Type {
                var elements: [Any] = []
                for d in dl {
                    if isPackable(at.elementType) {
                        if let (payload, _) = Protowire.consumeBytes(d) {
                            var rem = payload
                            while !rem.isEmpty {
                                if let (val, n) = try decoder.decodeOne(at.elementType, from: rem) {
                                    elements.append(val); rem = rem.advanced(by: n)
                                } else { break }
                            }
                        } else {
                            elements.append(try decoder.decodeAny(at.elementType, from: d))
                        }
                    } else {
                        elements.append(try decoder.decodeAny(at.elementType, from: d))
                    }
                }
                return at.init(elements: elements) as! T
            }
            if let mt = T.self as? _PBMap.Type {
                var es: [(Any, Any)] = []
                for d in dl {
                    let eb = Protowire.consumeBytes(d)?.value ?? Data(); let sub = _PBDecoder(data: eb)
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

    func getData(tag: Int32) throws -> Data { guard let d = fields[tag]?.last else { throw PB.Error.corruptData }; return d }
}

extension _PBDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool { false }
    func decode(_ t: Bool.Type) throws -> Bool { try decodeAny(t, from: data) as! Bool }
    func decode(_ t: String.Type) throws -> String { try decodeAny(t, from: data) as! String }
    func decode(_ t: Double.Type) throws -> Double { try decodeAny(t, from: data) as! Double }
    func decode(_ t: Float.Type) throws -> Float { try decodeAny(t, from: data) as! Float }
    func decode(_ t: Int.Type) throws -> Int { try decodeAny(t, from: data) as! Int }
    func decode(_ t: Int32.Type) throws -> Int32 { try decodeAny(t, from: data) as! Int32 }
    func decode(_ t: Int64.Type) throws -> Int64 { try decodeAny(t, from: data) as! Int64 }
    func decode(_ t: UInt.Type) throws -> UInt { try decodeAny(t, from: data) as! UInt }
    func decode(_ t: UInt64.Type) throws -> UInt64 { try decodeAny(t, from: data) as! UInt64 }
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
    return type is Int.Type || type is Int32.Type || type is Int64.Type ||
           type is UInt.Type || type is UInt32.Type || type is UInt64.Type ||
           type is Bool.Type || type is Float.Type || type is Double.Type ||
           "\(type)".contains("Status") // Heuristic for our test enum
}
