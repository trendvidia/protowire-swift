// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

// Literal text for the types PXF writes specially, and a `BoundMessage` as an
// `Encodable`, so that ConformanceTests can put a schema-described message
// through `PXFEncoder` the way a user's type goes, and compare the text with
// the reference's marshaller.

extension PXF.WellKnown {
    /// `strconv.FormatFloat(f, 'g', -1, bits)`: the shortest digits that read
    /// back, with an exponent below 1e-4 and from 1e+6. Swift's `description`
    /// gives the same digits, so only the layout is rebuilt.
    static func float<T: BinaryFloatingPoint & LosslessStringConvertible>(_ value: T) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let text = value.description
        let negative = text.hasPrefix("-")
        let parts = (negative ? String(text.dropFirst()) : text).lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(mantissa[0])
        let fraction = mantissa.count > 1 ? String(mantissa[1]) : ""
        var point = whole.count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        var digits = Array((whole + fraction).utf8)
        while digits.first == 48, digits.count > 1 {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == 48, digits.count > 1 { digits.removeLast() }
        let sign = negative ? "-" : ""
        if digits == [48] { return sign + "0" }
        let shown = String(decoding: digits, as: UTF8.self)
        let exponent = point - 1
        if exponent < -4 || exponent >= 6 {
            let rest = shown.dropFirst()
            let e = abs(exponent)
            return "\(sign)\(shown.prefix(1))\(rest.isEmpty ? "" : "." + rest)e\(exponent < 0 ? "-" : "+")\(e < 10 ? "0" : "")\(e)"
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + shown }
        if point >= digits.count { return sign + shown + String(repeating: "0", count: point - digits.count) }
        return sign + shown.prefix(point) + "." + shown.dropFirst(point)
    }

    /// `time.Time.Format(time.RFC3339Nano)` in UTC: no trailing zeros.
    static func timestampLiteral(seconds: Int64, nanos: Int32) -> String {
        var days = seconds / 86400
        var rest = seconds % 86400
        if rest < 0 {
            rest += 86400
            days -= 1
        }
        // Civil from days (Howard Hinnant's algorithm).
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
        var out = "\(String(repeating: "0", count: max(0, 4 - String(year).count)))\(year)-\(two(month))-\(two(day))T"
        out += "\(two(rest / 3600)):\(two(rest / 60 % 60)):\(two(rest % 60))"
        if nanos > 0 {
            var digits = String(nanos)
            digits = String(repeating: "0", count: 9 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            out += "." + digits
        }
        return out + "Z"
    }

    /// `time.Duration.String()`, or nil past what its int64 nanoseconds hold,
    /// where the reference writes the block form.
    static func durationLiteral(seconds: Int64, nanos: Int32) -> String? {
        let (scaled, o1) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (total, o2) = scaled.addingReportingOverflow(Int64(nanos))
        if o1 || o2 { return nil }
        if total == 0 { return "0s" }
        var u = total.magnitude
        let sign = total < 0 ? "-" : ""
        func fraction(_ v: UInt64, _ precision: Int) -> String {
            let unit = (0..<precision).reduce(UInt64(1)) { value, _ in value * 10 }
            let part = v % unit
            if part == 0 { return String(v / unit) }
            var digits = String(part)
            digits = String(repeating: "0", count: precision - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            return "\(v / unit).\(digits)"
        }
        if u < 1_000_000_000 {
            if u < 1_000 { return "\(sign)\(u)ns" }
            if u < 1_000_000 { return "\(sign)\(fraction(u, 3))µs" }
            return "\(sign)\(fraction(u, 6))ms"
        }
        let secondsText = fraction(u % 60_000_000_000, 9) + "s"
        u /= 60_000_000_000
        if u == 0 { return sign + secondsText }
        let minutes = "\(u % 60)m"
        u /= 60
        if u == 0 { return sign + minutes + secondsText }
        return "\(sign)\(u)h\(minutes)\(secondsText)"
    }
}

extension PXF.BoundMessage {
    func value(_ name: String) -> Value? { values.first { $0.field.name == name }?.value }

    /// Reads protobuf bytes the way the stock runtime does: the last of a
    /// singular field wins, and an unknown field is skipped.
    init(reading data: Data, message name: String, annotations: PXF.Annotations) throws {
        self.init(name: name)
        guard let message = annotations.message(name) else { return }
        var rest = data
        var lists: [Int32: [Value]] = [:]
        var maps: [Int32: [(key: Value, value: Value)]] = [:]
        while !rest.isEmpty {
            guard let (number, wire, tagLength) = Protowire.consumeTag(rest) else { throw PB.Error.corruptData }
            rest = rest.dropFirst(tagLength)
            let read = try Self.readValue(wire: wire, from: rest)
            rest = rest.dropFirst(read.length)
            guard let field = message.fields.first(where: { $0.number == number }) else { continue }
            if field.isMap {
                guard case .bytes(let body) = read.raw else { throw PB.Error.corruptData }
                maps[number, default: []].append(try Self.readMapEntry(body, field, annotations))
            } else if field.isRepeated {
                if case .bytes(let packed) = read.raw, ![.string, .bytes, .message, .group].contains(field.type) {
                    var body = packed
                    while !body.isEmpty {
                        let item = try Self.readValue(wire: Self.wireType(of: field), from: body)
                        body = body.dropFirst(item.length)
                        lists[number, default: []].append(try Self.convert(item.raw, field, annotations))
                    }
                } else {
                    lists[number, default: []].append(try Self.convert(read.raw, field, annotations))
                }
            } else {
                values.removeAll { $0.field.number == number }
                set(field, try Self.convert(read.raw, field, annotations))
            }
        }
        for (number, items) in lists {
            if let f = message.fields.first(where: { $0.number == number }) { set(f, .list(items)) }
        }
        for (number, entries) in maps {
            if let f = message.fields.first(where: { $0.number == number }) { set(f, .map(entries)) }
        }
    }

    private static func wireType(of field: PXF.Annotations.Field) -> Protowire.WireType {
        switch field.type {
        case .fixed32, .sfixed32, .float: return .fixed32
        case .fixed64, .sfixed64, .double: return .fixed64
        default: return .varint
        }
    }

    private static func readMapEntry(_ body: Data, _ field: PXF.Annotations.Field,
                                     _ annotations: PXF.Annotations) throws -> (key: Value, value: Value) {
        guard let keyField = field.mapEntryFields.first(where: { $0.number == 1 }),
              let valueField = field.mapEntryFields.first(where: { $0.number == 2 }) else { throw PB.Error.corruptData }
        var key = zero(keyField), value = zero(valueField)
        var rest = body
        while !rest.isEmpty {
            guard let (number, wire, length) = Protowire.consumeTag(rest) else { throw PB.Error.corruptData }
            rest = rest.dropFirst(length)
            let item = try readValue(wire: wire, from: rest)
            rest = rest.dropFirst(item.length)
            if number == 1 { key = try convert(item.raw, keyField, annotations) }
            if number == 2 { value = try convert(item.raw, valueField, annotations) }
        }
        return (key, value)
    }

    private static func readValue(wire: Protowire.WireType, from data: Data) throws -> (raw: Value, length: Int) {
        switch wire {
        case .varint:
            guard let (v, n) = Protowire.consumeVarint(data) else { throw PB.Error.corruptData }
            return (.uint(v), n)
        case .fixed32:
            guard let (v, n) = Protowire.consumeFixed32(data) else { throw PB.Error.corruptData }
            return (.uint(UInt64(v)), n)
        case .fixed64:
            guard let (v, n) = Protowire.consumeFixed64(data) else { throw PB.Error.corruptData }
            return (.uint(v), n)
        case .bytes:
            guard let (v, n) = Protowire.consumeBytes(data) else { throw PB.Error.corruptData }
            return (.bytes(v), n)
        default:
            throw PB.Error.corruptData
        }
    }

    private static func convert(_ raw: Value, _ field: PXF.Annotations.Field, _ annotations: PXF.Annotations) throws -> Value {
        switch (field.type, raw) {
        case (.string, .bytes(let v)):
            guard let s = String(data: v, encoding: .utf8) else { throw PB.Error.corruptData }
            return .string(s)
        case (.bytes, .bytes):
            return raw
        case (.message, .bytes(let v)):
            return .message(try PXF.BoundMessage(reading: v, message: field.typeName ?? "", annotations: annotations))
        case (.bool, .uint(let v)):
            return .bool(v != 0)
        case (.int32, .uint(let v)), (.enum, .uint(let v)):
            return .int(Int64(Int32(truncatingIfNeeded: v)))
        case (.int64, .uint(let v)):
            return .int(Int64(bitPattern: v))
        case (.sint32, .uint(let v)), (.sint64, .uint(let v)):
            return .int(Protowire.decodeZigZag(v))
        case (.sfixed32, .uint(let v)):
            return .int(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: v))))
        case (.sfixed64, .uint(let v)):
            return .int(Int64(bitPattern: v))
        case (.uint32, .uint), (.uint64, .uint), (.fixed32, .uint), (.fixed64, .uint):
            return raw
        case (.float, .uint(let v)):
            return .float(Float(bitPattern: UInt32(truncatingIfNeeded: v)))
        case (.double, .uint(let v)):
            return .double(Double(bitPattern: v))
        default:
            throw PB.Error.corruptData
        }
    }

    private static func zero(_ field: PXF.Annotations.Field) -> Value {
        switch field.type {
        case .bool: return .bool(false)
        case .string: return .string("")
        case .bytes: return .bytes(Data())
        case .float: return .float(0)
        case .double: return .double(0)
        case .message, .group: return .message(PXF.BoundMessage(name: field.typeName ?? ""))
        case .uint32, .uint64, .fixed32, .fixed64: return .uint(0)
        default: return .int(0)
        }
    }
}

extension PXF {
    /// A `BoundMessage` as an `Encodable`. Fields go in declaration order, as
    /// the reference walks them, which is the order a synthesized `encode`
    /// keeps too.
    struct BoundText: Encodable {
        let message: BoundMessage
        let annotations: Annotations
        /// The nesting depth of this body's entries, as the parser counts it:
        /// 0 for a document. An Any's body is checked at the depth it lands.
        var depth = 0

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: PXFKey.self)
            for field in annotations.message(message.name)?.fields ?? [] {
                guard let value = message.value(field.name), BoundItem.isWritten(value, field) else { continue }
                try container.encode(BoundItem(field: field, value: value, annotations: annotations, depth: depth),
                                     forKey: PXFKey(stringValue: field.name))
            }
        }
    }

    /// An Any's type entry and body, already rendered once and read back.
    private struct OpenedAny: Encodable, _PXFPrebuilt {
        let pxfNode: PXFNode
        func encode(to encoder: Encoder) throws {}
    }

    private struct Literal: Encodable, _PXFLiteral {
        let pxfLiteral: String
        func encode(to encoder: Encoder) throws {}
    }

    private struct BoundMap: Encodable, _PXFMapValue {
        let entries: [(key: BoundMessage.Value, value: BoundMessage.Value)]
        let field: Annotations.Field
        let annotations: Annotations
        /// The depth of the map's own block, where its values sit.
        let depth: Int

        var pxfEntries: [(key: Any, value: Any)] {
            guard let valueField = field.mapEntryFields.first(where: { $0.number == 2 }) else { return [] }
            return entries.map { entry in
                let key: Any
                switch entry.key {
                case .bool(let v): key = v
                case .int(let v): key = v
                case .uint(let v): key = v
                case .string(let v): key = v
                default: key = ""
                }
                return (key, BoundItem(field: valueField, value: entry.value, annotations: annotations, depth: depth, inCollection: true))
            }
        }

        func encode(to encoder: Encoder) throws {}
    }

    private struct BoundItem: Encodable {
        let field: Annotations.Field
        let value: BoundMessage.Value
        let annotations: Annotations
        /// The depth of the body, list or map this value is written in.
        let depth: Int
        /// A list element or map value: an Any stays its own fields there.
        var inCollection = false

        static func isWritten(_ value: BoundMessage.Value, _ field: Annotations.Field) -> Bool {
            switch value {
            case .list(let items): return !items.isEmpty
            case .map(let entries): return !entries.isEmpty
            default: return field.hasPresence || !BoundMessage.isZero(value)
            }
        }

        func encode(to encoder: Encoder) throws {
            if case .list(let items) = value {
                var c = encoder.unkeyedContainer()
                for item in items {
                    try c.encode(BoundItem(field: field, value: item, annotations: annotations, depth: depth + 1, inCollection: true))
                }
                return
            }
            var c = encoder.singleValueContainer()
            switch value {
            case .map(let entries):
                try c.encode(BoundMap(entries: entries, field: field, annotations: annotations, depth: depth + 1))
            case .bool(let v): try c.encode(v)
            case .int(let v):
                if field.type == .enum, let name = annotations.enumName(field.typeName, number: Int32(truncatingIfNeeded: v)) {
                    try c.encode(Literal(pxfLiteral: name))
                } else {
                    try c.encode(v)
                }
            case .uint(let v): try c.encode(v)
            case .float(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .bytes(let v): try c.encode(v)
            case .message(let m):
                if let literal = try Self.literal(m, annotations) {
                    try c.encode(Literal(pxfLiteral: literal))
                } else if m.name == WellKnown.any, !inCollection, let opened = Self.opened(m, depth: depth + 1, annotations) {
                    try c.encode(opened)
                } else {
                    try c.encode(BoundText(message: m, annotations: annotations, depth: depth + 1))
                }
            case .list:
                break
            }
        }

        /// The Any as a type entry and a body of the type it names, or nil to
        /// leave it to its own fields, `type_url` and `value`. A reader
        /// compares an Any by its bytes, so a body is written only when
        /// reading it back gives exactly the stored value (draft -01 § Any
        /// Blocks, protowire#501): what the text cannot say, such as an
        /// unknown field, a field or map order, an explicit zero or a
        /// Timestamp past year 9999, and what the reader would change, a
        /// default or a required field left unset, all stay raw. The check is
        /// the reader's own, as in protowire-go: render the body, parse it at
        /// `depth`, the depth of the Any's block, bind it and compare the
        /// packed bytes. Past the depth limit the Any is not unpacked at all,
        /// which bounds a chain of Anys: each holds the next as bytes, so the
        /// wire does not.
        ///
        /// The body is rendered with the default indent and without
        /// `emitDefaults`, which writes only an empty list or map, and a bound
        /// message has none to write.
        private static func opened(_ m: BoundMessage, depth: Int, _ annotations: Annotations) -> OpenedAny? {
            let limits = Hardening.Limits()
            guard depth <= limits.maxNestingDepth, case .string(let url)? = m.value("type_url"), !url.isEmpty else { return nil }
            var packed = Data()
            if case .bytes(let v)? = m.value("value") { packed = v }
            let name = Binder.messageName(ofTypeURL: url)
            guard let message = annotations.message(name),
                  let inner = try? BoundMessage(reading: packed, message: name, annotations: annotations),
                  case .message(let fields, _)? = try? PXFEncoder.node(BoundText(message: inner, annotations: annotations, depth: depth))
            else { return nil }
            var renderer = PXFRenderer(indent: "  ", emitDefaults: false, annotations: annotations)
            let text = renderer.document(.message(fields, typeURL: nil), message: message)
            do {
                let parser = Parser(input: Data(text.utf8))
                parser.limits = limits
                parser.bodyDepth = depth
                let expanded = try annotations.expandKeyed(try parser.parseDocument().entries, message: name)
                try Annotations.rejectQuotedNames(expanded)
                let binder = Binder(annotations: annotations, resolve: { annotations.message(Binder.messageName(ofTypeURL: $0)) != nil },
                                    limits: limits)
                guard try binder.bind(expanded, message: name).message.serialized() == packed else { return nil }
            } catch {
                return nil
            }
            return OpenedAny(pxfNode: .message(fields, typeURL: url))
        }

        private static func literal(_ m: BoundMessage, _ annotations: Annotations) throws -> String? {
            func int(_ name: String) -> Int64 {
                if case .int(let v)? = m.value(name) { return v }
                return 0
            }
            func bytes(_ name: String) -> Data {
                if case .bytes(let v)? = m.value(name) { return v }
                return Data()
            }
            func bool(_ name: String) -> Bool {
                if case .bool(let v)? = m.value(name) { return v }
                return false
            }
            switch m.name {
            case WellKnown.timestamp:
                return WellKnown.timestampLiteral(seconds: int("seconds"), nanos: Int32(truncatingIfNeeded: int("nanos")))
            case WellKnown.duration:
                return WellKnown.durationLiteral(seconds: int("seconds"), nanos: Int32(truncatingIfNeeded: int("nanos")))
            default:
                break
            }
            if WellKnown.wrappers.contains(m.name) {
                switch m.value("value") {
                case .bool(let v)?: return v ? "true" : "false"
                case .int(let v)?: return String(v)
                case .uint(let v)?: return String(v)
                case .float(let v)?: return WellKnown.float(v)
                case .double(let v)?: return WellKnown.float(v)
                case .string(let v)?: return PXFEncoder.quote(v)
                case .bytes(let v)?: return "b\"\(v.base64EncodedString())\""
                default: break
                }
                switch annotations.message(m.name)?.field(named: "value")?.type {
                case .bool?: return "false"
                case .string?: return "\"\""
                case .bytes?: return "b\"\""
                default: return "0"
                }
            }
            if m.name == WellKnown.secret, m.value("hint") == nil, m.value("fingerprint") == nil {
                if case .string(let v)? = m.value("value") { return PXFEncoder.quote(v) }
                return "\"\""
            }
            if m.name == WellKnown.bigInt {
                var n = Pxf_BigInt()
                n.abs = bytes("abs")
                n.negative = bool("negative")
                return try n.pxfLiteral
            }
            if m.name == WellKnown.decimal {
                var n = Pxf_Decimal()
                n.unscaled = bytes("unscaled")
                n.scale = Int32(truncatingIfNeeded: int("scale"))
                n.negative = bool("negative")
                return try n.pxfLiteral
            }
            if m.name == WellKnown.bigFloat {
                var n = Pxf_BigFloat()
                n.mantissa = bytes("mantissa")
                n.exponent = Int32(truncatingIfNeeded: int("exponent"))
                if case .uint(let v)? = m.value("prec") { n.prec = UInt32(truncatingIfNeeded: v) }
                n.negative = bool("negative")
                return try n.pxfLiteral
            }
            return nil
        }
    }
}
