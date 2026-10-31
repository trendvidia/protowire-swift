// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// The set of fully-qualified type names SwiftProtobuf generates for the
/// nine standard protobuf wrapper types. Any field whose CLR type matches one
/// of these gets PXF wrapper sugar (`field = innerValue` instead of
/// `field = { value = innerValue }`). User-defined types with a similar
/// shape are NOT covered — that would be a fragile heuristic.
private let protobufWrapperTypeNames: Set<String> = [
    "Google_Protobuf_DoubleValue",
    "Google_Protobuf_FloatValue",
    "Google_Protobuf_Int64Value",
    "Google_Protobuf_UInt64Value",
    "Google_Protobuf_Int32Value",
    "Google_Protobuf_UInt32Value",
    "Google_Protobuf_BoolValue",
    "Google_Protobuf_StringValue",
    "Google_Protobuf_BytesValue",
]

public final class PXFEncoder {
    public var indent: String = "  "
    public var emitDefaults: Bool = false

    /// Schema annotations; with `rootMessage` also set, a `(pxf.key)` field
    /// is written in the keyed block form whenever every element's key is
    /// present, non-empty and distinct, and as an anonymous list otherwise.
    /// Nil (the default) leaves encoding exactly as before.
    public var annotations: PXF.Annotations?

    /// Fully qualified proto name of the message being encoded.
    public var rootMessage: String?

    public init() {}

    /// Initializes an encoder that applies `annotations` from `rootMessage` down.
    public init(annotations: PXF.Annotations, rootMessage: String) {
        self.annotations = annotations
        self.rootMessage = rootMessage
    }

    /// Returns a PXF-quoted version of `s` — wraps it in double quotes and
    /// escapes `\"`, `\\`, `\n`, `\r`, `\t`, plus emits `\xHH` for control
    /// bytes < 0x20. Code units >= 0x20 pass through literally so valid UTF-8
    /// stays UTF-8.
    ///
    /// Mirrors `writeQuotedString` in `protowire-go/encoding/pxf/encode.go`.
    public static func quote(_ s: String) -> String {
        // Hex digits as ASCII bytes — used to encode `\xHH` for control bytes.
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = [0x22] // "
        for b in s.utf8 {
            switch b {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22]) // \"
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C]) // \\
            case 0x0A: bytes.append(contentsOf: [0x5C, 0x6E]) // \n
            case 0x0D: bytes.append(contentsOf: [0x5C, 0x72]) // \r
            case 0x09: bytes.append(contentsOf: [0x5C, 0x74]) // \t
            default:
                if b < 0x20 {
                    bytes.append(contentsOf: [0x5C, 0x78,    // \x
                                              hex[Int(b >> 4)],
                                              hex[Int(b & 0xF)]])
                } else {
                    // Pass UTF-8 bytes through verbatim so multibyte
                    // sequences (e.g. `é`, `µ`) survive intact.
                    bytes.append(b)
                }
            }
        }
        bytes.append(0x22) // "
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Returns true iff `value`'s concrete type is one of the nine
    /// SwiftProtobuf-generated wrapper types. Used to gate wrapper sugar.
    public static func isProtobufWrapper(_ value: Any) -> Bool {
        protobufWrapperTypeNames.contains(String(describing: type(of: value)))
    }

    public func encode<T: Encodable>(_ value: T) throws -> String {
        if let annotations, let rootMessage {
            try annotations.validateKeyPlacement(message: rootMessage)
        }
        let encoder = _PXFEncoder(indent: indent, emitDefaults: emitDefaults, annotations: annotations, messageName: rootMessage)
        try value.encode(to: encoder)
        
        // Handle top-level _null if it was a struct/class
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .struct || mirror.displayStyle == .class {
            for child in mirror.children {
                if child.label == "_null" {
                    if let paths = child.value as? [String] {
                        for p in paths { encoder.output += "\(p) = null\n" }
                    } else {
                        let maskMirror = Mirror(reflecting: child.value)
                        for maskChild in maskMirror.children {
                            if maskChild.label == "paths", let paths = maskChild.value as? [String] {
                                for p in paths { encoder.output += "\(p) = null\n" }
                            }
                        }
                    }
                }
            }
        }
        
        return encoder.output
    }
}

private final class _PXFEncoder: Swift.Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var output: String = ""
    let indent: String
    let emitDefaults: Bool
    var isSingleValue: Bool = false
    /// Schema annotations and the proto message being written; nil when the
    /// caller gave none, or below a value the schema does not describe.
    let annotations: PXF.Annotations?
    let messageName: String?
    /// How an element of a keyed field treats its own key field: the keyed
    /// form moves it to the entry name, and the anonymous form cannot carry
    /// it empty, since a decoder rejects an explicit empty key.
    enum KeyHandling { case capture(field: String), dropEmpty(field: String) }
    let keyHandling: KeyHandling?
    var capturedKey: String?

    init(indent: String, emitDefaults: Bool, codingPath: [CodingKey] = [],
         annotations: PXF.Annotations? = nil, messageName: String? = nil, keyHandling: KeyHandling? = nil) {
        self.indent = indent
        self.emitDefaults = emitDefaults
        self.codingPath = codingPath
        self.annotations = annotations
        self.messageName = messageName
        self.keyHandling = keyHandling
    }

    /// The schema field behind `key`, when this container has a message.
    func field(for key: CodingKey) -> PXF.Annotations.Field? {
        guard let annotations, let messageName else { return nil }
        return annotations.message(messageName)?.field(named: key.stringValue)
    }

    /// Whether the string `value` of field `key` is left out of the output,
    /// because the enclosing keyed field has dealt with it.
    func consumesKey(_ value: String, forKey key: CodingKey) -> Bool {
        switch keyHandling {
        case .capture(let field) where field == key.stringValue:
            capturedKey = value
            return true
        case .dropEmpty(let field) where field == key.stringValue:
            return value.isEmpty
        default:
            return false
        }
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        return KeyedEncodingContainer(KeyedContainer<Key>(encoder: self, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return UnkeyedContainer(encoder: self, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return self
    }

    struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        var encoder: _PXFEncoder
        var codingPath: [CodingKey] = []

        mutating func encodeNil(forKey key: Key) throws {
            writeIndent()
            encoder.output += "\(key.stringValue) = null\n"
        }

        mutating func encode(_ value: Bool, forKey key: Key) throws {
            writeIndent()
            encoder.output += "\(key.stringValue) = \(value)\n"
        }

        mutating func encode(_ value: String, forKey key: Key) throws {
            if encoder.consumesKey(value, forKey: key) { return }
            writeIndent()
            encoder.output += "\(key.stringValue) = \(PXFEncoder.quote(value))\n"
        }

        mutating func encode(_ value: Int, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { try encodeNumber(value, forKey: key) }
        mutating func encode(_ value: Double, forKey key: Key) throws { try encodeNumber(value, forKey: key) }

        private mutating func encodeNumber(_ value: Any, forKey key: Key) throws {
            writeIndent()
            encoder.output += "\(key.stringValue) = \(value)\n"
        }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            if key.stringValue == "_null" { return } // Skip explicit _null field
            
            if let s = value as? String { try encode(s, forKey: key); return }
            if let b = value as? Bool { try encode(b, forKey: key); return }
            if let i = value as? Int { try encode(i, forKey: key); return }
            if let i = value as? Int32 { try encode(i, forKey: key); return }
            if let i = value as? Int64 { try encode(i, forKey: key); return }
            if let i = value as? UInt { try encode(i, forKey: key); return }
            if let i = value as? UInt32 { try encode(i, forKey: key); return }
            if let i = value as? UInt64 { try encode(i, forKey: key); return }
            if let f = value as? Float { try encode(f, forKey: key); return }
            if let d = value as? Double { try encode(d, forKey: key); return }

            if let data = value as? Data {
                writeIndent()
                encoder.output += "\(key.stringValue) = b\"\(data.base64EncodedString())\"\n"
                return
            }
            if let date = value as? Date {
                writeIndent()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                encoder.output += "\(key.stringValue) = \(formatter.string(from: date))\n"
                return
            }

            let mirror = Mirror(reflecting: value)

            if mirror.displayStyle == .collection, let field = encoder.field(for: key),
               let keyField = encoder.annotations?.keyField(of: field) {
                try encodeKeyed(mirror.children.compactMap { $0.value as? Encodable },
                                field: field, keyName: keyField.name, forKey: key)
                return
            }

            // Wrapper sugar: only the nine SwiftProtobuf-generated wrapper
            // types (Google_Protobuf_{Double,Float,Int64,UInt64,Int32,UInt32,
            // Bool,String,Bytes}Value) get inlined as `key = innerValue`.
            // A previous heuristic also matched any user struct/class with a
            // single `value` member, but that caught false positives — for
            // example a user type with one Codable field happens to look like
            // a wrapper but isn't one. Tightening to the named protobuf
            // wrappers makes the behavior predictable and keeps user types
            // emitted as proper nested messages.
            if PXFEncoder.isProtobufWrapper(value) {
                if let first = mirror.children.first(where: { $0.label == "value" }),
                   let enc = first.value as? Encodable {
                    try encode(enc, forKey: key)
                    return
                }
            }

            // Check for _null FieldMask in message
            if mirror.displayStyle == .struct || mirror.displayStyle == .class {
                var nullFields: Set<String> = []
                for child in mirror.children {
                    if child.label == "_null" {
                        let maskMirror = Mirror(reflecting: child.value)
                        for maskChild in maskMirror.children {
                            if maskChild.label == "paths", let paths = maskChild.value as? [String] {
                                nullFields = Set(paths)
                            }
                        }
                    }
                }
                
                let f = encoder.field(for: key)
                let message = (f?.type == .message && f?.isRepeated == false && f?.isMap == false) ? f?.typeName : nil
                let sub = _PXFEncoder(indent: encoder.indent, emitDefaults: encoder.emitDefaults, codingPath: codingPath + [key],
                                      annotations: message == nil ? nil : encoder.annotations, messageName: message)
                try value.encode(to: sub)
                
                if sub.isSingleValue {
                    writeIndent()
                    encoder.output += "\(key.stringValue) = \(sub.output)\n"
                    return
                }
                
                writeIndent()
                encoder.output += "\(key.stringValue) = {\n"
                
                // Emit nulls from FieldMask. The sub-encoder's children already
                // write at sub.codingPath.count indents; level: 0 keeps these
                // null lines at the same depth as those children.
                for nf in nullFields {
                    sub.writeIndent(level: 0)
                    sub.output += "\(nf) = null\n"
                }
                
                encoder.output += sub.output
                writeIndent()
                encoder.output += "}\n"
                return
            }

            if mirror.displayStyle == .collection {
                writeIndent()
                encoder.output += "\(key.stringValue) = ["
                let sub = _PXFEncoder(indent: encoder.indent, emitDefaults: encoder.emitDefaults, codingPath: codingPath + [key])
                var unkeyed = sub.unkeyedContainer()
                try unkeyed.encode(value)
                encoder.output += sub.output
                encoder.output += "]\n"
                return
            }

            writeIndent()
            encoder.output += "\(key.stringValue) = {\n"
            let sub = _PXFEncoder(indent: encoder.indent, emitDefaults: encoder.emitDefaults, codingPath: codingPath + [key])
            try value.encode(to: sub)
            encoder.output += sub.output
            writeIndent()
            encoder.output += "}\n"
        }

        /// Writes a `(pxf.key)` field: the keyed block form when every key is
        /// present, non-empty and distinct, the anonymous list otherwise. An
        /// entry body and a list element sit at the same depth, so one
        /// encoder path serves both.
        private mutating func encodeKeyed(_ elements: [Encodable], field: PXF.Annotations.Field,
                                          keyName: String, forKey key: Key) throws {
            if elements.isEmpty {
                if encoder.emitDefaults {
                    writeIndent()
                    encoder.output += "\(key.stringValue) = []\n"
                }
                return
            }
            let name = key.stringValue
            let path = codingPath + [key, PXFKey(index: 0)]
            func elementEncoder(_ handling: _PXFEncoder.KeyHandling) -> _PXFEncoder {
                _PXFEncoder(indent: encoder.indent, emitDefaults: encoder.emitDefaults, codingPath: path,
                            annotations: encoder.annotations, messageName: field.typeName, keyHandling: handling)
            }

            var seen = Set<[UInt8]>()
            var entries: [(key: String, body: String)] = []
            for element in elements {
                let sub = elementEncoder(.capture(field: keyName))
                try element.encode(to: sub)
                // Bytes, not String ==: canonically equivalent keys are distinct.
                guard let k = sub.capturedKey, !k.isEmpty, seen.insert(Array(k.utf8)).inserted else {
                    entries = []
                    break
                }
                entries.append((k, sub.output))
            }

            if !entries.isEmpty {
                writeIndent()
                encoder.output += "\(name) {\n"
                for entry in entries {
                    writeIndent(level: 1)
                    encoder.output += "\(PXF.Format.canonicalEntryName(entry.key)) {\n\(entry.body)"
                    writeIndent(level: 1)
                    encoder.output += "}\n"
                }
                writeIndent()
                encoder.output += "}\n"
                return
            }

            writeIndent()
            encoder.output += "\(name) = [\n"
            for (i, element) in elements.enumerated() {
                let sub = elementEncoder(.dropEmpty(field: keyName))
                try element.encode(to: sub)
                writeIndent(level: 1)
                encoder.output += "{\n\(sub.output)"
                writeIndent(level: 1)
                encoder.output += i + 1 < elements.count ? "},\n" : "}\n"
            }
            writeIndent()
            encoder.output += "]\n"
        }

        private func writeIndent(level: Int = 0) {
            for _ in 0..<(codingPath.count + level) {
                encoder.output += encoder.indent
            }
        }

        mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { fatalError() }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { fatalError() }
        mutating func superEncoder() -> any Swift.Encoder { encoder }
        mutating func superEncoder(forKey key: Key) -> any Swift.Encoder { encoder }
    }

    struct UnkeyedContainer: UnkeyedEncodingContainer {
        var encoder: _PXFEncoder
        var codingPath: [CodingKey] = []
        var count: Int = 0

        mutating func encodeNil() throws { addComma(); encoder.output += "null" }
        mutating func encode(_ value: Bool) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: String) throws { addComma(); encoder.output += PXFEncoder.quote(value) }
        mutating func encode(_ value: Int) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: Int8) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: Int16) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: Int32) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: Int64) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: UInt) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: UInt8) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: UInt16) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: UInt32) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: UInt64) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: Float) throws { addComma(); encoder.output += "\(value)" }
        mutating func encode(_ value: Double) throws { addComma(); encoder.output += "\(value)" }

        mutating func encode<T: Encodable>(_ value: T) throws {
            if let data = value as? Data {
                addComma()
                encoder.output += "b\"\(data.base64EncodedString())\""
                return
            }

            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .collection {
                addComma()
                encoder.output += "["
                for child in mirror.children {
                    if let e = child.value as? Encodable {
                        try encode(e)
                    }
                }
                encoder.output += "]"
                return
            }

            addComma()
            encoder.output += "{\n"
            let sub = _PXFEncoder(indent: encoder.indent, emitDefaults: encoder.emitDefaults, codingPath: codingPath)
            try value.encode(to: sub)
            encoder.output += sub.output
            for _ in 0..<codingPath.count { encoder.output += encoder.indent }
            encoder.output += "}"
        }

        private mutating func addComma() {
            if count > 0 { encoder.output += ", " }
            count += 1
        }

        mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { fatalError() }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { fatalError() }
        mutating func superEncoder() -> any Swift.Encoder { encoder }
    }

    func writeIndent(level: Int = 0) {
        for _ in 0..<(codingPath.count + level) {
            output += indent
        }
    }
}

extension _PXFEncoder: SingleValueEncodingContainer {
    func encodeNil() throws { isSingleValue = true; output += "null" }
    func encode(_ value: Bool) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: String) throws { isSingleValue = true; output += PXFEncoder.quote(value) }
    func encode(_ value: Double) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: Float) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: Int) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: Int8) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: Int16) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: Int32) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: Int64) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: UInt) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: UInt8) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: UInt16) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: UInt32) throws { isSingleValue = true; output += "\(value)" }
    func encode(_ value: UInt64) throws { isSingleValue = true; output += "\(value)" }
    func encode<T: Encodable>(_ value: T) throws { try value.encode(to: self) }
}
