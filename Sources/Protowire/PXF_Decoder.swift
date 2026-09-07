// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

struct PXFKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = Int(stringValue) }
    init(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    init(index: Int) { self.stringValue = "\(index)"; self.intValue = index }
}

/// A decoder that deserializes `Decodable` types from PXF format.
public final class PXFDecoder {
    /// An optional type resolver to handle `@type` directives (e.g., for `google.protobuf.Any`).
    public var typeResolver: PXF.TypeResolver?

    /// Schema annotations — `(pxf.required)` / `(pxf.default)` — indexed
    /// from a descriptor set. With `rootMessage` also set, decoding rejects
    /// an absent required field and hands the Swift type a synthesised
    /// value for an absent defaulted field; see `PXF.Annotations`. Nil
    /// (the default) leaves decoding exactly as before.
    public var annotations: PXF.Annotations?

    /// Fully qualified proto name of the message the document represents,
    /// e.g. `settings.v1.Settings`; the entry point into `annotations`.
    public var rootMessage: String?

    /// Initializes a new `PXFDecoder`.
    public init() {}

    /// Initializes a decoder that applies `annotations` from `rootMessage` down.
    public init(annotations: PXF.Annotations, rootMessage: String) {
        self.annotations = annotations
        self.rootMessage = rootMessage
    }

    /// The `(pxf.required)` pass, before the Swift type sees the document:
    /// it covers every field the schema declares, whether or not the type
    /// asks for it (Go's `postDecode` walks the descriptor, not the caller).
    private func validateRequired(_ entries: [PXF.Entry]) throws {
        guard let annotations, let root = rootMessage else { return }
        try annotations.validateRequired(entries: entries, message: root)
    }

    /// Decodes a value of the given type from PXF data.
    /// - Parameters:
    ///   - type: The type of value to decode.
    ///   - data: The PXF data to decode from.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let doc = try PXF.Parser(input: data).parseDocument()
        try validateRequired(doc.entries)
        let decoder = _PXFDecoder(entries: doc.entries, typeResolver: typeResolver, annotations: annotations, messageName: rootMessage)
        return try T(from: decoder)
    }

    /// Decodes a value of the given type from a PXF string.
    /// - Parameters:
    ///   - type: The type of value to decode.
    ///   - string: The PXF string to decode from.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        let doc = try PXF.Parser(string: string).parseDocument()
        try validateRequired(doc.entries)
        let decoder = _PXFDecoder(entries: doc.entries, typeResolver: typeResolver, annotations: annotations, messageName: rootMessage)
        return try T(from: decoder)
    }

    /// Decodes a value and returns both the value and a result object containing presence information.
    /// - Parameters:
    ///   - type: The type of value to decode.
    ///   - string: The PXF string to decode from.
    /// - Returns: A tuple containing the decoded value and a `PXF.Result` object.
    /// - Throws: An error if decoding fails.
    public func unmarshalFull<T: Decodable>(_ type: T.Type, from string: String) throws -> (T, PXF.Result) {
        let doc = try PXF.Parser(string: string).parseDocument()
        try validateRequired(doc.entries)
        var result = PXF.Result()
        // Surface document-root directives on the result so callers can
        // walk them after decode.
        result.directives = doc.directives
        result.datasets = doc.datasets
        result.protos = doc.protos
        // Pre-walk the document so any top-level `field = null` entries land in
        // `result.nullFields` BEFORE T's synthesized init runs. The keyed
        // container's contains/decode entry points then surface `_null` as a
        // populated [String] / Google_Protobuf_FieldMask if the user's type
        // declares it. Without this, T(from: decoder) runs first and finds an
        // empty result.
        for entry in doc.entries {
            if let a = entry as? PXF.Assignment, a.value is PXF.NullVal {
                result.markNull(path: a.key)
            }
        }
        let decoder = _PXFDecoder(entries: doc.entries, result: &result, typeResolver: typeResolver, annotations: annotations, messageName: rootMessage)
        let value = try T(from: decoder)
        return (value, result)
    }
}

private final class _PXFDecoder: Swift.Decoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    let entries: [PXF.Entry]
    private var result: UnsafeMutablePointer<PXF.Result>?
    let typeResolver: PXF.TypeResolver?
    /// Schema annotations and the proto message these entries belong to;
    /// nil when the caller gave none, or for a container the reference
    /// does not annotate (list elements, map values).
    let annotations: PXF.Annotations?
    let messageName: String?

    init(entries: [PXF.Entry], codingPath: [CodingKey] = [], result: UnsafeMutablePointer<PXF.Result>? = nil, typeResolver: PXF.TypeResolver? = nil,
         annotations: PXF.Annotations? = nil, messageName: String? = nil) {
        self.entries = entries
        self.codingPath = codingPath
        self.result = result
        self.typeResolver = typeResolver
        self.annotations = annotations
        self.messageName = messageName
    }

    /// The schema field behind `key`, when this container has a message.
    func field(for key: CodingKey) -> PXF.Annotations.Field? {
        guard let annotations, let messageName else { return nil }
        return annotations.message(messageName)?.field(named: key.stringValue)
    }

    /// A child decoder for the singular message field `key` — the one
    /// place annotations follow the descriptor down. Repeated elements and
    /// map values get a plain decoder (Go's postDecode does not descend
    /// into them either).
    func child(entries: [PXF.Entry], key: CodingKey) -> _PXFDecoder {
        let f = field(for: key)
        let sub = (f?.type == .message && f?.isRepeated == false && f?.isMap == false) ? f?.typeName : nil
        return _PXFDecoder(entries: entries, codingPath: codingPath + [key], result: result, typeResolver: typeResolver,
                           annotations: sub == nil ? nil : annotations, messageName: sub)
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> where Key: CodingKey {
        return KeyedDecodingContainer(KeyedContainer<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
            debugDescription: "PXF: cannot decode top-level message as unkeyed container"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
            debugDescription: "PXF: cannot decode top-level message as single value"))
    }

    struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        var decoder: _PXFDecoder
        var codingPath: [CodingKey] = []
        var allKeys: [Key] {
            return decoder.entries.compactMap {
                if let a = $0 as? PXF.Assignment { return Key(stringValue: a.key) }
                else if let b = $0 as? PXF.Block { return Key(stringValue: b.name) }
                else if let m = $0 as? PXF.MapEntry { return Key(stringValue: m.key) }
                else { return nil }
            }
        }

        func contains(_ k: Key) -> Bool {
            // The reserved `_null` field is synthesized from presence-tracking
            // state: when the user calls unmarshalFull and any field was set
            // to null, we let the decoder return a populated `_null` to the
            // user's struct (as either [String] or Google_Protobuf_FieldMask).
            if k.stringValue == "_null", codingPath.isEmpty,
               let result = decoder.result?.pointee,
               !result.allNullFields.isEmpty {
                return true
            }
            let present = decoder.entries.contains {
                if let a = $0 as? PXF.Assignment { return a.key == k.stringValue }
                else if let b = $0 as? PXF.Block { return b.name == k.stringValue }
                else if let m = $0 as? PXF.MapEntry { return m.key == k.stringValue }
                else { return false }
            }
            if present {
                decoder.result?.pointee.markPresent(path: path(for: k))
                return true
            }
            // Absent with a (pxf.default): the Swift type sees a value, the
            // Result still says absent (Go applies the default without
            // markPresent).
            return decoder.field(for: k)?.defaultLiteral != nil
        }

        func decodeNil(forKey k: Key) throws -> Bool {
            guard let e = documentEntry(k) else {
                // Absent: nil unless a (pxf.default) stands in — and then it
                // is still not marked present (Go applies defaults without
                // markPresent).
                return decoder.field(for: k)?.defaultLiteral == nil
            }
            var isNull = false
            if let a = e as? PXF.Assignment { isNull = a.value is PXF.NullVal }
            else if let m = e as? PXF.MapEntry { isNull = m.value is PXF.NullVal }
            
            if isNull {
                decoder.result?.pointee.markNull(path: path(for: k))
            } else {
                decoder.result?.pointee.markPresent(path: path(for: k))
            }
            return isNull
        }

        private func path(for key: Key) -> String {
            let p = codingPath + [key]
            return p.map { $0.stringValue }.joined(separator: ".")
        }
        func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { let v = try getValue(k); if let x = v as? PXF.BoolVal { return x.value } else if let x = v as? PXF.IntVal { return x.raw != "0" } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected bool or int for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        func decode(_ t: String.Type, forKey k: Key) throws -> String { let v = try getValue(k); if let x = v as? PXF.StringVal { return x.value } else if let x = v as? PXF.IdentVal { return x.name } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected string or identifier for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        func decode(_ t: Int.Type, forKey k: Key) throws -> Int { return Int(try decodeI64(k)) }
        func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { return Int8(try decodeI64(k)) }
        func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { return Int16(try decodeI64(k)) }
        func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { return Int32(try decodeI64(k)) }
        func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { return try decodeI64(k) }
        func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { return UInt(try decodeU64(k)) }
        func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { return UInt8(try decodeU64(k)) }
        func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { return UInt16(try decodeU64(k)) }
        func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { return UInt32(try decodeU64(k)) }
        func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { return try decodeU64(k) }
        func decode(_ t: Float.Type, forKey k: Key) throws -> Float { let v = try getValue(k); if let x = v as? PXF.IntVal { return Float(x.raw) ?? 0 } else if let x = v as? PXF.FloatVal { return Float(x.raw) ?? 0 } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected float or int for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        func decode(_ t: Double.Type, forKey k: Key) throws -> Double { let v = try getValue(k); if let x = v as? PXF.IntVal { return Double(x.raw) ?? 0 } else if let x = v as? PXF.FloatVal { return Double(x.raw) ?? 0 } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected double or int for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }

        private func decodeI64(_ k: Key) throws -> Int64 { let v = try getValue(k); if let x = v as? PXF.IntVal, let n = Int64(x.raw) { return n } else { throw DecodingError.typeMismatch(Int64.self, .init(codingPath: codingPath + [k], debugDescription: "Expected integer for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        private func decodeU64(_ k: Key) throws -> UInt64 { let v = try getValue(k); if let x = v as? PXF.IntVal, let n = UInt64(x.raw) { return n } else { throw DecodingError.typeMismatch(UInt64.self, .init(codingPath: codingPath + [k], debugDescription: "Expected unsigned integer for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }

        func decode<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T {
            if T.self == Data.self { let v = try getValue(k); if let x = v as? PXF.BytesVal { return x.value as! T } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected bytes (base64) for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
            if T.self == Date.self { let v = try getValue(k); if let x = v as? PXF.TimestampVal { return x.value as! T } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected timestamp for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }

            // Synthetic `_null` at the top of the message: hand the user the
            // null-paths tracked by the Result. This is the read side of the
            // FieldMask round-trip. Encoder side (PXF_Encoder.encode<T>) walks
            // the user's `_null` field via Mirror and emits `field = null`.
            if k.stringValue == "_null", codingPath.isEmpty,
               let result = decoder.result?.pointee {
                let paths = result.allNullFields
                if T.self == [String].self { return paths as! T }
                if String(describing: T.self) == "Google_Protobuf_FieldMask" {
                    var fm = Google_Protobuf_FieldMask()
                    fm.paths = paths
                    return fm as! T
                }
                // For any other Decodable, fall through and let the synthesized
                // init handle it via singleValueContainer. This keeps custom
                // FieldMask-like types working (e.g., a `struct NullMask:
                // Codable { var paths: [String] }`).
                return try T(from: _PXFSingleValueDecoder(
                    value: PXF.ListVal(pos: PXF.Position(line: 0, column: 0),
                                       elements: paths.map { PXF.StringVal(pos: PXF.Position(line: 0, column: 0), value: $0) }),
                    codingPath: codingPath + [k]))
            }

            let e = try getEntry(k)
            
            // Special handling for google.protobuf.Any
            if String(describing: T.self) == "Google_Protobuf_Any" {
                if let a = e as? PXF.Assignment, let bv = a.value as? PXF.BlockVal {
                    if let typeURL = bv.typeURL, let resolved = decoder.typeResolver?.resolve(typeURL: typeURL) {
                        let sub = _PXFDecoder(entries: bv.entries, codingPath: codingPath + [k], result: decoder.result, typeResolver: decoder.typeResolver)
                        let decoded = try resolved.init(from: sub)
                        if let encodable = decoded as? Encodable {
                            let pbData = try PBEncoder().encode(encodable)
                            var any = Google_Protobuf_Any()
                            any.typeURL = typeURL
                            any.value = pbData
                            return any as! T
                        }
                    }
                }
            }

            if let b = e as? PXF.Block { return try T(from: decoder.child(entries: b.entries, key: k)) }
            if let a = e as? PXF.Assignment {
                if let bv = a.value as? PXF.BlockVal { return try T(from: decoder.child(entries: bv.entries, key: k)) }
                if let lv = a.value as? PXF.ListVal { return try T(from: _PXFUnkeyedDecoder(elements: lv.elements, codingPath: codingPath + [k], result: decoder.result, typeResolver: decoder.typeResolver)) }
                return try T(from: _PXFSingleValueDecoder(value: a.value, codingPath: codingPath + [k]))
            }
            if let m = e as? PXF.MapEntry {
                return try T(from: _PXFSingleValueDecoder(value: m.value, codingPath: codingPath + [k]))
            }
            throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Key '\(k.stringValue)' not found in PXF document"))
        }


        /// The document's own entry for `k`, if any.
        private func documentEntry(_ k: Key) -> PXF.Entry? {
            decoder.entries.first { if let a = $0 as? PXF.Assignment { return a.key == k.stringValue } else if let b = $0 as? PXF.Block { return b.name == k.stringValue } else if let m = $0 as? PXF.MapEntry { return m.key == k.stringValue } else { return false } }
        }
        /// The document's entry, or the synthesised `(pxf.default)` one.
        private func findEntry(_ k: Key) -> PXF.Entry? {
            documentEntry(k) ?? defaultEntry(k)
        }
        /// The synthesised `key = <default>` for an absent field that
        /// declares a `(pxf.default)`; nil otherwise. A literal that does
        /// not read as the field's type is reported through decode(), where
        /// throwing is possible.
        private func defaultEntry(_ k: Key) -> PXF.Entry? {
            guard let f = decoder.field(for: k), f.defaultLiteral != nil,
                  let v = try? decoder.annotations?.defaultValue(for: f) else { return nil }
            return PXF.Assignment(pos: PXF.Position(line: 0, column: 0), key: k.stringValue, value: v, leadingComments: [], trailingComment: nil)
        }
        private func getEntry(_ k: Key) throws -> PXF.Entry {
            if let e = findEntry(k) { return e }
            // Surface a bad default literal as its own error rather than
            // as "key not found".
            if let f = decoder.field(for: k), f.defaultLiteral != nil, let annotations = decoder.annotations {
                _ = try annotations.defaultValue(for: f)
            }
            throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Key '\(k.stringValue)' not found in PXF document"))
        }
        private func getValue(_ k: Key) throws -> PXF.Value { let e = try getEntry(k); if let a = e as? PXF.Assignment { return a.value } else if let m = e as? PXF.MapEntry { return m.value } else { throw DecodingError.typeMismatch(PXF.Value.self, .init(codingPath: codingPath, debugDescription: "")) } }

        func decodeIfPresent<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T? { guard contains(k) else { return nil }; if try decodeNil(forKey: k) { return nil }; return try decode(t, forKey: k) }
        func nestedContainer<N: CodingKey>(keyedBy t: N.Type, forKey k: Key) throws -> KeyedDecodingContainer<N> {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                debugDescription: "PXF: nested keyed containers are decoded via decode<T>; this entry point is unused"))
        }
        func nestedUnkeyedContainer(forKey k: Key) throws -> UnkeyedDecodingContainer {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                debugDescription: "PXF: nested unkeyed containers are decoded via decode<T>; this entry point is unused"))
        }
        func superDecoder() throws -> Swift.Decoder { decoder }
        func superDecoder(forKey k: Key) throws -> Swift.Decoder { decoder }
    }
}

private final class _PXFUnkeyedDecoder: Swift.Decoder {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]
    let elements: [PXF.Value]
    private var result: UnsafeMutablePointer<PXF.Result>?
    let typeResolver: PXF.TypeResolver?
    init(elements: [PXF.Value], codingPath: [CodingKey] = [], result: UnsafeMutablePointer<PXF.Result>? = nil, typeResolver: PXF.TypeResolver? = nil) {
        self.elements = elements
        self.codingPath = codingPath
        self.result = result
        self.typeResolver = typeResolver
    }
    func container<K>(keyedBy t: K.Type) -> KeyedDecodingContainer<K> { fatalError() }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { return UnkeyedContainer(decoder: self) }
    func singleValueContainer() throws -> SingleValueDecodingContainer { return self }

    struct UnkeyedContainer: UnkeyedDecodingContainer {
        var decoder: _PXFUnkeyedDecoder; var codingPath: [CodingKey] = []
        var count: Int? { decoder.elements.count }; var isAtEnd: Bool { currentIndex >= decoder.elements.count }; var currentIndex: Int = 0
        mutating func decodeNil() throws -> Bool {
            if decoder.elements[currentIndex] is PXF.NullVal {
                decoder.result?.pointee.markNull(path: "\(path).\(currentIndex)")
                currentIndex += 1
                return true
            }
            return false
        }
        
        private var path: String {
            return codingPath.map { $0.stringValue }.joined(separator: ".")
        }

        mutating func decode(_ t: Bool.Type) throws -> Bool { let v = try current() as? PXF.BoolVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return v?.value ?? false }
        mutating func decode(_ t: String.Type) throws -> String { let v = try current() as? PXF.StringVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return v?.value ?? "" }
        mutating func decode(_ t: Int.Type) throws -> Int { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Int(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: Int8.Type) throws -> Int8 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Int8(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: Int16.Type) throws -> Int16 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Int16(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: Int32.Type) throws -> Int32 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Int32(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: Int64.Type) throws -> Int64 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Int64(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: UInt.Type) throws -> UInt { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return UInt(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: UInt8.Type) throws -> UInt8 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return UInt8(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: UInt16.Type) throws -> UInt16 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return UInt16(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: UInt32.Type) throws -> UInt32 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return UInt32(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: UInt64.Type) throws -> UInt64 { let v = try current() as? PXF.IntVal; decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return UInt64(v?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: Float.Type) throws -> Float { let v = try current(); decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Float((v as? PXF.FloatVal)?.raw ?? (v as? PXF.IntVal)?.raw ?? "0") ?? 0 }
        mutating func decode(_ t: Double.Type) throws -> Double { let v = try current(); decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)"); currentIndex += 1; return Double((v as? PXF.FloatVal)?.raw ?? (v as? PXF.IntVal)?.raw ?? "0") ?? 0 }
        mutating func decode<T: Decodable>(_ t: T.Type) throws -> T {
            let v = try current()
            decoder.result?.pointee.markPresent(path: "\(path).\(currentIndex)")
            if let b = v as? PXF.BlockVal { currentIndex += 1; return try T(from: _PXFDecoder(entries: b.entries, codingPath: codingPath + [PXFKey(index: currentIndex - 1)], result: decoder.result, typeResolver: decoder.typeResolver)) }
            currentIndex += 1; return try T(from: _PXFSingleValueDecoder(value: v, codingPath: codingPath + [PXFKey(index: currentIndex - 1)]))
        }
        private func current() throws -> PXF.Value { guard currentIndex < decoder.elements.count else { throw DecodingError.valueNotFound(PXF.Value.self, .init(codingPath: codingPath, debugDescription: "")) }; return decoder.elements[currentIndex] }
        mutating func nestedContainer<N: CodingKey>(keyedBy t: N.Type) throws -> KeyedDecodingContainer<N> {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
                debugDescription: "PXF: nested keyed containers within lists are decoded via decode<T>; this entry point is unused"))
        }
        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
                debugDescription: "PXF: nested unkeyed containers within lists are decoded via decode<T>; this entry point is unused"))
        }
        func superDecoder() throws -> Swift.Decoder { decoder }
    }
}

extension _PXFUnkeyedDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool { return false }
    func decode(_ t: Bool.Type) throws -> Bool { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: String.Type) throws -> String { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Double.Type) throws -> Double { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Float.Type) throws -> Float { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int.Type) throws -> Int { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int8.Type) throws -> Int8 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int16.Type) throws -> Int16 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int32.Type) throws -> Int32 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int64.Type) throws -> Int64 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt.Type) throws -> UInt { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt8.Type) throws -> UInt8 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt16.Type) throws -> UInt16 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt32.Type) throws -> UInt32 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt64.Type) throws -> UInt64 { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode<T: Decodable>(_ t: T.Type) throws -> T { return try T(from: self) }
}

private final class _PXFSingleValueDecoder: Swift.Decoder {
    var codingPath: [CodingKey] = []; var userInfo: [CodingUserInfoKey: Any] = [:]; let value: PXF.Value
    init(value: PXF.Value, codingPath: [CodingKey] = []) { self.value = value; self.codingPath = codingPath }
    
    func container<K>(keyedBy type: K.Type) -> KeyedDecodingContainer<K> where K : CodingKey {
        return KeyedDecodingContainer(WrapperContainer<K>(decoder: self))
    }
    
    struct WrapperContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        var decoder: _PXFSingleValueDecoder
        var codingPath: [CodingKey] { decoder.codingPath }
        var allKeys: [Key] { [] }
        
        func contains(_ key: Key) -> Bool {
            return key.stringValue == "value"
        }
        
        func decodeNil(forKey key: Key) throws -> Bool {
            return key.stringValue == "value" ? decoder.value is PXF.NullVal : true
        }
        
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            guard key.stringValue == "value" else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Wrapper sugar only supports 'value' key"))
            }
            return try T(from: decoder)
        }
        
        // Boilerplate for other types
        func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { try check(k); return try decoder.decode(t) }
        func decode(_ t: String.Type, forKey k: Key) throws -> String { try check(k); return try decoder.decode(t) }
        func decode(_ t: Double.Type, forKey k: Key) throws -> Double { try check(k); return try decoder.decode(t) }
        func decode(_ t: Float.Type, forKey k: Key) throws -> Float { try check(k); return try decoder.decode(t) }
        func decode(_ t: Int.Type, forKey k: Key) throws -> Int { try check(k); return try decoder.decode(t) }
        func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { try check(k); return try decoder.decode(t) }
        func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { try check(k); return try decoder.decode(t) }
        func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { try check(k); return try decoder.decode(t) }
        func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { try check(k); return try decoder.decode(t) }
        func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { try check(k); return try decoder.decode(t) }
        func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { try check(k); return try decoder.decode(t) }
        func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { try check(k); return try decoder.decode(t) }
        func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { try check(k); return try decoder.decode(t) }
        func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { try check(k); return try decoder.decode(t) }
        
        private func check(_ k: Key) throws {
            guard k.stringValue == "value" else {
                throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Wrapper sugar only supports 'value' key"))
            }
        }
        
        func decodeIfPresent<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T? {
            guard k.stringValue == "value" else { return nil }
            return try decoder.decode(t)
        }
        
        func nestedContainer<N: CodingKey>(keyedBy t: N.Type, forKey k: Key) throws -> KeyedDecodingContainer<N> {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                debugDescription: "PXF: wrapper sugar does not support nested keyed containers"))
        }
        func nestedUnkeyedContainer(forKey k: Key) throws -> UnkeyedDecodingContainer {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                debugDescription: "PXF: wrapper sugar does not support nested unkeyed containers"))
        }
        func superDecoder() throws -> Swift.Decoder { decoder }
        func superDecoder(forKey k: Key) throws -> Swift.Decoder { decoder }
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
            debugDescription: "PXF: single value cannot be decoded as unkeyed container"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer { return self }
}

extension _PXFSingleValueDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool { value is PXF.NullVal }
    func decode(_ t: Bool.Type) throws -> Bool { if let v = value as? PXF.BoolVal { return v.value }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: String.Type) throws -> String { if let v = value as? PXF.StringVal { return v.value }; if let v = value as? PXF.IdentVal { return v.name }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Double.Type) throws -> Double { if let v = value as? PXF.FloatVal, let n = Double(v.raw) { return n }; if let v = value as? PXF.IntVal, let n = Double(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Float.Type) throws -> Float { if let v = value as? PXF.FloatVal, let n = Float(v.raw) { return n }; if let v = value as? PXF.IntVal, let n = Float(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int.Type) throws -> Int { if let v = value as? PXF.IntVal, let n = Int(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int8.Type) throws -> Int8 { if let v = value as? PXF.IntVal, let n = Int8(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int16.Type) throws -> Int16 { if let v = value as? PXF.IntVal, let n = Int16(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int32.Type) throws -> Int32 { if let v = value as? PXF.IntVal, let n = Int32(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: Int64.Type) throws -> Int64 { if let v = value as? PXF.IntVal, let n = Int64(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt.Type) throws -> UInt { if let v = value as? PXF.IntVal, let n = UInt(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt8.Type) throws -> UInt8 { if let v = value as? PXF.IntVal, let n = UInt8(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt16.Type) throws -> UInt16 { if let v = value as? PXF.IntVal, let n = UInt16(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt32.Type) throws -> UInt32 { if let v = value as? PXF.IntVal, let n = UInt32(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode(_ t: UInt64.Type) throws -> UInt64 { if let v = value as? PXF.IntVal, let n = UInt64(v.raw) { return n }; throw DecodingError.typeMismatch(t, .init(codingPath: codingPath, debugDescription: "")) }
    func decode<T: Decodable>(_ t: T.Type) throws -> T { if T.self == Data.self { if let v = value as? PXF.BytesVal { return v.value as! T } }; return try T(from: self) }
}
