// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

/// The set of fully-qualified type names SwiftProtobuf generates for the
/// nine standard protobuf wrapper types. Any field whose type matches one of
/// these gets PXF wrapper sugar (`field = innerValue` instead of
/// `field { value = innerValue }`). User-defined types with a similar shape
/// are NOT covered — that would be a fragile heuristic.
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

/// A map, whatever its key type: `Dictionary` hands a `Bool` or `Int32` key to
/// an unkeyed container in alternating pairs, so the keys are read here.
protocol _PXFMapValue {
    var pxfEntries: [(key: Any, value: Any)] { get }
}

extension Dictionary: _PXFMapValue {
    var pxfEntries: [(key: Any, value: Any)] { map { ($0.key, $0.value) } }
}

/// A value whose node is already built: an `Any` written as a type entry and
/// a body, which was rendered and read back to decide that it could be.
protocol _PXFPrebuilt {
    var pxfNode: PXFNode { get }
}

/// What a value writes as. The encoder builds this tree and one function
/// renders it, so the text's shape is decided in one place. Each form follows
/// the matching function of protowire-go's encoding/pxf/encode.go.
indirect enum PXFNode {
    case literal(String)
    case string(String)
    case null
    case message([(name: String, node: PXFNode)], typeURL: String?)
    case list([PXFNode])
    case map([(key: String, node: PXFNode)])
    /// A field with implicit presence: a non-optional scalar, string, bytes,
    /// bool or enum. The renderer leaves it out at its zero value unless
    /// `emitDefaults` is set, as protowire-go leaves out a field `Has` is
    /// false for. Lists and maps need no marker: an empty one is always left
    /// out that way, and a message is always written.
    case implicit(PXFNode)
}

/// Writes an `Encodable` value as PXF text.
///
/// A field follows proto3 implicit presence, as `pxf.Marshal` does in the
/// reference: a non-optional scalar, string, bytes, bool, enum, list or map at
/// its zero value is left out. An `Optional` holding a value is written at zero
/// too, which is how a type marks a proto3 `optional` field. A non-optional
/// message is always written, and a nil one is absent, so a wrapper such as
/// `Google_Protobuf_Int32Value` holding 0 is written. List elements and map
/// values keep their zeros. A negative zero float is not zero: it is written
/// as `-0`, as the reference writes it. A field named in `_null` is written as
/// `null` whatever its value.
///
/// `emitDefaults` writes the zeros back, as the reference's `EmitDefaults`
/// does: every field left out above, an empty list or map, and a nil
/// `Optional` scalar as its zero. A nil message stays absent.
///
/// A zero left out reads back as the field's `(pxf.default)`, not as zero,
/// under a schema-aware decode: the encoder has no schema to see the default
/// in. The reference does the same (protowire-go#259; protowire-swift#58).
/// Declare the field `Optional` to keep the zero.
///
/// A `google.protobuf.Any` is written as whatever its own `encode(to:)` writes,
/// which for the Any's fields is `type_url` and `value`. The encoder never
/// unpacks one into a type entry and a body: a reader compares an Any by its
/// bytes, so a body is allowed only when reading it gives back the stored value
/// byte for byte (draft -01 § Any Blocks), and a Swift type carries no
/// descriptor to check that against. Writing every Any raw conforms.
public final class PXFEncoder {
    public var indent: String = "  "
    public var emitDefaults: Bool = false

    /// Schema annotations; with `rootMessage` also set, a `(pxf.key)` field
    /// is written in the keyed block form whenever every element's key is
    /// present, non-empty and distinct, and as an anonymous list otherwise,
    /// and an enum field's name is written bare. Nil (the default) leaves
    /// both off.
    public var annotations: PXF.Annotations?

    /// Fully qualified proto name of the message being encoded.
    public var rootMessage: String?

    /// The limits for each encode call; only `maxNestingDepth` applies. A
    /// value nested deeper than a decoder at that limit reads is an error,
    /// counted as the decoder counts it: the root is depth 0, and every `{`
    /// or `[` the text opens is one descent (HARDENING.md § Recursion).
    /// Raise it only together with every reader's limit.
    public var limits = Hardening.Limits()

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
        let maxDepth = limits.maxNestingDepth
        let node = try _PXFEncoder.node(for: value, codingPath: [], level: 0, maxDepth: maxDepth)
        var renderer = PXFRenderer(indent: indent, emitDefaults: emitDefaults, annotations: annotations, maxDepth: maxDepth)
        return try renderer.document(node, message: rootMessage.flatMap { annotations?.message($0) })
    }

    /// The node `value` writes as, for a caller that renders it itself.
    /// `level` is the depth the value sits at, so the producer's depth check
    /// counts from there.
    static func node<T: Encodable>(_ value: T, level: Int, maxDepth: Int) throws -> PXFNode {
        try _PXFEncoder.node(for: value, codingPath: [], level: level, maxDepth: maxDepth)
    }
}

/// The `_null` paths a value carries: a `[String]`, or a FieldMask's `paths`.
private func nullPaths(of value: Any) -> [String] {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .struct || mirror.displayStyle == .class else { return [] }
    for child in mirror.children where child.label == "_null" {
        if let paths = child.value as? [String] { return paths }
        for maskChild in Mirror(reflecting: child.value).children where maskChild.label == "paths" {
            if let paths = maskChild.value as? [String] { return paths }
        }
    }
    return []
}

/// The error for a block or list whose contents sit at `level`, past `maxDepth`.
func pxfNestingError(_ value: Any, level: Int, maxDepth: Int, codingPath: [CodingKey]) -> EncodingError {
    EncodingError.invalidValue(value, .init(codingPath: codingPath,
        debugDescription: "pxf: nesting depth \(level) exceeds MaxNestingDepth=\(maxDepth)"))
}

/// Whether a field holding `value` has implicit presence: a scalar, string,
/// bytes, bool or enum, which the renderer leaves out at zero. A message,
/// list or map is none of these. Neither is a `BoundText` item, which is a
/// struct: a bound message has already decided which fields to write.
private func hasImplicitPresence(_ value: Any) -> Bool {
    switch value {
    case is String, is Bool, is Data, is any BinaryInteger, is any BinaryFloatingPoint: return true
    default: return value is any RawRepresentable && Mirror(reflecting: value).displayStyle == .enum
    }
}

/// The zero a nil `Optional` of type `t` writes under `emitDefaults`, or nil
/// for a type that stays absent: a message, list, map or enum.
private func zeroNode(_ t: Any.Type) -> PXFNode? {
    switch t {
    case is String.Type: return .string("")
    case is Bool.Type: return .literal("false")
    case is Data.Type: return .literal("b\"\"")
    case is any BinaryInteger.Type, is any BinaryFloatingPoint.Type: return .literal("0")
    default: return nil
    }
}

/// Writes `field = null` inside the block its path names, making any block on
/// the way: `one.a` belongs in `one`, not at the root as a dotted name. A path
/// names a singular field at each step, so it never crosses a list.
private func insertNull(_ path: ArraySlice<Substring>, into fields: inout [(name: String, node: PXFNode)]) {
    guard let head = path.first.map(String.init) else { return }
    let index = fields.firstIndex { $0.name == head }
    if path.count == 1 {
        if let index { fields[index].node = .null } else { fields.append((head, .null)) }
        return
    }
    var inner: [(name: String, node: PXFNode)] = []
    var typeURL: String?
    if let index, case .message(let existing, let url) = fields[index].node {
        inner = existing
        typeURL = url
    }
    insertNull(path.dropFirst(), into: &inner)
    if let index {
        fields[index].node = .message(inner, typeURL: typeURL)
    } else {
        fields.append((head, .message(inner, typeURL: nil)))
    }
}

private final class _PXFEncoder: Swift.Encoder {
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var fields: [(name: String, node: PXFNode)] = []
    var elements: [PXFNode] = []
    var single: PXFNode?
    var isList = false
    /// The decoder's depth inside the block or list this value opens.
    let level: Int
    let maxDepth: Int

    init(codingPath: [CodingKey], level: Int, maxDepth: Int) {
        self.codingPath = codingPath
        self.level = level
        self.maxDepth = maxDepth
    }

    /// Refuses a member of a block or list that sits past the limit, before
    /// the member is built, so a reference cycle stops here and not on the
    /// stack. A block that stays empty is refused when it is rendered.
    func checkMember(_ value: Any, codingPath: [CodingKey]) throws {
        if level > maxDepth {
            throw pxfNestingError(value, level: level, maxDepth: maxDepth, codingPath: codingPath)
        }
    }

    var result: PXFNode {
        if let single { return single }
        if isList { return .list(elements) }
        return .message(fields, typeURL: nil)
    }

    /// The node for `value`, handling the types with a literal form before
    /// any type gets to run its own `encode(to:)`. `level` is the depth of
    /// the contents `value` would open: one past the body holding it.
    static func node<T: Encodable>(for value: T, codingPath: [CodingKey], level: Int, maxDepth: Int) throws -> PXFNode {
        switch value {
        case let v as _PXFPrebuilt: return v.pxfNode
        case let v as _PXFLiteral: return .literal(try v.pxfLiteral)
        case let v as Google_Protobuf_Duration:
            // Past int64 nanoseconds this falls through to the message form.
            if let text = v.pxfLiteral { return .literal(text) }
        case let v as String: return .string(v)
        case let v as Bool: return .literal(v ? "true" : "false")
        case let v as Double: return .literal(PXF.WellKnown.float(v))
        case let v as Float: return .literal(PXF.WellKnown.float(v))
        case let v as Int: return .literal(String(v))
        case let v as Int8: return .literal(String(v))
        case let v as Int16: return .literal(String(v))
        case let v as Int32: return .literal(String(v))
        case let v as Int64: return .literal(String(v))
        case let v as UInt: return .literal(String(v))
        case let v as UInt8: return .literal(String(v))
        case let v as UInt16: return .literal(String(v))
        case let v as UInt32: return .literal(String(v))
        case let v as UInt64: return .literal(String(v))
        case let v as Data: return .literal("b\"\(v.base64EncodedString())\"")
        case let v as Date:
            let time = v.timeIntervalSince1970
            let seconds = Int64(time.rounded(.down))
            return .literal(PXF.WellKnown.timestampLiteral(seconds: seconds, nanos: Int32(((time - Double(seconds)) * 1e9).rounded())))
        default:
            break
        }

        // Wrapper sugar: only the nine SwiftProtobuf-generated wrapper types
        // are inlined as `key = innerValue`. A user type that happens to have
        // one `value` member stays a nested message.
        if PXFEncoder.isProtobufWrapper(value),
           let inner = Mirror(reflecting: value).children.first(where: { $0.label == "value" })?.value as? Encodable {
            return try Self.node(for: inner, codingPath: codingPath, level: level, maxDepth: maxDepth)
        }

        if let map = value as? _PXFMapValue {
            var entries: [(key: String, node: PXFNode)] = []
            for (key, item) in map.pxfEntries {
                guard let item = item as? Encodable else { continue }
                if level > maxDepth {
                    throw pxfNestingError(value, level: level, maxDepth: maxDepth, codingPath: codingPath)
                }
                let spelled = (key as? String).map(PXF.Format.canonicalEntryName) ?? String(describing: key)
                // A value's own block opens one level inside the map's.
                entries.append((spelled, try Self.node(for: item, codingPath: codingPath + [PXFKey(stringValue: spelled)],
                                                       level: level + 1, maxDepth: maxDepth)))
            }
            return .map(entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) })
        }

        let sub = _PXFEncoder(codingPath: codingPath, level: level, maxDepth: maxDepth)
        try value.encode(to: sub)
        guard case .message(var fields, let inner) = sub.result else { return sub.result }
        for path in nullPaths(of: value) {
            insertNull(path.split(separator: ".")[...], into: &fields)
        }
        return .message(fields, typeURL: inner)
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        KeyedEncodingContainer(KeyedContainer<Key>(encoder: self, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        isList = true
        return UnkeyedContainer(encoder: self, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer { self }

    struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        var encoder: _PXFEncoder
        var codingPath: [CodingKey]

        private func add(_ node: PXFNode, _ key: Key) {
            encoder.fields.append((key.stringValue, node))
        }

        /// Adds `value`. `set` means it is written at zero too, because it
        /// is what an `Optional` held; an `Optional` encoded explicitly that
        /// holds a value is set as well.
        private mutating func addValue<T: Encodable>(_ value: T, _ key: Key, set: Bool = false) throws {
            try encoder.checkMember(value, codingPath: codingPath + [key])
            let node = try _PXFEncoder.node(for: value, codingPath: codingPath + [key],
                                            level: encoder.level + 1, maxDepth: encoder.maxDepth)
            let isSet = set || (value as? _PBOptional)?.pbWrapped != nil
            add(!isSet && hasImplicitPresence(value) ? .implicit(node) : node, key)
        }

        /// An `Optional` property, which a synthesized `encode(to:)` hands
        /// over here. A nil scalar is its zero, written only by `emitDefaults`,
        /// as the reference writes an unset proto3 `optional` field then.
        private mutating func addIfPresent<T: Encodable>(_ value: T?, _ key: Key) throws {
            if key.stringValue == "_null" { return } // written from the mask, not as a field
            if let value {
                try addValue(value, key, set: true)
            } else if let zero = zeroNode(T.self) {
                try encoder.checkMember(value as Any, codingPath: codingPath + [key])
                add(.implicit(zero), key)
            }
        }

        mutating func encodeNil(forKey key: Key) throws {
            try encoder.checkMember(Optional<Int>.none as Any, codingPath: codingPath + [key])
            add(.null, key)
        }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            if key.stringValue == "_null" { return } // written from the mask, not as a field
            try addValue(value, key)
        }

        mutating func encode(_ value: Bool, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: String, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { try addValue(value, key) }
        mutating func encode(_ value: Double, forKey key: Key) throws { try addValue(value, key) }

        mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try addIfPresent(value, key) }
        mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try addIfPresent(value, key) }

        mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { fatalError() }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { fatalError() }
        mutating func superEncoder() -> any Swift.Encoder { encoder }
        mutating func superEncoder(forKey key: Key) -> any Swift.Encoder { encoder }
    }

    struct UnkeyedContainer: UnkeyedEncodingContainer {
        var encoder: _PXFEncoder
        var codingPath: [CodingKey]
        var count: Int { encoder.elements.count }

        mutating func encodeNil() throws {
            try encoder.checkMember(Optional<Int>.none as Any, codingPath: codingPath + [PXFKey(index: count)])
            encoder.elements.append(.null)
        }
        mutating func encode<T: Encodable>(_ value: T) throws {
            let path = codingPath + [PXFKey(index: count)]
            try encoder.checkMember(value, codingPath: path)
            encoder.elements.append(try _PXFEncoder.node(for: value, codingPath: path,
                                                         level: encoder.level + 1, maxDepth: encoder.maxDepth))
        }
        mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { fatalError() }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { fatalError() }
        mutating func superEncoder() -> any Swift.Encoder { encoder }
    }
}

extension _PXFEncoder: SingleValueEncodingContainer {
    func encodeNil() throws { single = .null }
    // A value standing in for this one opens what this one would: same level.
    func encode<T: Encodable>(_ value: T) throws { single = try Self.node(for: value, codingPath: codingPath, level: level, maxDepth: maxDepth) }
    func encode(_ value: Bool) throws { single = .literal(value ? "true" : "false") }
    func encode(_ value: String) throws { single = .string(value) }
    func encode(_ value: Double) throws { single = .literal(PXF.WellKnown.float(value)) }
    func encode(_ value: Float) throws { single = .literal(PXF.WellKnown.float(value)) }
    func encode(_ value: Int) throws { single = .literal(String(value)) }
    func encode(_ value: Int8) throws { single = .literal(String(value)) }
    func encode(_ value: Int16) throws { single = .literal(String(value)) }
    func encode(_ value: Int32) throws { single = .literal(String(value)) }
    func encode(_ value: Int64) throws { single = .literal(String(value)) }
    func encode(_ value: UInt) throws { single = .literal(String(value)) }
    func encode(_ value: UInt8) throws { single = .literal(String(value)) }
    func encode(_ value: UInt16) throws { single = .literal(String(value)) }
    func encode(_ value: UInt32) throws { single = .literal(String(value)) }
    func encode(_ value: UInt64) throws { single = .literal(String(value)) }
}

/// Turns a `PXFNode` into text. This is where a schema changes the output: a
/// keyed field takes its block form and an enum's name goes bare.
struct PXFRenderer {
    let indent: String
    let emitDefaults: Bool
    let annotations: PXF.Annotations?
    /// The deepest level a block or list may open at, as a decoder counts it.
    let maxDepth: Int
    private var out = ""

    init(indent: String, emitDefaults: Bool, annotations: PXF.Annotations?, maxDepth: Int = Hardening.maxNestingDepth) {
        self.indent = indent
        self.emitDefaults = emitDefaults
        self.annotations = annotations
        self.maxDepth = maxDepth
    }

    mutating func document(_ node: PXFNode, message: PXF.Annotations.Message?) throws -> String {
        out = ""
        switch node {
        case .message(let fields, _):
            try body(fields, message: message, level: 0)
        default:
            try write(node, field: nil, level: 0)
            out += "\n"
        }
        return out
    }

    /// Refuses a block or list whose contents sit at `level`. This is the
    /// exact check: it runs on what is written, so an empty list left out
    /// is not counted and an empty block is.
    private func check(_ level: Int) throws {
        if level > maxDepth {
            throw pxfNestingError(level, level: level, maxDepth: maxDepth, codingPath: [])
        }
    }

    private mutating func pad(_ level: Int) {
        for _ in 0..<level { out += indent }
    }

    private mutating func body(_ fields: [(name: String, node: PXFNode)], typeURL: String? = nil,
                               message: PXF.Annotations.Message?, level: Int, skipping skipped: String? = nil) throws {
        try check(level)
        if let typeURL {
            pad(level)
            out += "@type = \(PXFEncoder.quote(typeURL))\n"
        }
        for (name, node) in fields where name != skipped {
            let field = message?.field(named: name)
            switch node {
            case .message(let inner, let url):
                pad(level)
                out += "\(name) {\n"
                try body(inner, typeURL: url, message: messageType(of: field, typeURL: url), level: level + 1)
                pad(level)
                out += "}\n"
            case .implicit(let inner):
                if !emitDefaults && isZero(inner, field) { continue }
                pad(level)
                out += "\(name) = "
                try write(inner, field: field, level: level)
                out += "\n"
            case .list(let items):
                if items.isEmpty {
                    if emitDefaults {
                        // `[` and `]` on lines of their own, as the
                        // reference writes an empty list.
                        try check(level + 1)
                        pad(level)
                        out += "\(name) = [\n"
                        pad(level)
                        out += "]\n"
                    }
                    continue
                }
                if let field, let key = annotations?.keyField(of: field), keyedForm(items, key: key.name) {
                    try keyed(items, name: name, field: field, keyName: key.name, level: level)
                    continue
                }
                pad(level)
                out += "\(name) = "
                try write(node, field: field, level: level)
                out += "\n"
            case .map(let entries):
                if entries.isEmpty && !emitDefaults { continue }
                pad(level)
                out += "\(name) = "
                try write(node, field: field, level: level)
                out += "\n"
            default:
                pad(level)
                out += "\(name) = "
                try write(node, field: field, level: level)
                out += "\n"
            }
        }
    }

    private func messageType(of field: PXF.Annotations.Field?, typeURL: String?) -> PXF.Annotations.Message? {
        if let typeURL { return annotations?.message(PXF.Binder.messageName(ofTypeURL: typeURL)) }
        guard let field else { return nil }
        if field.isMap { return field.mapValueMessage.flatMap { annotations?.message($0) } }
        return field.typeName.flatMap { annotations?.message($0) }
    }

    /// A value after `name = `, or a list element, at the level of its owner.
    private mutating func write(_ node: PXFNode, field: PXF.Annotations.Field?, level: Int) throws {
        switch node {
        case .literal(let text):
            out += text
        case .string(let text):
            // A Swift enum with a String raw value arrives as a string.
            out += field?.type == .enum ? text : PXFEncoder.quote(text)
        case .null:
            out += "null"
        case .implicit(let inner):
            try write(inner, field: field, level: level)
        case .message(let fields, let url):
            out += "{\n"
            try body(fields, typeURL: url, message: messageType(of: field, typeURL: url), level: level + 1)
            pad(level)
            out += "}"
        case .list(let items):
            try check(level + 1)
            out += "[\n"
            let keyName = field.flatMap { annotations?.keyField(of: $0) }?.name
            for (i, item) in items.enumerated() {
                pad(level + 1)
                if case .message(let fields, let url) = item, let keyName {
                    // A list only reaches here when the keyed form cannot
                    // carry it, and a decoder rejects an explicit empty key.
                    let kept = fields.filter { !($0.name == keyName && Self.isEmptyString($0.node)) }
                    try write(.message(kept, typeURL: url), field: field, level: level + 1)
                } else {
                    try write(item, field: field, level: level + 1)
                }
                out += i + 1 < items.count ? ",\n" : "\n"
            }
            pad(level)
            out += "]"
        case .map(let entries):
            try check(level + 1)
            out += "{\n"
            let value = field?.mapEntryFields.first { $0.number == 2 }
            for (key, item) in entries {
                pad(level + 1)
                out += "\(key): "
                try write(item, field: value, level: level + 1)
                out += "\n"
            }
            pad(level)
            out += "}"
        }
    }

    private static func isEmptyString(_ node: PXFNode) -> Bool {
        if case .implicit(let inner) = node { return isEmptyString(inner) }
        if case .string(let s) = node { return s.isEmpty }
        return false
    }

    /// Whether an implicit-presence value is its type's zero, read from the
    /// text it writes: `0`, `false`, `b""`, `""`, or the name of an enum's
    /// number 0. Only a scalar, string, bytes, bool or enum is marked
    /// implicit, so a message's literal (a big number's `0`) never gets here.
    /// `-0` is not zero, since `Has` is true for it in the reference.
    private func isZero(_ node: PXFNode, _ field: PXF.Annotations.Field?) -> Bool {
        switch node {
        case .literal(let text):
            return text == "0" || text == "false" || text == "b\"\""
        case .string(let text):
            if text.isEmpty { return true }
            // A Swift enum with a String raw value arrives as its name.
            guard let field, field.type == .enum else { return false }
            return annotations?.enumName(field.typeName, number: 0) == text
        default:
            return false
        }
    }

    /// Every key present, non-empty and distinct, by bytes: canonically
    /// equivalent keys are distinct.
    private func keyedForm(_ items: [PXFNode], key: String) -> Bool {
        var seen = Set<[UInt8]>()
        for item in items {
            guard let k = Self.key(of: item, key), !k.isEmpty, seen.insert(Array(k.utf8)).inserted else { return false }
        }
        return true
    }

    private static func key(of item: PXFNode, _ key: String) -> String? {
        guard case .message(let fields, _) = item else { return nil }
        for (name, node) in fields where name == key {
            if case .string(let s) = node { return s }
            if case .implicit(.string(let s)) = node { return s }
        }
        return nil
    }

    private mutating func keyed(_ items: [PXFNode], name: String, field: PXF.Annotations.Field, keyName: String, level: Int) throws {
        try check(level + 1)
        pad(level)
        out += "\(name) {\n"
        let element = field.typeName.flatMap { annotations?.message($0) }
        for item in items {
            guard case .message(let fields, let url) = item, let k = Self.key(of: item, keyName) else { continue }
            pad(level + 1)
            out += "\(PXF.Format.canonicalEntryName(k)) {\n"
            try body(fields, typeURL: url, message: element, level: level + 2, skipping: keyName)
            pad(level + 1)
            out += "}\n"
        }
        pad(level)
        out += "}\n"
    }
}
