// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

// Keyed repeated fields (draft-trendvidia-protowire-01 "Keyed Repeated
// Fields", trendvidia/protowire#116): a `repeated <Message>` field carrying
// `(pxf.key)` may be written as a block of named blocks, entry name = key
// field value, entry order = list order.
//
// Go, Rust and C++ read the keyed block inside a decode loop that has a
// descriptor in hand. The Codable decoder has none: it matches entries to a
// Swift type's CodingKeys. So the schema work happens on the AST before the
// type sees it. `expandKeyed` checks the keyed rules and rewrites every keyed
// binding to the anonymous list it is equivalent to, with the key field
// written out, and from there the ordinary list path decodes it. This file
// also holds the placement rules and `canonicalizeKeyed`, the schema half of
// `pxf fmt`. Keyed emission is in PXF_Encoder.swift. Mirrors protowire-go's
// encoding/pxf/keyed.go.

extension PXF {
    /// Classifies a `KeyedError`.
    public enum KeyedErrorKind: Equatable {
        /// Two entries of one keyed block whose names are equal after unquoting.
        case duplicateKey
        /// An explicit key-field assignment disagrees with the entry name.
        case keyConflict
        /// The empty string used as a key, as an entry name or as an explicit
        /// assignment to the key field, in either surface form.
        case emptyKey
        /// A quoted entry name anywhere but inside a keyed field's block.
        case quotedNameUnkeyed
        /// An entry of a keyed block that is not a named block.
        case malformedEntry
    }

    /// A keyed-repeated-field decode error. `message` carries the reference's
    /// wording.
    public struct KeyedError: Error, CustomStringConvertible, Equatable {
        public var pos: Position
        public var kind: KeyedErrorKind
        /// The keyed repeated field; empty for `.quotedNameUnkeyed`, where
        /// no keyed field exists.
        public var field: String
        /// The offending key or entry name, when one applies.
        public var key: String
        public var message: String

        public var description: String { "[\(pos)] \(message)" }
    }
}

extension PXF.Format {
    /// Whether `s` can be written as an unquoted entry name: it matches the
    /// identifier production and is not a value keyword. Canonical form
    /// writes a name unquoted exactly when this holds.
    public static func identSafeEntryName(_ s: String) -> Bool {
        if s == "true" || s == "false" || s == "null" { return false }
        let bytes = Array(s.utf8)
        guard let first = bytes.first else { return false }
        func isStart(_ b: UInt8) -> Bool {
            (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b == 0x5F
        }
        guard isStart(first) else { return false }
        return bytes.dropFirst().allSatisfy { isStart($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }
    }

    /// `name` as it appears in canonical form.
    static func canonicalEntryName(_ name: String) -> String {
        identSafeEntryName(name) ? name : PXFEncoder.quote(name)
    }
}

extension PXF.Annotations {
    private typealias KeyedError = PXF.KeyedError
    private typealias Entry = PXF.Entry
    private typealias Assignment = PXF.Assignment
    private typealias Block = PXF.Block
    private typealias BlockVal = PXF.BlockVal
    private typealias ListVal = PXF.ListVal
    private typealias MapEntry = PXF.MapEntry
    private typealias StringVal = PXF.StringVal

    // MARK: - Placement

    /// The key field of a keyed repeated field, or nil when `field` has no
    /// `(pxf.key)` or its placement is invalid. `validateKeyPlacement`
    /// reports the invalid ones; this declines to treat them as keyed.
    public func keyField(of field: Field) -> Field? {
        keyFieldProblem(of: field) == nil ? keyFieldCandidate(of: field) : nil
    }

    private func keyFieldCandidate(of field: Field) -> Field? {
        guard let keyName = field.keyName, let element = field.typeName else { return nil }
        return message(element)?.field(named: keyName)
    }

    /// Why `field`'s `(pxf.key)` is misplaced, or nil when it is well placed
    /// or absent.
    func keyFieldProblem(of field: Field) -> String? {
        guard let keyName = field.keyName else { return nil }
        guard field.isRepeated, !field.isMap, field.type == .message else {
            return "(pxf.key) is valid only on repeated message-typed fields"
        }
        guard let element = field.typeName, let elementMessage = message(element) else {
            return "element message \(field.typeName ?? "") is not in the descriptor set"
        }
        guard let key = elementMessage.field(named: keyName) else {
            return "element message \(element) has no field \"\(keyName)\""
        }
        guard !key.isRepeated, !key.isMap, key.type == .string else {
            return "key field \(element).\(keyName) must be a singular string field"
        }
        return nil
    }

    // MARK: - Decoding

    /// Rewrites every keyed binding under `message` to its anonymous list:
    /// entry name to key field, entry order to list order, and all bindings
    /// of one field concatenated in document order, enforcing the keyed
    /// rules on the way. The result decodes through the ordinary list path.
    func expandKeyed(_ entries: [PXF.Entry], message name: String) throws -> [PXF.Entry] {
        guard let message = message(name) else { return entries }
        var out: [Entry] = []
        var firstBinding: [String: Int] = [:]

        func bind(_ fieldName: String, _ pos: PXF.Position, _ elements: [PXF.Value]) {
            if let i = firstBinding[fieldName], var a = out[i] as? Assignment, var list = a.value as? ListVal {
                list.elements += elements
                a.value = list
                out[i] = a
            } else {
                firstBinding[fieldName] = out.count
                out.append(Assignment(pos: pos, key: fieldName, value: ListVal(pos: pos, elements: elements), leadingComments: []))
            }
        }

        for entry in entries {
            if let a = entry as? Assignment, !a.keyQuoted, let field = message.field(named: a.key) {
                if let key = keyField(of: field) {
                    if let bv = a.value as? BlockVal {
                        bind(a.key, a.pos, try expandKeyedBlock(bv.entries, field: field, key: key))
                        continue
                    }
                    if let lv = a.value as? ListVal {
                        bind(a.key, a.pos, try expandAnonymous(lv, field: field, key: key))
                        continue
                    }
                }
                var expanded = a
                expanded.value = try expandValue(a.value, field: field)
                out.append(expanded)
            } else if let b = entry as? Block, !b.nameQuoted, let field = message.field(named: b.name) {
                if let key = keyField(of: field) {
                    bind(b.name, b.pos, try expandKeyedBlock(b.entries, field: field, key: key))
                    continue
                }
                var expanded = b
                expanded.entries = try expandBody(b.entries, field: field)
                out.append(expanded)
            } else {
                out.append(entry)
            }
        }
        return out
    }

    /// One keyed block: each entry becomes a list element carrying its key.
    private func expandKeyedBlock(_ entries: [PXF.Entry], field: Field, key: Field) throws -> [PXF.Value] {
        var seen = Set<[UInt8]>()
        var elements: [PXF.Value] = []
        for entry in entries {
            let name: String, pos: PXF.Position, body: [Entry]
            if let b = entry as? Block {
                (name, pos, body) = (b.name, b.pos, b.entries)
            } else if let a = entry as? Assignment {
                guard let bv = a.value as? BlockVal else {
                    throw KeyedError(pos: a.pos, kind: .malformedEntry, field: field.name, key: a.key,
                                     message: "keyed entry \"\(a.key)\" of field \"\(field.name)\" must have a block value ('{ ... }'): the element type is a message")
                }
                (name, pos, body) = (a.key, a.pos, bv.entries)
            } else {
                let m = entry as? MapEntry
                throw KeyedError(pos: entry.pos, kind: .malformedEntry, field: field.name, key: m?.key ?? "",
                                 message: "expected '{' or '=' after entry name \"\(m?.key ?? "")\" in keyed field \"\(field.name)\", got ':'")
            }
            if name.isEmpty {
                throw KeyedError(pos: pos, kind: .emptyKey, field: field.name, key: "",
                                 message: "empty entry name in keyed field \"\(field.name)\": the empty string is not a valid key")
            }
            // Bytes, not String ==: Swift's equality is canonical equivalence,
            // which would call two distinct keys the same one.
            guard seen.insert(Array(name.utf8)).inserted else {
                throw KeyedError(pos: pos, kind: .duplicateKey, field: field.name, key: name,
                                 message: "duplicate key \"\(name)\" in keyed field \"\(field.name)\"")
            }
            try checkExplicitKey(in: body, field: field, key: key, entryName: name)
            var expanded = try expandKeyed(body, message: field.typeName ?? "")
            // A surviving explicit entry already agrees, or is a shape error
            // the type should see. `key = null` sets nothing, so the name
            // goes first and wins the decoder's first match.
            let explicit = body.contains {
                if let a = $0 as? Assignment { return a.key == key.name && !(a.value is PXF.NullVal) }
                return ($0 as? Block)?.name == key.name
            }
            if !explicit {
                expanded.insert(Assignment(pos: pos, key: key.name, value: StringVal(pos: pos, value: name), leadingComments: []), at: 0)
            }
            elements.append(BlockVal(pos: pos, typeURL: nil, entries: expanded))
        }
        return elements
    }

    private func expandAnonymous(_ list: PXF.ListVal, field: Field, key: Field) throws -> [PXF.Value] {
        try list.elements.map { element in
            guard var bv = element as? BlockVal else { return element }
            try checkExplicitKey(in: bv.entries, field: field, key: key, entryName: nil)
            bv.entries = try expandKeyed(bv.entries, message: field.typeName ?? "")
            return bv
        }
    }

    /// An explicit key assignment must not be empty, and inside a named
    /// entry must agree with the name. The decoder takes a bare identifier
    /// for a string, so one counts here too.
    private func checkExplicitKey(in body: [PXF.Entry], field: Field, key: Field, entryName: String?) throws {
        for entry in body {
            guard let a = entry as? Assignment, !a.keyQuoted, a.key == key.name else { continue }
            guard let value = (a.value as? StringVal)?.value ?? (a.value as? PXF.IdentVal)?.name else { continue }
            if value.isEmpty {
                throw KeyedError(pos: a.value.pos, kind: .emptyKey, field: field.name, key: "",
                                 message: "explicit empty-string assignment to key field \"\(key.name)\" of keyed field \"\(field.name)\": the empty string is not a valid key")
            }
            if let entryName, !Self.sameKey(value, entryName) {
                throw KeyedError(pos: a.value.pos, kind: .keyConflict, field: field.name, key: entryName,
                                 message: "key field \"\(key.name)\" = \"\(value)\" conflicts with entry name \"\(entryName)\" in keyed field \"\(field.name)\"")
            }
        }
    }

    static func sameKey(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// Descends an assignment's value into the messages it holds.
    private func expandValue(_ value: PXF.Value, field: Field) throws -> PXF.Value {
        if var bv = value as? BlockVal {
            bv.entries = try expandBody(bv.entries, field: field, typeURL: bv.typeURL)
            return bv
        }
        if var lv = value as? ListVal, field.type == .message, field.isRepeated, !field.isMap, let element = field.typeName {
            lv.elements = try lv.elements.map { item in
                guard var bv = item as? BlockVal else { return item }
                bv.entries = try expandKeyed(bv.entries, message: element)
                return bv
            }
            return lv
        }
        return value
    }

    /// Descends a block bound to `field`: a singular message, an Any body
    /// that names a type in this set, or a map whose values are messages.
    private func expandBody(_ entries: [PXF.Entry], field: Field, typeURL: String? = nil) throws -> [PXF.Entry] {
        guard field.type == .message else { return entries }
        if field.isMap {
            guard let valueMessage = field.mapValueMessage else { return entries }
            return try entries.map { entry in
                guard var m = entry as? MapEntry, var bv = m.value as? BlockVal else { return entry }
                bv.entries = try expandKeyed(bv.entries, message: valueMessage)
                m.value = bv
                return m
            }
        }
        guard !field.isRepeated, let sub = typeURL ?? field.typeName else { return entries }
        return try expandKeyed(entries, message: sub)
    }

    /// Rejects a quoted entry name. A string name never names a field, so
    /// one that survives `expandKeyed` is outside every keyed block. Also
    /// the rule with no schema at all: nothing is keyed then, and the quoted
    /// spelling must not reach a type's CodingKeys as if it were a field.
    static func rejectQuotedNames(_ entries: [PXF.Entry]) throws {
        for entry in entries {
            if let a = entry as? Assignment {
                if a.keyQuoted { throw quotedNameError(a.pos, a.key) }
                try rejectQuotedNames(in: a.value)
            } else if let b = entry as? Block {
                if b.nameQuoted { throw quotedNameError(b.pos, b.name) }
                try rejectQuotedNames(b.entries)
            } else if let m = entry as? MapEntry {
                try rejectQuotedNames(in: m.value)
            }
        }
    }

    private static func rejectQuotedNames(in value: PXF.Value) throws {
        if let bv = value as? BlockVal {
            try rejectQuotedNames(bv.entries)
        } else if let lv = value as? ListVal {
            for element in lv.elements { try rejectQuotedNames(in: element) }
        }
    }

    private static func quotedNameError(_ pos: PXF.Position, _ name: String) -> KeyedError {
        KeyedError(pos: pos, kind: .quotedNameUnkeyed, field: "", key: name,
                   message: "quoted entry name \"\(name)\" is only valid inside a keyed repeated field's block (draft -01 §3.13)")
    }

    // MARK: - Canonical form

    /// Rewrites `doc` to the canonical keyed form, with `message` as its
    /// schema. Per keyed field binding it converts an eligible anonymous list
    /// to the keyed block form, normalizes `name = { ... }` to `name { ... }`,
    /// unquotes identifier-safe names and drops redundant key assignments.
    /// Ineligible bindings stay anonymous and entries that do not resolve
    /// stay as they are, so formatting an invalid document loses nothing.
    /// Follow with `PXF.Format.formatDocument`; the pair is `pxf fmt`.
    public func canonicalizeKeyed(_ doc: inout PXF.Document, message: String) {
        doc.entries = canonEntries(doc.entries, message: message)
    }

    private func canonEntries(_ entries: [PXF.Entry], message name: String) -> [PXF.Entry] {
        guard let message = message(name) else { return entries }
        return entries.map { entry in
            if let a = entry as? Assignment, !a.keyQuoted, let field = message.field(named: a.key) {
                return canonAssignment(a, field: field)
            }
            if var b = entry as? Block, !b.nameQuoted, let field = message.field(named: b.name) {
                if let key = keyField(of: field) { return canonKeyedBlock(b, field: field, key: key) }
                b.entries = canonBody(b.entries, field: field)
                return b
            }
            return entry
        }
    }

    private func canonAssignment(_ a: PXF.Assignment, field: Field) -> PXF.Entry {
        var a = a
        if var bv = a.value as? BlockVal {
            if let key = keyField(of: field) {
                let block = Block(pos: a.pos, name: a.key, entries: bv.entries, leadingComments: a.leadingComments)
                return canonKeyedBlock(block, field: field, key: key)
            }
            bv.entries = canonBody(bv.entries, field: field)
            a.value = bv
            return a
        }
        if var lv = a.value as? ListVal, field.type == .message, field.isRepeated, !field.isMap, let element = field.typeName {
            if let key = keyField(of: field), let block = keyedBlock(a, list: lv, field: field, key: key) {
                return block
            }
            lv.elements = lv.elements.map { item in
                guard var bv = item as? BlockVal else { return item }
                bv.entries = canonEntries(bv.entries, message: element)
                return bv
            }
            a.value = lv
        }
        return a
    }

    private func canonBody(_ entries: [PXF.Entry], field: Field) -> [PXF.Entry] {
        guard field.type == .message else { return entries }
        if field.isMap {
            guard let valueMessage = field.mapValueMessage else { return entries }
            return entries.map { entry in
                guard var m = entry as? MapEntry, var bv = m.value as? BlockVal else { return entry }
                bv.entries = canonEntries(bv.entries, message: valueMessage)
                m.value = bv
                return m
            }
        }
        guard !field.isRepeated, let sub = field.typeName else { return entries }
        return canonEntries(entries, message: sub)
    }

    private func canonKeyedBlock(_ block: PXF.Block, field: Field, key: Field) -> PXF.Block {
        var block = block
        let element = field.typeName ?? ""
        block.entries = block.entries.map { entry in
            var named: Block
            if let b = entry as? Block {
                named = b
            } else if let a = entry as? Assignment, let bv = a.value as? BlockVal {
                named = Block(pos: a.pos, name: a.key, entries: bv.entries, leadingComments: a.leadingComments, nameQuoted: a.keyQuoted)
            } else {
                return entry // malformed; leave it for the decoder to report
            }
            if named.nameQuoted && PXF.Format.identSafeEntryName(named.name) { named.nameQuoted = false }
            named.entries = canonEntries(dropKeyAssignments(named.entries, keyName: key.name, entryName: named.name), message: element)
            return named
        }
        return block
    }

    /// Removes the agreeing `keyName = "entryName"` assignment. A disagreeing
    /// or non-string one stays: that document is invalid and formatting must
    /// not change what it says. The dropped entry's leading comments move to
    /// the next surviving entry.
    private func dropKeyAssignments(_ entries: [PXF.Entry], keyName: String, entryName: String) -> [PXF.Entry] {
        var pending: [PXF.Comment] = []
        var out: [Entry] = []
        for entry in entries {
            if let a = entry as? Assignment, !a.keyQuoted, a.key == keyName,
               let sv = a.value as? StringVal, Self.sameKey(sv.value, entryName) {
                pending += a.leadingComments
                continue
            }
            if pending.isEmpty {
                out.append(entry)
            } else if var a = entry as? Assignment {
                a.leadingComments = pending + a.leadingComments
                out.append(a)
                pending = []
            } else if var b = entry as? Block {
                b.leadingComments = pending + b.leadingComments
                out.append(b)
                pending = []
            } else if var m = entry as? MapEntry {
                m.leadingComments = pending + m.leadingComments
                out.append(m)
                pending = []
            }
        }
        return out
    }

    /// The keyed block form of an eligible anonymous binding: every element a
    /// block with exactly one non-empty, distinct explicit string key. Nil
    /// when the binding has to stay anonymous.
    private func keyedBlock(_ a: PXF.Assignment, list: PXF.ListVal, field: Field, key: Field) -> PXF.Block? {
        var seen = Set<[UInt8]>()
        var named: [(String, PXF.BlockVal)] = []
        for item in list.elements {
            guard let bv = item as? BlockVal, let name = Self.explicitKey(of: bv.entries, keyName: key.name), !name.isEmpty,
                  seen.insert(Array(name.utf8)).inserted else { return nil }
            named.append((name, bv))
        }
        let element = field.typeName ?? ""
        var block = Block(pos: a.pos, name: a.key, entries: [], leadingComments: a.leadingComments)
        block.entries = named.map { name, bv in
            let body = dropKeyAssignments(bv.entries, keyName: key.name, entryName: name)
            return Block(pos: bv.pos, name: name, entries: canonEntries(body, message: element), leadingComments: [],
                         nameQuoted: !PXF.Format.identSafeEntryName(name))
        }
        return block
    }

    /// The single explicit string assignment to `keyName`; nil when there
    /// is none, more than one, a quoted spelling or a non-string value.
    private static func explicitKey(of entries: [PXF.Entry], keyName: String) -> String? {
        var found: String?
        for entry in entries {
            guard let a = entry as? Assignment, a.key == keyName else { continue }
            guard let sv = a.value as? StringVal, !a.keyQuoted, found == nil else { return nil }
            found = sv.value
        }
        return found
    }
}
