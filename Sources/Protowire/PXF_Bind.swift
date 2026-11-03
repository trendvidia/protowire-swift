// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

// The schema-bound pass. A Swift type only sees the fields it asks for, so a
// rule about a whole message body cannot live in the Codable containers: an
// unread field would escape it. This pass walks the document against the
// descriptor, enforces the draft's binding rules and builds the message, and
// the Codable decoder runs afterwards on the same entries. The rules, and their
// order, follow `decodeFields` and `postDecode` in protowire-go's
// encoding/pxf/decode_fast.go.

extension PXF {
    /// A decode error from the schema-bound pass, in the reference's wording.
    public struct BindError: Error, CustomStringConvertible, Equatable {
        public var pos: Position
        public var message: String
        public var description: String { "[\(pos)] \(message)" }
    }

    /// What a message body bound to. `serialized()` gives protobuf bytes in
    /// the reference's deterministic order.
    struct BoundMessage {
        indirect enum Value {
            case bool(Bool)
            case int(Int64)
            case uint(UInt64)
            case float(Float)
            case double(Double)
            case string(String)
            case bytes(Data)
            case message(BoundMessage)
            case list([Value])
            case map([(key: Value, value: Value)])
        }

        var name: String
        var values: [(field: Annotations.Field, value: Value)] = []

        mutating func set(_ field: Annotations.Field, _ value: Value) {
            values.append((field, value))
        }

        func has(_ name: String) -> Bool { values.contains { $0.field.name == name } }

        /// Fields outside a real oneof first, then by number: the order of
        /// protobuf-go's deterministic marshal.
        func serialized() -> Data {
            let ordered = values.sorted { a, b in
                let ao = a.field.oneof != nil, bo = b.field.oneof != nil
                if ao != bo { return !ao }
                return a.field.number < b.field.number
            }
            var out = Data()
            for (field, value) in ordered { Self.write(value, of: field, into: &out) }
            return out
        }

        private static func write(_ value: Value, of field: Annotations.Field, into out: inout Data) {
            switch value {
            case .list(let items):
                if items.isEmpty { return }
                if field.isPacked {
                    var body = Data()
                    for item in items { writePayload(item, of: field, into: &body) }
                    Protowire.appendTag(&out, number: field.number, type: .bytes)
                    Protowire.appendBytes(&out, body)
                } else {
                    for item in items { writeOne(item, of: field, into: &out) }
                }
            case .map(let entries):
                guard let keyField = field.mapEntryFields.first(where: { $0.number == 1 }),
                      let valueField = field.mapEntryFields.first(where: { $0.number == 2 }) else { return }
                for entry in entries.sorted(by: { less($0.key, $1.key) }) {
                    var body = Data()
                    writeOne(entry.key, of: keyField, into: &body)
                    writeOne(entry.value, of: valueField, into: &body)
                    Protowire.appendTag(&out, number: field.number, type: .bytes)
                    Protowire.appendBytes(&out, body)
                }
            default:
                if !field.hasPresence && isZero(value) { return }
                writeOne(value, of: field, into: &out)
            }
        }

        private static func less(_ a: Value, _ b: Value) -> Bool {
            switch (a, b) {
            case (.bool(let x), .bool(let y)): return !x && y
            case (.int(let x), .int(let y)): return x < y
            case (.uint(let x), .uint(let y)): return x < y
            case (.string(let x), .string(let y)): return x.utf8.lexicographicallyPrecedes(y.utf8)
            default: return false
            }
        }

        private static func isZero(_ value: Value) -> Bool {
            switch value {
            case .bool(let v): return !v
            case .int(let v): return v == 0
            case .uint(let v): return v == 0
            // By bits: -0.0 is a value protobuf-go writes.
            case .float(let v): return v.bitPattern == 0
            case .double(let v): return v.bitPattern == 0
            case .string(let v): return v.isEmpty
            case .bytes(let v): return v.isEmpty
            case .message, .list, .map: return false
            }
        }

        private static func writeOne(_ value: Value, of field: Annotations.Field, into out: inout Data) {
            switch field.type {
            case .group:
                Protowire.appendVarint(&out, UInt64(field.number) << 3 | 3)
                writePayload(value, of: field, into: &out)
                Protowire.appendVarint(&out, UInt64(field.number) << 3 | 4)
                return
            case .string, .bytes, .message:
                Protowire.appendTag(&out, number: field.number, type: .bytes)
            case .fixed32, .sfixed32, .float:
                Protowire.appendTag(&out, number: field.number, type: .fixed32)
            case .fixed64, .sfixed64, .double:
                Protowire.appendTag(&out, number: field.number, type: .fixed64)
            default:
                Protowire.appendTag(&out, number: field.number, type: .varint)
            }
            writePayload(value, of: field, into: &out)
        }

        private static func writePayload(_ value: Value, of field: Annotations.Field, into out: inout Data) {
            switch value {
            case .bool(let v):
                Protowire.appendVarint(&out, v ? 1 : 0)
            case .int(let v):
                switch field.type {
                case .sint32: Protowire.appendVarint(&out, UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: (v << 1) ^ (v >> 31)))))
                case .sint64: Protowire.appendVarint(&out, UInt64(bitPattern: (v << 1) ^ (v >> 63)))
                case .sfixed32: Protowire.appendFixed32(&out, UInt32(bitPattern: Int32(truncatingIfNeeded: v)))
                case .sfixed64: Protowire.appendFixed64(&out, UInt64(bitPattern: v))
                default: Protowire.appendVarint(&out, UInt64(bitPattern: v))
                }
            case .uint(let v):
                switch field.type {
                case .fixed32: Protowire.appendFixed32(&out, UInt32(truncatingIfNeeded: v))
                case .fixed64: Protowire.appendFixed64(&out, v)
                default: Protowire.appendVarint(&out, v)
                }
            case .float(let v):
                Protowire.appendFixed32(&out, v.bitPattern)
            case .double(let v):
                Protowire.appendFixed64(&out, v.bitPattern)
            case .string(let v):
                Protowire.appendString(&out, v)
            case .bytes(let v):
                Protowire.appendBytes(&out, v)
            case .message(let m):
                if field.type == .group {
                    out.append(m.serialized())
                } else {
                    Protowire.appendBytes(&out, m.serialized())
                }
            case .list, .map:
                break
            }
        }
    }

    /// One bind of one document. `resolve` answers whether an Any's type URL
    /// resolves; `bind` returns the message and the entries for the Codable
    /// decoder, which are the input with each applied default added.
    struct Binder {
        let annotations: Annotations
        /// nil: no resolver was given, so an Any's type entry cannot bind.
        var resolve: ((String) -> Bool)?
        var discardUnknown = false

        /// The message an Any's type URL names, after its last "/".
        static func messageName(ofTypeURL url: String) -> String {
            url.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? url
        }

        func bind(_ entries: [Entry], message name: String) throws -> (message: BoundMessage, entries: [Entry]) {
            guard let message = annotations.message(name) else {
                return (BoundMessage(name: name), entries)
            }
            return try body(entries, of: message, depth: 0, path: "")
        }

        /// One `@dataset` row, as the body it stands for (draft §3.4.4).
        /// The header rules run per row, so a table with no rows passes them.
        func bindRow(columns: [String], row: DatasetRow, message name: String) throws -> (message: BoundMessage, entries: [Entry]) {
            guard annotations.message(name) != nil else {
                return (BoundMessage(name: name), Dataset.entries(columns: columns, row: row))
            }
            if let problem = Dataset.columnProblem(columns, message: name, in: annotations) {
                throw fail(row.pos, problem)
            }
            let expanded = try annotations.expandKeyed(Dataset.entries(columns: columns, row: row), message: name)
            try Annotations.rejectQuotedNames(expanded)
            return try bind(expanded, message: name)
        }

        private func fail(_ pos: Position, _ message: String) -> BindError {
            BindError(pos: pos, message: message)
        }

        // MARK: - bodies

        private func body(_ entries: [Entry], of message: Annotations.Message, depth: Int, path: String) throws -> (message: BoundMessage, entries: [Entry]) {
            var out = BoundMessage(name: message.fullName)
            var normalized: [Entry] = []
            var bound: Set<String> = []
            var present: Set<String> = []
            var chosenOneof: [String: String] = [:]
            var lists: [String: [BoundMessage.Value]] = [:]
            var maps: [String: [(key: BoundMessage.Value, value: BoundMessage.Value)]] = [:]
            var mapKeys: [String: Set<String>] = [:]
            var listOrder: [Annotations.Field] = []

            /// The checks every singular binding passes through.
            func bindOnce(_ field: Annotations.Field, _ pos: Position) throws {
                if let oneof = field.oneof {
                    if let previous = chosenOneof[oneof] {
                        throw fail(pos, "oneof \"\(oneof)\": field \"\(field.name)\" conflicts with already-set field \"\(previous)\"")
                    }
                    chosenOneof[oneof] = field.name
                }
                if !field.isRepeated && !field.isMap, !bound.insert(field.name).inserted {
                    throw fail(pos, "field \"\(field.name)\" is already set")
                }
                present.insert(field.name)
            }

            for entry in entries {
                switch entry {
                case let a as Assignment:
                    guard let field = message.field(named: a.key) else {
                        if discardUnknown { continue }
                        throw fail(a.pos, "unknown field \"\(a.key)\" in \(message.fullName)")
                    }
                    try bindOnce(field, a.pos)
                    normalized.append(entry)
                    if a.value is NullVal {
                        if !Self.nullable(field) { throw nullNotAllowed(a.value.pos, field) }
                        continue
                    }
                    if field.isMap {
                        guard let block = a.value as? BlockVal else {
                            throw fail(a.value.pos, "expected '{' for map field \"\(field.name)\"")
                        }
                        var rewritten = a
                        rewritten.value = try mapBody(block, field, into: &maps[field.name, default: []], seen: &mapKeys[field.name, default: []], depth: depth + 1, path: path + field.name)
                        normalized[normalized.count - 1] = rewritten
                        if !listOrder.contains(where: { $0.name == field.name }) { listOrder.append(field) }
                    } else if field.isRepeated {
                        guard let list = a.value as? ListVal else {
                            throw fail(a.value.pos, "expected '[' for repeated field \"\(field.name)\"")
                        }
                        var rewrittenList = list
                        for (i, element) in list.elements.enumerated() {
                            if element is NullVal {
                                throw fail(element.pos, "null is not allowed in repeated field \"\(field.name)\"")
                            }
                            let index = lists[field.name]?.count ?? 0
                            let result = try singular(element, field, depth: depth + 1, path: "\(path)\(field.name)[\(index)].")
                            lists[field.name, default: []].append(result.value)
                            rewrittenList.elements[i] = Self.withEntries(element, result.entries)
                        }
                        var rewritten = a
                        rewritten.value = rewrittenList
                        normalized[normalized.count - 1] = rewritten
                        if !listOrder.contains(where: { $0.name == field.name }) { listOrder.append(field) }
                    } else {
                        let result = try singular(a.value, field, depth: depth, path: path + field.name + ".")
                        out.set(field, result.value)
                        if let inner = result.entries, let v = a.value as? BlockVal {
                            var rewritten = a
                            var block = v
                            block.entries = inner
                            rewritten.value = block
                            normalized[normalized.count - 1] = rewritten
                        }
                    }

                case let b as Block:
                    guard let field = message.field(named: b.name) else {
                        if discardUnknown { continue }
                        throw fail(b.pos, "unknown field \"\(b.name)\" in \(message.fullName)")
                    }
                    guard field.type == .message || field.type == .group else {
                        throw fail(b.pos, "field \"\(b.name)\" is not a message type, cannot use block syntax")
                    }
                    if field.isMap {
                        throw fail(b.pos, "map field \"\(b.name)\" must use assignment syntax: \(b.name) = { ... }")
                    }
                    if field.isRepeated {
                        throw fail(b.pos, "repeated field \"\(b.name)\" must use list syntax: \(b.name) = [...]")
                    }
                    try bindOnce(field, b.pos)
                    let result = try blockValue(BlockVal(pos: b.pos, typeURL: b.typeURL, entries: b.entries), field, depth: depth, path: path + field.name + ".")
                    out.set(field, .message(result.message))
                    var rewritten = b
                    rewritten.entries = result.entries
                    normalized.append(rewritten)

                case is MapEntry:
                    throw fail(entry.pos, "unexpected ':' in message context, use '=' for field assignments")

                default:
                    normalized.append(entry)
                }
            }

            for field in listOrder {
                if field.isMap {
                    out.set(field, .map(maps[field.name] ?? []))
                } else {
                    out.set(field, .list(lists[field.name] ?? []))
                }
            }

            // The reference's post-decode pass, over this body only: nested
            // bodies ran theirs when they were bound.
            for field in message.fields where !present.contains(field.name) {
                if field.required {
                    throw AnnotationError.requiredFieldAbsent(path: path + field.name)
                }
                guard field.defaultLiteral != nil else { continue }
                if let oneof = field.oneof, chosenOneof[oneof] != nil { continue }
                guard let value = try annotations.defaultValue(for: field) else { continue }
                let result = try singular(value, field, depth: depth, path: path + field.name + ".")
                out.set(field, result.value)
                var synthesized = Assignment(pos: Position(line: 0, column: 0), key: field.name, value: value, leadingComments: [])
                synthesized.isDefault = true
                normalized.append(synthesized)
            }
            return (out, normalized)
        }

        private func mapBody(_ block: BlockVal, _ field: Annotations.Field,
                             into entries: inout [(key: BoundMessage.Value, value: BoundMessage.Value)],
                             seen: inout Set<String>, depth: Int, path: String) throws -> BlockVal {
            guard field.mapEntryFields.count == 2,
                  let keyField = field.mapEntryFields.first(where: { $0.number == 1 }),
                  let valueField = field.mapEntryFields.first(where: { $0.number == 2 }) else { return block }
            var rewritten = block
            for (i, entry) in block.entries.enumerated() {
                guard let m = entry as? MapEntry else {
                    if entry is Assignment {
                        throw fail(entry.pos, "unexpected '=' in map, use ':' for map entries")
                    }
                    throw fail(entry.pos, "expected ':' after map key")
                }
                let (key, spelling) = try mapKey(m, field, keyField)
                guard seen.insert(spelling).inserted else {
                    throw fail(m.pos, "map field \"\(field.name)\": key \(m.key) is already set")
                }
                if m.value is NullVal {
                    throw fail(m.value.pos, "null is not allowed as map value in field \"\(field.name)\"")
                }
                let result = try singular(m.value, valueField, named: field, depth: depth, path: "\(path)[\"\(m.key)\"].")
                entries.append((key, result.value))
                var entryOut = m
                entryOut.value = Self.withEntries(m.value, result.entries)
                rewritten.entries[i] = entryOut
            }
            return rewritten
        }

        /// `value` with a block's entries replaced by their normal form.
        private static func withEntries(_ value: Value, _ entries: [Entry]?) -> Value {
            guard var block = value as? BlockVal, let entries else { return value }
            block.entries = entries
            return block
        }

        /// A map key as a value of the key type, so `1:` and `"1":` on an int
        /// key are one key. The second result identifies it for the repeat
        /// check, by bytes: Swift's == would merge canonically equal strings.
        private func mapKey(_ m: MapEntry, _ field: Annotations.Field, _ keyField: Annotations.Field) throws -> (BoundMessage.Value, String) {
            let raw = m.key
            if m.keyKind == .number, let precision = PXF.splitPrecision(raw).precision {
                throw fail(m.pos, "map field \"\(field.name)\": a key cannot carry a precision suffix (p\(PXF.clip(precision)))")
            }
            let invalid = { (type: String) in fail(m.pos, "invalid \(type) map key: \(raw)") }
            switch keyField.type {
            case .string:
                if m.keyKind == .bool {
                    throw fail(m.pos, "invalid string map key \(raw) for field \"\(field.name)\": the keyword \(raw) is a bool key; write \"\(raw)\" for the string")
                }
                return (.string(raw), raw.utf8.map(String.init).joined(separator: ","))
            case .int32, .sint32, .sfixed32:
                guard m.keyKind != .bool, let n = Int32(raw) else { throw invalid("int32") }
                return (.int(Int64(n)), String(n))
            case .int64, .sint64, .sfixed64:
                guard m.keyKind != .bool, let n = Int64(raw) else { throw invalid("int64") }
                return (.int(n), String(n))
            case .uint32, .fixed32:
                guard m.keyKind != .bool, let n = UInt32(raw) else { throw invalid("uint32") }
                return (.uint(UInt64(n)), String(n))
            case .uint64, .fixed64:
                guard m.keyKind != .bool, let n = UInt64(raw) else { throw invalid("uint64") }
                return (.uint(n), String(n))
            case .bool:
                switch raw {
                case "true", "1": return (.bool(true), "true")
                case "false", "0": return (.bool(false), "false")
                default: throw invalid("bool")
                }
            default:
                throw invalid("key")
            }
        }

        // MARK: - values

        /// One value of a singular field, a list element or a map value.
        /// `entries` is set when the value is a block, with its defaults added.
        private func singular(_ value: Value, _ field: Annotations.Field, named: Annotations.Field? = nil,
                              depth: Int, path: String) throws -> (value: BoundMessage.Value, entries: [Entry]?) {
            let named = named ?? field
            switch field.type {
            case .message, .group:
                if let block = value as? BlockVal {
                    let result = try blockValue(block, field, depth: depth, path: path)
                    return (.message(result.message), result.entries)
                }
                return (.message(try literalMessage(value, field, named: named)), nil)
            default:
                return (try scalar(value, field, named: named), nil)
            }
        }

        private func blockValue(_ block: BlockVal, _ field: Annotations.Field, depth: Int, path: String) throws -> (message: BoundMessage, entries: [Entry]) {
            guard let name = field.typeName else { return (BoundMessage(name: ""), block.entries) }
            guard let message = annotations.message(name) else {
                return (BoundMessage(name: name), block.entries)
            }
            guard let url = block.typeURL else {
                return try body(block.entries, of: message, depth: depth + 1, path: path)
            }
            guard name == WellKnown.any else {
                throw fail(block.pos, "@type is only allowed in a block bound to google.protobuf.Any")
            }
            guard let resolve else {
                throw fail(block.pos, "cannot resolve Any type \"\(url)\": no TypeResolver")
            }
            guard resolve(url) else {
                throw fail(block.pos, "cannot resolve Any type \"\(url)\"")
            }
            let innerName = Self.messageName(ofTypeURL: url)
            guard let inner = annotations.message(innerName) else {
                return (BoundMessage(name: name), block.entries)
            }
            let bound = try body(block.entries, of: inner, depth: depth, path: path)
            var any = BoundMessage(name: name)
            if let f = message.field(named: "type_url") { any.set(f, .string(url)) }
            if let f = message.field(named: "value") { any.set(f, .bytes(bound.message.serialized())) }
            return (any, bound.entries)
        }

        /// A well-known message written as a literal.
        private func literalMessage(_ value: Value, _ field: Annotations.Field, named: Annotations.Field) throws -> BoundMessage {
            let name = field.typeName ?? ""
            let message = annotations.message(name)
            var out = BoundMessage(name: name)
            func set(_ fieldName: String, _ v: BoundMessage.Value) {
                if let f = message?.field(named: fieldName) { out.set(f, v) }
            }
            let literal = PXF.numericLiteral(value)
            if name == WellKnown.bigFloat, let literal {
                let parsed = try PXF.parseBigFloat(literal)
                set("mantissa", .bytes(parsed.mantissa))
                set("exponent", .int(Int64(parsed.exponent)))
                set("prec", .uint(UInt64(parsed.prec)))
                set("negative", .bool(parsed.negative))
                return out
            }
            try rejectPrecision(value, named)
            if name == WellKnown.decimal, let literal {
                let parsed = try PXF.parseDecimal(literal)
                set("unscaled", .bytes(parsed.unscaled))
                set("scale", .int(Int64(parsed.scale)))
                set("negative", .bool(parsed.negative))
                return out
            }
            switch value {
            case let t as TimestampVal where name == WellKnown.timestamp:
                guard let (seconds, nanos) = WellKnown.parseTimestamp(t.raw) else {
                    throw fail(value.pos, "invalid timestamp \"\(t.raw)\"")
                }
                set("seconds", .int(seconds))
                set("nanos", .int(Int64(nanos)))
                return out
            case let d as DurationVal where name == WellKnown.duration:
                guard let (seconds, nanos) = WellKnown.parseDuration(d.raw) else {
                    throw fail(value.pos, "invalid duration \"\(d.raw)\"")
                }
                set("seconds", .int(seconds))
                set("nanos", .int(Int64(nanos)))
                return out
            case let i as IntVal where name == WellKnown.bigInt:
                let (abs, negative) = try PXF.parseBigInt(i.raw, codingPath: [])
                set("abs", .bytes(abs))
                set("negative", .bool(negative))
                return out
            default:
                break
            }
            if WellKnown.wrappers.contains(name), let inner = message?.field(named: "value") {
                set("value", try scalar(value, inner, named: named))
                return out
            }
            if name == WellKnown.secret, value is StringVal, let inner = message?.field(named: "value") {
                set("value", try scalar(value, inner, named: named))
                return out
            }
            throw fail(value.pos, "expected a message value for field \"\(named.name)\", got \(type(of: value))")
        }

        /// A precision suffix belongs on a `pxf.BigFloat` and nowhere else.
        private func rejectPrecision(_ value: Value, _ named: Annotations.Field) throws {
            if let raw = PXF.numericLiteral(value), let precision = PXF.splitPrecision(raw).precision {
                throw fail(value.pos, "precision suffix p\(PXF.clip(precision)) is allowed only on a pxf.BigFloat, not on field \"\(named.name)\"")
            }
        }

        private func scalar(_ value: Value, _ field: Annotations.Field, named: Annotations.Field) throws -> BoundMessage.Value {
            let pos = value.pos
            try rejectPrecision(value, named)
            switch field.type {
            case .string:
                guard let v = value as? StringVal else { throw fail(pos, "expected string for field \"\(named.name)\"") }
                return .string(v.value)
            case .bool:
                guard let v = value as? BoolVal else { throw fail(pos, "expected bool for field \"\(named.name)\"") }
                return .bool(v.value)
            case .int32, .sint32, .sfixed32:
                guard let v = value as? IntVal else { throw fail(pos, "expected integer for field \"\(named.name)\"") }
                guard let n = Int32(v.raw) else { throw fail(pos, "invalid int32: \(v.raw)") }
                return .int(Int64(n))
            case .int64, .sint64, .sfixed64:
                guard let v = value as? IntVal else { throw fail(pos, "expected integer for field \"\(named.name)\"") }
                guard let n = Int64(v.raw) else { throw fail(pos, "invalid int64: \(v.raw)") }
                return .int(n)
            case .uint32, .fixed32:
                guard let v = value as? IntVal else { throw fail(pos, "expected integer for field \"\(named.name)\"") }
                guard let n = UInt32(v.raw) else { throw fail(pos, "invalid uint32: \(v.raw)") }
                return .uint(UInt64(n))
            case .uint64, .fixed64:
                guard let v = value as? IntVal else { throw fail(pos, "expected integer for field \"\(named.name)\"") }
                guard let n = UInt64(v.raw) else { throw fail(pos, "invalid uint64: \(v.raw)") }
                return .uint(n)
            case .float:
                return .float(Float(try number(value, named, width: "float") { Float($0) }))
            case .double:
                return .double(try number(value, named, width: "double") { Double($0) })
            case .bytes:
                guard let v = value as? BytesVal else { throw fail(pos, "expected bytes for field \"\(named.name)\"") }
                return .bytes(v.value)
            case .enum:
                if let v = value as? IdentVal {
                    guard let n = annotations.enumNumber(field.typeName, value: v.name) else {
                        throw fail(pos, "unknown enum value \"\(v.name)\" for \(field.typeName ?? "")")
                    }
                    return .int(Int64(n))
                }
                if let v = value as? IntVal {
                    guard let n = Int32(v.raw) else { throw fail(pos, "invalid enum number: \(v.raw)") }
                    return .int(Int64(n))
                }
                throw fail(pos, "expected enum name or number for field \"\(named.name)\"")
            case .message, .group:
                throw fail(pos, "expected a message value for field \"\(named.name)\"")
            }
        }

        /// A number in `width`, as `strconv.ParseFloat` reads it: a finite
        /// literal that overflows the width is an error, not an infinity.
        private func number<T: BinaryFloatingPoint>(_ value: Value, _ named: Annotations.Field, width: String,
                                                    parse: (String) -> T?) throws -> Double {
            let raw: String
            switch value {
            case let v as FloatVal: raw = v.raw
            case let v as IntVal: raw = v.raw
            case let v as IdentVal where WellKnown.nonFinite.contains(v.name): raw = v.name
            default: throw fail(value.pos, "expected number for field \"\(named.name)\"")
            }
            switch raw.lowercased() {
            case "nan": return .nan
            case "inf", "+inf", "infinity", "+infinity": return .infinity
            case "-inf", "-infinity": return -.infinity
            default: break
            }
            guard let n = parse(raw), n.isFinite else { throw fail(value.pos, "invalid \(width): \(raw)") }
            return Double(n)
        }

        // MARK: - null

        /// Whether `null` may bind to `field`: it needs an unset state, so a
        /// list, a map and a plain proto3 scalar are out, and a required
        /// field must be set.
        static func nullable(_ field: Annotations.Field) -> Bool {
            field.hasPresence && !field.isRepeated && !field.isMap && !field.isRequiredLabel
        }

        private func nullNotAllowed(_ pos: Position, _ field: Annotations.Field) -> BindError {
            if field.isMap { return fail(pos, "null is not allowed on map field \"\(field.name)\"") }
            if field.isRepeated { return fail(pos, "null is not allowed on repeated field \"\(field.name)\"") }
            if field.isRequiredLabel {
                return fail(pos, "null is not allowed on scalar field \"\(field.name)\": the field is required, so it must be set")
            }
            return fail(pos, "null is not allowed on scalar field \"\(field.name)\": declare it optional, or as a wrapper type, to make it nullable")
        }
    }

    /// How a `@dataset` row becomes a message body. A cell in column `c` means
    /// what `c = <value>` means in a body of the row type, an empty cell means
    /// nothing, and cells sharing a dotted prefix land in one block.
    enum Dataset {
        private final class Node {
            let name: String
            var cell: Value?
            var children: [Node] = []
            init(name: String, cell: Value? = nil) {
                self.name = name
                self.cell = cell
            }
        }

        static func entries(columns: [String], row: DatasetRow) -> [Entry] {
            let root = Node(name: "")
            for (column, cell) in zip(columns, row.cells) {
                guard let cell else { continue }
                var segments = column.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                let leaf = segments.removeLast()
                var node = root
                for segment in segments {
                    if let next = node.children.first(where: { $0.cell == nil && $0.name == segment }) {
                        node = next
                    } else {
                        let next = Node(name: segment)
                        node.children.append(next)
                        node = next
                    }
                }
                node.children.append(Node(name: leaf, cell: cell.value))
            }
            return body(root, pos: row.pos)
        }

        private static func body(_ node: Node, pos: Position) -> [Entry] {
            node.children.map { child -> Entry in
                if let cell = child.cell {
                    return Assignment(pos: pos, key: child.name, value: cell, leadingComments: [])
                }
                return Block(pos: pos, name: child.name, entries: body(child, pos: pos), leadingComments: [])
            }
        }

        /// The header rules that need the row type. A path names a field at
        /// each segment, and goes only through singular message fields not
        /// written as a literal of their own.
        static func columnProblem(_ columns: [String], message name: String, in annotations: Annotations) -> String? {
            for column in columns {
                var current = annotations.message(name)
                let segments = column.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                for (i, segment) in segments.enumerated() {
                    guard let message = current else { break }
                    guard let field = message.field(named: segment) else {
                        return "@dataset column \"\(column)\": \(message.fullName) has no field \"\(segment)\""
                    }
                    if i == segments.count - 1 { break }
                    let at = segments[...i].joined(separator: ".")
                    if field.isMap {
                        return "@dataset column \"\(column)\": \"\(at)\" is a map field, and a column path cannot go through one; use a value cell for \"\(at)\" (draft §3.4.4)"
                    }
                    if field.isRepeated {
                        return "@dataset column \"\(column)\": \"\(at)\" is a repeated field, and a column path cannot go through one; use a value cell for \"\(at)\" (draft §3.4.4)"
                    }
                    guard field.type == .message || field.type == .group, let sub = field.typeName else {
                        return "@dataset column \"\(column)\": \"\(at)\" is not a message field"
                    }
                    if WellKnown.writtenAsLiteral(sub) {
                        return "@dataset column \"\(column)\": \"\(at)\" is a \(sub), which is written as a literal; a column path cannot go into it (draft §3.4.4)"
                    }
                    current = annotations.message(sub)
                }
            }
            return nil
        }
    }

    /// Names and literal forms of the types PXF writes specially.
    enum WellKnown {
        static let any = "google.protobuf.Any"
        static let timestamp = "google.protobuf.Timestamp"
        static let duration = "google.protobuf.Duration"
        static let bigInt = "pxf.BigInt"
        static let decimal = "pxf.Decimal"
        static let bigFloat = "pxf.BigFloat"
        static let secret = "pxf.Secret"
        static let wrappers: Set<String> = [
            "google.protobuf.DoubleValue", "google.protobuf.FloatValue",
            "google.protobuf.Int64Value", "google.protobuf.UInt64Value",
            "google.protobuf.Int32Value", "google.protobuf.UInt32Value",
            "google.protobuf.BoolValue", "google.protobuf.StringValue",
            "google.protobuf.BytesValue",
        ]
        static let nonFinite: Set<String> = ["nan", "inf"]

        /// A type with a literal form and no useful fields of its own. A
        /// `pxf.Secret` has a block form too, so a column path may enter one.
        static func writtenAsLiteral(_ name: String) -> Bool {
            wrappers.contains(name) || [timestamp, duration, bigInt, decimal, bigFloat].contains(name)
        }

        /// `time.ParseDuration`, exactly, into a `Duration`'s two fields. A
        /// Double loses nanoseconds on a long duration, so this counts in
        /// integers, and it refuses what overflows Go's int64 nanoseconds.
        static func parseDuration(_ s: String) -> (seconds: Int64, nanos: Int32)? {
            let bytes = Array(s.utf8)
            var i = 0
            var negative = false
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 {
                negative = bytes[i] == 45
                i += 1
            }
            if i == bytes.count { return nil }
            if i + 1 == bytes.count, bytes[i] == 48 { return (0, 0) }
            var total: UInt64 = 0
            while i < bytes.count {
                var whole: UInt64 = 0
                var fraction: UInt64 = 0
                var scale: UInt64 = 1
                var digits = 0
                while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 {
                    let (m, o1) = whole.multipliedReportingOverflow(by: 10)
                    let (a, o2) = m.addingReportingOverflow(UInt64(bytes[i] - 48))
                    if o1 || o2 { return nil }
                    whole = a
                    i += 1
                    digits += 1
                }
                if i < bytes.count, bytes[i] == 46 {
                    i += 1
                    while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 {
                        digits += 1
                        if scale < 1 << 61 {
                            fraction = fraction * 10 + UInt64(bytes[i] - 48)
                            scale *= 10
                        }
                        i += 1
                    }
                }
                if digits == 0 { return nil }
                let unitStart = i
                while i < bytes.count, bytes[i] != 46, bytes[i] < 48 || bytes[i] > 57 { i += 1 }
                let unit: UInt64
                switch String(decoding: bytes[unitStart..<i], as: UTF8.self) {
                case "ns": unit = 1
                case "us", "µs", "μs": unit = 1_000
                case "ms": unit = 1_000_000
                case "s": unit = 1_000_000_000
                case "m": unit = 60_000_000_000
                case "h": unit = 3_600_000_000_000
                default: return nil
                }
                let (scaled, o1) = whole.multipliedReportingOverflow(by: unit)
                if o1 { return nil }
                // Fraction * unit / scale, truncated, as Go computes it.
                let part = UInt64((Double(fraction) * (Double(unit) / Double(scale))))
                let (sum, o2) = scaled.addingReportingOverflow(part)
                let (next, o3) = total.addingReportingOverflow(sum)
                if o2 || o3 { return nil }
                total = next
            }
            if negative {
                if total > 1 << 63 { return nil }
                let n = total == 1 << 63 ? Int64.min : -Int64(total)
                return (n / 1_000_000_000, Int32(n % 1_000_000_000))
            }
            guard total < 1 << 63 else { return nil }
            let n = Int64(total)
            return (n / 1_000_000_000, Int32(n % 1_000_000_000))
        }

        /// RFC 3339, to a Timestamp's fields, keeping every nanosecond digit.
        static func parseTimestamp(_ s: String) -> (seconds: Int64, nanos: Int32)? {
            let b = Array(s.utf8)
            func digits(_ at: Int, _ n: Int) -> Int? {
                guard at + n <= b.count else { return nil }
                var v = 0
                for c in b[at..<(at + n)] {
                    guard c >= 48, c <= 57 else { return nil }
                    v = v * 10 + Int(c - 48)
                }
                return v
            }
            guard let year = digits(0, 4), b.count > 19, b[4] == 45,
                  let month = digits(5, 2), b[7] == 45,
                  let day = digits(8, 2), b[10] == 84 || b[10] == 116,
                  let hour = digits(11, 2), b[13] == 58,
                  let minute = digits(14, 2), b[16] == 58,
                  let second = digits(17, 2),
                  (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...lengths[month - 1]).contains(day) else { return nil }
            var i = 19
            var nanos = 0
            if i < b.count, b[i] == 46 {
                i += 1
                let start = i
                var place = 100_000_000
                while i < b.count, b[i] >= 48, b[i] <= 57 {
                    nanos += Int(b[i] - 48) * place
                    place /= 10
                    i += 1
                }
                if i == start { return nil }
            }
            var offset = 0
            guard i < b.count else { return nil }
            if b[i] == 90 || b[i] == 122 {
                i += 1
            } else if b[i] == 43 || b[i] == 45 {
                guard let h = digits(i + 1, 2), i + 3 < b.count, b[i + 3] == 58, let m = digits(i + 4, 2) else { return nil }
                offset = (h * 3600 + m * 60) * (b[i] == 45 ? -1 : 1)
                i += 6
            } else {
                return nil
            }
            guard i == b.count else { return nil }
            // Days from civil (Howard Hinnant's algorithm).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            let seconds = Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offset)
            return (seconds, Int32(nanos))
        }
    }
}
