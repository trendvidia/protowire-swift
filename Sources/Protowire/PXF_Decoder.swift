// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

struct PXFKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    /// A list element's position, as opposed to a field that happens to be
    /// spelled like a number.
    var isIndex = false
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = Int(stringValue) }
    init(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    init(index: Int) { self.stringValue = "\(index)"; self.intValue = index; self.isIndex = true }
}

/// `path` as a `PXF.Result` names it, the Go reference's spelling:
/// `one.name`, `kd[0].name`.
func presencePath(_ path: [CodingKey]) -> String {
    path.reduce(into: "") { out, key in
        if (key as? PXFKey)?.isIndex == true {
            out += "[\(key.stringValue)]"
        } else {
            if !out.isEmpty { out += "." }
            out += key.stringValue
        }
    }
}

/// A decoder that deserializes `Decodable` types from PXF format.
public final class PXFDecoder {
    /// An optional type resolver to handle `@type` directives (e.g., for `google.protobuf.Any`).
    public var typeResolver: PXF.TypeResolver?

    /// The schema, indexed from a descriptor set. With `rootMessage` also
    /// set, the whole document is checked against it before the Swift type
    /// runs: see `PXF.Binder`. Required fields, defaults and keyed repeated
    /// fields apply in every message body. Nil (the default) leaves only what
    /// holds without a schema: a quoted entry name is rejected, since nothing
    /// is keyed, and a singular field or map key bound twice is rejected for
    /// the fields the Swift type reads.
    public var annotations: PXF.Annotations?

    /// Fully qualified proto name of the message the document represents,
    /// e.g. `settings.v1.Settings`; the entry point into `annotations`.
    public var rootMessage: String?

    /// With a schema, an entry naming no field of its message is an error
    /// unless this is set, as `DiscardUnknown` is in the reference.
    public var discardUnknown = false

    /// What the last document bound to, for the conformance comparison.
    var lastBound: PXF.BoundMessage?
    var lastBoundRows: [PXF.BoundMessage] = []

    /// Initializes a new `PXFDecoder`.
    public init() {}

    /// Initializes a decoder that applies `annotations` from `rootMessage` down.
    public init(annotations: PXF.Annotations, rootMessage: String) {
        self.annotations = annotations
        self.rootMessage = rootMessage
    }

    /// The schema checks that do not depend on a document, so they run
    /// before one is read: a bad schema fails on every input.
    private func validateSchema() throws {
        guard let annotations, let root = rootMessage else { return }
        try annotations.validateRequiredDefault(message: root)
    }

    /// What the Swift type sees: `entries` with keyed bindings rewritten to
    /// lists and each applied default added. The schema-bound pass runs here,
    /// before the type sees the document, because it has to cover every field
    /// the schema declares whether or not the type asks for it.
    private func bind(_ entries: [PXF.Entry]) throws -> [PXF.Entry] {
        guard let annotations, let root = rootMessage else {
            try PXF.Annotations.rejectQuotedNames(entries)
            return entries
        }
        try annotations.validateKeyPlacement(message: root)
        let expanded = try annotations.expandKeyed(entries, message: root)
        try PXF.Annotations.rejectQuotedNames(expanded)
        let resolve = typeResolver.map { resolver in { (url: String) in resolver.resolve(typeURL: url) != nil } }
        let binder = PXF.Binder(annotations: annotations, resolve: resolve, discardUnknown: discardUnknown)
        let bound = try binder.bind(expanded, message: root)
        lastBound = bound.message
        return bound.entries
    }

    /// Decodes each row of a `@dataset` directive as the message body it
    /// stands for: a cell in column `c` means what `c = <value>` means in a
    /// body, and an empty cell leaves the field absent. With `annotations`,
    /// the row type comes from the directive and every body rule applies,
    /// `(pxf.required)` and `(pxf.default)` included.
    public func decodeRows<T: Decodable>(_ type: T.Type, of dataset: PXF.DatasetDirective) throws -> [T] {
        lastBoundRows = []
        let annotations = annotations
        let binder = annotations.map { annotations in
            PXF.Binder(annotations: annotations, resolve: typeResolver.map { resolver in { resolver.resolve(typeURL: $0) != nil } },
                       discardUnknown: discardUnknown)
        }
        if let annotations, !dataset.rows.isEmpty {
            try annotations.validateRequiredDefault(message: dataset.type)
            try annotations.validateKeyPlacement(message: dataset.type)
        }
        return try dataset.rows.map { row in
            guard let binder else {
                return try T(from: _PXFDecoder(entries: PXF.Dataset.entries(columns: dataset.columns, row: row), typeResolver: typeResolver))
            }
            let bound = try binder.bindRow(columns: dataset.columns, row: row, message: dataset.type)
            lastBoundRows.append(bound.message)
            return try T(from: _PXFDecoder(entries: bound.entries, typeResolver: typeResolver))
        }
    }

    /// Decodes a value of the given type from PXF data.
    /// - Parameters:
    ///   - type: The type of value to decode.
    ///   - data: The PXF data to decode from.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateSchema()
        let doc = try PXF.Parser(input: data).parseDocument()
        let entries = try bind(doc.entries)
        let decoder = _PXFDecoder(entries: entries, typeResolver: typeResolver)
        return try T(from: decoder)
    }

    /// Decodes a value of the given type from a PXF string.
    /// - Parameters:
    ///   - type: The type of value to decode.
    ///   - string: The PXF string to decode from.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try validateSchema()
        let doc = try PXF.Parser(string: string).parseDocument()
        let entries = try bind(doc.entries)
        let decoder = _PXFDecoder(entries: entries, typeResolver: typeResolver)
        return try T(from: decoder)
    }

    /// Decodes a value and returns both the value and a result object containing presence information.
    /// - Parameters:
    ///   - type: The type of value to decode.
    ///   - string: The PXF string to decode from.
    /// - Returns: A tuple containing the decoded value and a `PXF.Result` object.
    /// - Throws: An error if decoding fails.
    public func unmarshalFull<T: Decodable>(_ type: T.Type, from string: String) throws -> (T, PXF.Result) {
        try validateSchema()
        let doc = try PXF.Parser(string: string).parseDocument()
        let entries = try bind(doc.entries)
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
        for entry in entries {
            if let a = entry as? PXF.Assignment, a.value is PXF.NullVal {
                result.markNull(path: a.key)
            }
        }
        let decoder = _PXFDecoder(entries: entries, result: &result, typeResolver: typeResolver)
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

    init(entries: [PXF.Entry], codingPath: [CodingKey] = [], result: UnsafeMutablePointer<PXF.Result>? = nil, typeResolver: PXF.TypeResolver? = nil) {
        self.entries = entries
        self.codingPath = codingPath
        self.result = result
        self.typeResolver = typeResolver
        markEntriesPresent()
    }

    /// A decoder for a value bound at `path`, whatever its shape.
    func valueDecoder(_ value: PXF.Value, path: [CodingKey]) -> Swift.Decoder {
        if let b = value as? PXF.BlockVal {
            return _PXFDecoder(entries: b.entries, codingPath: path, result: result, typeResolver: typeResolver)
        }
        if let l = value as? PXF.ListVal {
            return _PXFUnkeyedDecoder(elements: l.elements, codingPath: path, result: result, typeResolver: typeResolver)
        }
        return _PXFSingleValueDecoder(value: value, codingPath: path)
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> where Key: CodingKey {
        return KeyedDecodingContainer(KeyedContainer<Key>(decoder: self, codingPath: codingPath))
    }

    /// Presence comes from the document, not from what the Swift type asks
    /// for: a non-optional property never calls `contains`, and a type may
    /// not declare the field at all. This is what records an entry name's key
    /// field, written out by `expandKeyed` (protowire-go#214). Nulls stay with
    /// `decodeNil`, and a map's `key: value` entries name no field.
    private func markEntriesPresent() {
        guard let result else { return }
        for entry in entries {
            let name: String
            if let a = entry as? PXF.Assignment, !(a.value is PXF.NullVal), !a.isDefault {
                name = a.key
            } else if let b = entry as? PXF.Block {
                name = b.name
            } else {
                continue
            }
            result.pointee.markPresent(path: presencePath(codingPath + [PXFKey(stringValue: name)]))
        }
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
               !result.nullMaskPaths.isEmpty {
                return true
            }
            guard let e = decoder.entries.first(where: { matches($0, k) }) else { return false }
            // A (pxf.default) stands in for an absent field: the Swift type
            // sees a value, and the Result still says absent (Go applies the
            // default without markPresent).
            if (e as? PXF.Assignment)?.isDefault != true {
                decoder.result?.pointee.markPresent(path: path(for: k))
            }
            return true
        }

        func decodeNil(forKey k: Key) throws -> Bool {
            let found = bindings(k)
            guard let e = found.first else { return true }
            // A second binding is an error for a singular field and fine for
            // a list; only the type asked for says which, so this leaves it to
            // decode, unless the second one is what makes it singular: a null.
            if found.count > 1, found.contains(where: isNullBinding) {
                throw Self.boundTwice(k, codingPath)
            }
            if (e as? PXF.Assignment)?.isDefault == true { return false }
            if isNullBinding(e) {
                decoder.result?.pointee.markNull(path: path(for: k))
                return true
            }
            decoder.result?.pointee.markPresent(path: path(for: k))
            return false
        }

        private func isNullBinding(_ e: PXF.Entry) -> Bool {
            if let a = e as? PXF.Assignment { return a.value is PXF.NullVal }
            if let m = e as? PXF.MapEntry { return m.value is PXF.NullVal }
            return false
        }

        private func matches(_ e: PXF.Entry, _ k: Key) -> Bool {
            if let a = e as? PXF.Assignment { return a.key == k.stringValue }
            if let b = e as? PXF.Block { return b.name == k.stringValue }
            if let m = e as? PXF.MapEntry { return m.key == k.stringValue }
            return false
        }

        /// Every entry of this body for `k`, in document order.
        private func bindings(_ k: Key) -> [PXF.Entry] {
            decoder.entries.filter { matches($0, k) }
        }

        fileprivate static func boundTwice(_ k: Key, _ path: [CodingKey]) -> DecodingError {
            .dataCorrupted(.init(codingPath: path + [k], debugDescription: "field \"\(k.stringValue)\" is already set"))
        }

        private func path(for key: Key) -> String {
            presencePath(codingPath + [key])
        }
        func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { let v = try getValue(k); if let x = v as? PXF.BoolVal { return x.value } else if let x = v as? PXF.IntVal { return x.raw != "0" } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected bool or int for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        func decode(_ t: String.Type, forKey k: Key) throws -> String { let v = try getValue(k); if let x = v as? PXF.StringVal { return x.value } else if let x = v as? PXF.IdentVal { return x.name } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected string or identifier for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        func decode(_ t: Int.Type, forKey k: Key) throws -> Int { guard let n = Int(exactly: try decodeI64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { guard let n = Int8(exactly: try decodeI64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { guard let n = Int16(exactly: try decodeI64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { guard let n = Int32(exactly: try decodeI64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { return try decodeI64(k) }
        func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { guard let n = UInt(exactly: try decodeU64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { guard let n = UInt8(exactly: try decodeU64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { guard let n = UInt16(exactly: try decodeU64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { guard let n = UInt32(exactly: try decodeU64(k)) else { throw outOfRange(t, k) }; return n }
        func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { return try decodeU64(k) }
        func decode(_ t: Float.Type, forKey k: Key) throws -> Float { let v = try getValue(k); if let raw = PXF.numericLiteral(v), let n = Float(raw) { return n } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected float or int for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }
        func decode(_ t: Double.Type, forKey k: Key) throws -> Double { let v = try getValue(k); if let raw = PXF.numericLiteral(v), let n = Double(raw) { return n } else { throw DecodingError.typeMismatch(t, .init(codingPath: codingPath + [k], debugDescription: "Expected double or int for key '\(k.stringValue)', got \(String(describing: type(of: v)))")) } }

        private func outOfRange(_ t: Any.Type, _ k: Key) -> DecodingError {
            .dataCorrupted(.init(codingPath: codingPath + [k], debugDescription: "value of '\(k.stringValue)' is out of range for \(t)"))
        }
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
                let paths = result.nullMaskPaths
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

            // A repeated field concatenates its bindings and a map merges
            // them (draft -01 § Entries and Keys). Anything else is singular.
            if let list = T.self as? _PBArray.Type, !(T.self == Data.self) {
                return try decodeList(list, t, forKey: k)
            }
            if let map = T.self as? _PBMap.Type {
                return try decodeMap(map, forKey: k) as! T
            }

            let e = try getEntry(k)

            // Special handling for google.protobuf.Any
            if String(describing: T.self) == "Google_Protobuf_Any" {
                let body = (e as? PXF.Block).map { PXF.BlockVal(pos: $0.pos, typeURL: $0.typeURL, entries: $0.entries) }
                    ?? (e as? PXF.Assignment)?.value as? PXF.BlockVal
                if let body, let typeURL = body.typeURL, let resolved = decoder.typeResolver?.resolve(typeURL: typeURL) {
                    let sub = _PXFDecoder(entries: body.entries, codingPath: codingPath + [k], result: decoder.result, typeResolver: decoder.typeResolver)
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

            if let b = e as? PXF.Block {
                return try T(from: _PXFDecoder(entries: b.entries, codingPath: codingPath + [k], result: decoder.result, typeResolver: decoder.typeResolver))
            }
            let value: PXF.Value
            if let a = e as? PXF.Assignment { value = a.value }
            else if let m = e as? PXF.MapEntry { value = m.value }
            else { throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Key '\(k.stringValue)' not found in PXF document")) }
            return try T(from: decoder.valueDecoder(value, path: codingPath + [k]))
        }

        private func decodeList<T: Decodable>(_ list: _PBArray.Type, _ t: T.Type, forKey k: Key) throws -> T {
            let found = bindings(k)
            guard let first = found.first else {
                throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Key '\(k.stringValue)' not found in PXF document"))
            }
            if found.count == 1 {
                if let b = first as? PXF.Block {
                    return try T(from: _PXFDecoder(entries: b.entries, codingPath: codingPath + [k], result: decoder.result, typeResolver: decoder.typeResolver))
                }
                let value = (first as? PXF.Assignment)?.value ?? (first as? PXF.MapEntry)?.value
                if let value { return try T(from: decoder.valueDecoder(value, path: codingPath + [k])) }
            }
            var elements: [PXF.Value] = []
            for entry in found {
                guard let a = entry as? PXF.Assignment, let l = a.value as? PXF.ListVal else {
                    throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                        debugDescription: "repeated field \"\(k.stringValue)\" must use list syntax: \(k.stringValue) = [...]"))
                }
                elements += l.elements
            }
            return try T(from: _PXFUnkeyedDecoder(elements: elements, codingPath: codingPath + [k], result: decoder.result, typeResolver: decoder.typeResolver))
        }

        /// A map's bindings, merged. A key bound twice is an error, inside
        /// one literal or across bindings, and keys compare as values of the
        /// key type, so `1:` and `"1":` on an integer key are one key.
        private func decodeMap(_ map: _PBMap.Type, forKey k: Key) throws -> Any {
            let found = bindings(k)
            guard !found.isEmpty else {
                throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Key '\(k.stringValue)' not found in PXF document"))
            }
            var out: [(Any, Any)] = []
            var seen = Set<String>()
            for entry in found {
                let body: [PXF.Entry]
                if let a = entry as? PXF.Assignment, let b = a.value as? PXF.BlockVal {
                    body = b.entries
                } else if let b = entry as? PXF.Block {
                    body = b.entries
                } else {
                    throw DecodingError.typeMismatch(Dictionary<String, String>.self, .init(codingPath: codingPath + [k],
                        debugDescription: "expected '{' for map field \"\(k.stringValue)\""))
                }
                for item in body {
                    guard let m = item as? PXF.MapEntry else {
                        throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [k],
                            debugDescription: "unexpected entry in map \"\(k.stringValue)\", use ':' for map entries"))
                    }
                    let path = codingPath + [k, PXFKey(stringValue: m.key)]
                    let key = try PXF.mapKey(m.key, as: map.keyType, codingPath: path)
                    guard seen.insert(String(describing: key)).inserted else {
                        throw DecodingError.dataCorrupted(.init(codingPath: path,
                            debugDescription: "map field \"\(k.stringValue)\": key \(m.key) is already set"))
                    }
                    out.append((key, try map.valueType.init(from: decoder.valueDecoder(m.value, path: path))))
                }
            }
            return map.init(entries: out)
        }

        /// The one entry for `k`, or the error for a second binding.
        private func getEntry(_ k: Key) throws -> PXF.Entry {
            let found = bindings(k)
            guard let first = found.first else {
                throw DecodingError.keyNotFound(k, .init(codingPath: codingPath, debugDescription: "Key '\(k.stringValue)' not found in PXF document"))
            }
            if found.count > 1 { throw Self.boundTwice(k, codingPath) }
            return first
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

extension PXF {
    /// A map key's text as the Swift key type, so spellings of one key compare
    /// equal. Keys are written as identifiers, strings, integers or bools.
    static func mapKey(_ raw: String, as type: Any.Type, codingPath: [CodingKey]) throws -> Any {
        func bad() -> DecodingError {
            .dataCorrupted(.init(codingPath: codingPath, debugDescription: "invalid map key \(raw) for \(type)"))
        }
        switch type {
        case is String.Type: return raw
        case is Bool.Type:
            switch raw {
            case "true", "1": return true
            case "false", "0": return false
            default: throw bad()
            }
        case is Int.Type: guard let n = Int(raw) else { throw bad() }; return n
        case is Int8.Type: guard let n = Int8(raw) else { throw bad() }; return n
        case is Int16.Type: guard let n = Int16(raw) else { throw bad() }; return n
        case is Int32.Type: guard let n = Int32(raw) else { throw bad() }; return n
        case is Int64.Type: guard let n = Int64(raw) else { throw bad() }; return n
        case is UInt.Type: guard let n = UInt(raw) else { throw bad() }; return n
        case is UInt8.Type: guard let n = UInt8(raw) else { throw bad() }; return n
        case is UInt16.Type: guard let n = UInt16(raw) else { throw bad() }; return n
        case is UInt32.Type: guard let n = UInt32(raw) else { throw bad() }; return n
        case is UInt64.Type: guard let n = UInt64(raw) else { throw bad() }; return n
        default: throw bad()
        }
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
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { return UnkeyedContainer(decoder: self, codingPath: codingPath) }
    func singleValueContainer() throws -> SingleValueDecodingContainer { return self }

    struct UnkeyedContainer: UnkeyedDecodingContainer {
        var decoder: _PXFUnkeyedDecoder; var codingPath: [CodingKey] = []
        var count: Int? { decoder.elements.count }; var isAtEnd: Bool { currentIndex >= decoder.elements.count }; var currentIndex: Int = 0
        mutating func decodeNil() throws -> Bool {
            if decoder.elements[currentIndex] is PXF.NullVal {
                decoder.result?.pointee.markNull(path: elementPath)
                currentIndex += 1
                return true
            }
            return false
        }
        
        private var elementPath: String {
            presencePath(codingPath + [PXFKey(index: currentIndex)])
        }

        mutating func decode(_ t: Bool.Type) throws -> Bool { try element { try $0.decode(t) } }
        mutating func decode(_ t: String.Type) throws -> String { try element { try $0.decode(t) } }
        mutating func decode(_ t: Int.Type) throws -> Int { try element { try $0.decode(t) } }
        mutating func decode(_ t: Int8.Type) throws -> Int8 { try element { try $0.decode(t) } }
        mutating func decode(_ t: Int16.Type) throws -> Int16 { try element { try $0.decode(t) } }
        mutating func decode(_ t: Int32.Type) throws -> Int32 { try element { try $0.decode(t) } }
        mutating func decode(_ t: Int64.Type) throws -> Int64 { try element { try $0.decode(t) } }
        mutating func decode(_ t: UInt.Type) throws -> UInt { try element { try $0.decode(t) } }
        mutating func decode(_ t: UInt8.Type) throws -> UInt8 { try element { try $0.decode(t) } }
        mutating func decode(_ t: UInt16.Type) throws -> UInt16 { try element { try $0.decode(t) } }
        mutating func decode(_ t: UInt32.Type) throws -> UInt32 { try element { try $0.decode(t) } }
        mutating func decode(_ t: UInt64.Type) throws -> UInt64 { try element { try $0.decode(t) } }
        mutating func decode(_ t: Float.Type) throws -> Float { try element { try $0.decode(t) } }
        mutating func decode(_ t: Double.Type) throws -> Double { try element { try $0.decode(t) } }
        mutating func decode<T: Decodable>(_ t: T.Type) throws -> T {
            let v = try current()
            let at = codingPath + [PXFKey(index: currentIndex)]
            decoder.result?.pointee.markPresent(path: presencePath(at))
            currentIndex += 1
            if let b = v as? PXF.BlockVal {
                return try T(from: _PXFDecoder(entries: b.entries, codingPath: at, result: decoder.result, typeResolver: decoder.typeResolver))
            }
            if let l = v as? PXF.ListVal {
                return try T(from: _PXFUnkeyedDecoder(elements: l.elements, codingPath: at, result: decoder.result, typeResolver: decoder.typeResolver))
            }
            return try T(from: _PXFSingleValueDecoder(value: v, codingPath: at))
        }
        /// One scalar element, read by the same checks as a field: a wrong
        /// type is an error rather than a zero.
        private mutating func element<T>(_ read: (_PXFSingleValueDecoder) throws -> T) throws -> T {
            let at = codingPath + [PXFKey(index: currentIndex)]
            let v = try read(_PXFSingleValueDecoder(value: try current(), codingPath: at))
            decoder.result?.pointee.markPresent(path: presencePath(at))
            currentIndex += 1
            return v
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

fileprivate final class _PXFSingleValueDecoder: Swift.Decoder, _PXFValueHolder {
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
