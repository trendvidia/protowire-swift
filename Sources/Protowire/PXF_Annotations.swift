// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

extension PXF {
    /// The schema-side half of `(pxf.required)` = 1314, `(pxf.default)` =
    /// 1315 and `(pxf.key)` = 1316 (protowire `proto/pxf/annotations.proto`),
    /// indexed from a descriptor set for the Codable bridge to consult.
    ///
    /// The decoder itself has no descriptor: it matches document entries to
    /// a Swift type's `CodingKeys` by name, and those names are the proto
    /// field names — a type keyed any other way cannot decode PXF at all.
    /// So the annotations attach by the same names: `PXFDecoder` given an
    /// `Annotations` and a `rootMessage` looks up each keyed container's
    /// message (nested containers follow the descriptor's `type_name`),
    /// rejects an absent `required` field, and hands the Swift type a
    /// synthesised value for an absent `default` field.
    ///
    /// Semantics follow the Go reference's `postDecode`
    /// (`protowire-go/encoding/pxf/decode_fast.go`): a field set to `null`
    /// counts as present; validation and defaults apply in every message
    /// body, list elements, map values and `Any` bodies included; a defaulted
    /// field is still reported absent by `PXF.Result`, since it was not in
    /// the input.
    ///
    /// Some schemas have no single meaning, and the draft refuses them
    /// whatever a document contains: both annotations on one field, a default
    /// no literal can denote, and the oneof rules. Building an `Annotations`
    /// records them and does not fail; `validateSchema(message:)` reports
    /// them, and `PXFDecoder` calls that before it reads a document.
    ///
    /// Both spellings are read: the bracket options, and `@required` /
    /// `@default` in the 1327 annotation carrier. The brackets are read from
    /// the extension fields of a descriptor set parsed with
    /// `Pxf_Annotations_Extensions`, and from its unknown bytes otherwise.
    public struct Annotations {
        /// One proto field, as far as the decoder needs to know it.
        public struct Field: Equatable {
            public var name: String
            public var number: Int32
            public var type: Google_Protobuf_FieldDescriptorProto.TypeEnum
            /// Fully qualified message or enum name, without the leading dot.
            public var typeName: String?
            public var isRepeated: Bool
            public var isMap: Bool
            public var required: Bool
            /// The default as a literal: `(pxf.default)`, or `@default` reduced
            /// to the same form.
            public var defaultLiteral: String?
            /// The `(pxf.key)` value as written in the schema, valid or not;
            /// `Annotations.keyField(of:)` resolves a well-placed one.
            public var keyName: String?
            /// For a map field, the message its values are, if they are one.
            public var mapValueMessage: String?
            /// The oneof this field belongs to; nil for a proto3 `optional`
            /// field, whose synthetic oneof is not a oneof to a document.
            public var oneof: String?
            /// Whether the field can be unset rather than zero: a message, a
            /// oneof member, a proto3 `optional`, a proto2 optional, or an
            /// editions field with explicit presence.
            public var hasPresence: Bool = false
            /// A proto2 `required`, or editions `LEGACY_REQUIRED`.
            public var isRequiredLabel: Bool = false
            /// A repeated scalar written as one length-delimited record.
            public var isPacked: Bool = false
            /// For a map field, its entry's key and value fields.
            public var mapEntryFields: [Field] = []
            /// Which spelling supplied `required`, for a diagnostic that
            /// quotes what the author wrote.
            var requiredFromCarrier = false
            /// Which spelling supplied the default.
            var defaultFromCarrier = false
            /// Why the default can't be used; see `FieldAnnotations`.
            var defaultProblem: String?

            var requiredSpelling: String { requiredFromCarrier ? "@required" : "(pxf.required)" }
            var defaultSpelling: String { defaultFromCarrier ? "@default" : "(pxf.default)" }
        }

        /// One message: its fields by proto name, in declaration order.
        public struct Message: Equatable {
            public var fullName: String
            public var fields: [Field]
            public func field(named name: String) -> Field? {
                fields.first { $0.name == name }
            }
        }

        private var messages: [String: Message] = [:]
        /// Enum value names by fully qualified enum name.
        private var enums: [String: [String: Int32]] = [:]
        /// The file declaring each message.
        private var messageFiles: [String: String] = [:]
        /// Per file, the files it imports.
        private var imports: [String: [String]] = [:]
        /// Per file, what it declares that the draft refuses. Computed once
        /// here; a decode only walks the import closure.
        private var violations: [String: [AnnotationError]] = [:]

        /// Every message declared in `descriptorSet`, including nested ones.
        public init(descriptorSet: Google_Protobuf_FileDescriptorSet) {
            self.init(files: descriptorSet.file)
        }

        public init(files: [Google_Protobuf_FileDescriptorProto]) {
            for file in files {
                let prefix = file.package.isEmpty ? "" : file.package + "."
                imports[file.name] = file.dependency
                for e in file.enumType { indexEnum(e, prefix: prefix) }
                for m in file.messageType { index(m, prefix: prefix, file: file) }
            }
            for (fullName, file) in messageFiles.sorted(by: { $0.key < $1.key }) {
                guard let message = messages[fullName] else { continue }
                violations[file, default: []] += schemaViolations(of: message, file: file)
            }
        }

        private func schemaViolations(of message: Message, file: String) -> [AnnotationError] {
            var out: [AnnotationError] = []
            func element(_ field: Field) -> String { message.fullName + "." + field.name }
            var oneofDefaults: [(oneof: String, field: Field)] = []
            for field in message.fields {
                if let problem = keyFieldProblem(of: field) {
                    out.append(.invalidKeyPlacement(file: file, element: element(field), key: field.keyName ?? "", detail: problem))
                }
                if let problem = field.defaultProblem {
                    out.append(.invalidDefaultPlacement(file: file, element: element(field), spelling: field.defaultSpelling, literal: nil, detail: problem))
                }
                if let literal = field.defaultLiteral, let problem = Self.defaultPlacementProblem(field) {
                    out.append(.invalidDefaultPlacement(file: file, element: element(field), spelling: field.defaultSpelling, literal: literal, detail: problem))
                }
                if field.required && field.defaultLiteral != nil {
                    if field.requiredFromCarrier || field.defaultFromCarrier {
                        out.append(.invalidRequiredPlacement(file: file, element: element(field), spelling: field.requiredSpelling,
                            detail: "\(field.requiredSpelling) and \(field.defaultSpelling) are exclusive on one field: the first rejects a document where the field is absent, and the second treats it as supplied"))
                    } else {
                        out.append(.requiredWithDefault(file: file, element: element(field)))
                    }
                }
                if let oneof = field.oneof {
                    if field.required {
                        out.append(.invalidRequiredPlacement(file: file, element: element(field), spelling: field.requiredSpelling,
                            detail: "\(field.requiredSpelling) is not valid on a member of oneof \"\(oneof)\": read per field it demands that one arm always be chosen, which makes every other arm undecodable"))
                    }
                    if field.defaultLiteral != nil { oneofDefaults.append((oneof, field)) }
                }
            }
            for (oneof, field) in oneofDefaults {
                let members = oneofDefaults.filter { $0.oneof == oneof }.map(\.field)
                guard members.count > 1 else { continue }
                let names = members.map(\.name).joined(separator: ", ")
                out.append(.invalidDefaultPlacement(file: file, element: element(field), spelling: field.defaultSpelling, literal: field.defaultLiteral,
                    detail: "at most one member of oneof \"\(oneof)\" may carry a default; \(members.count) do (\(names))"))
            }
            return out
        }

        /// Why one literal can't denote `field`, or nil when it can. A literal
        /// that doesn't parse as the field's type stays a decode-time error,
        /// as in the reference: placement is decidable from the descriptor.
        private static func defaultPlacementProblem(_ field: Field) -> String? {
            let name = field.defaultSpelling
            if field.isMap { return "\(name) is not valid on map fields: one literal cannot denote a map" }
            if field.isRepeated { return "\(name) is not valid on repeated fields: one literal cannot denote a list" }
            if field.type == .group { return "\(name) is not valid on group fields" }
            if field.type == .message, !WellKnown.defaultable(field.typeName ?? "") {
                return "\(name) is not valid on message type \(field.typeName ?? ""): no PXF literal denotes it"
            }
            return nil
        }

        private mutating func index(_ m: Google_Protobuf_DescriptorProto, prefix: String, file: Google_Protobuf_FileDescriptorProto) {
            let fullName = prefix + m.name
            // A descriptor can be untrusted input, so a repeated name is the
            // schema's error to report. The first declaration stays indexed.
            guard messages[fullName] == nil else {
                violations[file.name, default: []].append(.duplicateName(file: file.name, name: fullName))
                return
            }
            messageFiles[fullName] = file.name
            // Claimed now, so a nested type repeating the name is seen as a repeat.
            messages[fullName] = Message(fullName: fullName, fields: [])
            for e in m.enumType { indexEnum(e, prefix: fullName + ".") }
            let nested = Dictionary(m.nestedType.map { (fullName + "." + $0.name, $0) }) { first, _ in first }
            var fields: [Field] = []
            for fd in m.field {
                var field = Self.field(fd, in: m, file: file)
                let mapEntry = fd.type == .message ? field.typeName.flatMap { nested[$0] } : nil
                if let mapEntry, mapEntry.options.mapEntry {
                    field.isMap = true
                    field.isPacked = false
                    field.mapEntryFields = mapEntry.field.map { Self.field($0, in: mapEntry, file: file) }
                    let value = mapEntry.field.first { $0.number == 2 }
                    field.mapValueMessage = value?.type == .message ? value?.typeName.drop { $0 == "." }.description : nil
                }
                fields.append(field)
            }
            messages[fullName] = Message(fullName: fullName, fields: fields)
            for n in m.nestedType { index(n, prefix: fullName + ".", file: file) }
        }

        private mutating func indexEnum(_ e: Google_Protobuf_EnumDescriptorProto, prefix: String) {
            enums[prefix + e.name] = Dictionary(e.value.map { ($0.name, $0.number) }) { first, _ in first }
        }

        private static func field(_ fd: Google_Protobuf_FieldDescriptorProto, in m: Google_Protobuf_DescriptorProto,
                                  file: Google_Protobuf_FileDescriptorProto) -> Field {
            let typeName = fd.typeName.hasPrefix(".") ? String(fd.typeName.dropFirst()) : (fd.typeName.isEmpty ? nil : fd.typeName)
            let isRepeated = fd.label == .repeated
            let inRealOneof = fd.hasOneofIndex && !fd.proto3Optional
            let oneofIndex = Int(fd.oneofIndex)
            let features = (fd.options.hasFeatures ? fd.options.features : nil)
            let fileFeatures = file.options.hasFeatures ? file.options.features : nil

            let presence: Google_Protobuf_FeatureSet.FieldPresence
            if file.syntax == "editions" {
                if let f = features, f.hasFieldPresence { presence = f.fieldPresence }
                else if let f = fileFeatures, f.hasFieldPresence { presence = f.fieldPresence }
                else { presence = .explicit }
            } else if file.syntax == "proto3" {
                presence = .implicit
            } else {
                presence = .explicit
            }
            let hasPresence = !isRepeated && (fd.type == .message || fd.type == .group || fd.hasOneofIndex
                                              || presence != .implicit)

            var isPacked = false
            if isRepeated, fd.type != .string, fd.type != .bytes, fd.type != .message, fd.type != .group {
                if fd.options.hasPacked {
                    isPacked = fd.options.packed
                } else if file.syntax == "proto3" {
                    isPacked = true
                } else if file.syntax == "editions" {
                    let encoding = features.flatMap { $0.hasRepeatedFieldEncoding ? $0.repeatedFieldEncoding : nil }
                        ?? fileFeatures.flatMap { $0.hasRepeatedFieldEncoding ? $0.repeatedFieldEncoding : nil }
                        ?? .packed
                    isPacked = encoding == .packed
                }
            }

            let annotated = FieldAnnotations.read(fd)
            return Field(
                name: fd.name,
                number: fd.number,
                type: fd.type,
                typeName: typeName,
                isRepeated: isRepeated,
                isMap: false,
                required: annotated.required,
                defaultLiteral: annotated.defaultLiteral,
                keyName: annotated.keyName,
                mapValueMessage: nil,
                oneof: inRealOneof && oneofIndex < m.oneofDecl.count ? m.oneofDecl[oneofIndex].name : nil,
                hasPresence: hasPresence,
                isRequiredLabel: fd.label == .required || presence == .legacyRequired,
                isPacked: isPacked,
                requiredFromCarrier: annotated.requiredFromCarrier,
                defaultFromCarrier: annotated.defaultFromCarrier,
                defaultProblem: annotated.defaultProblem)
        }

        /// The name enum `name` gives `number`, the first when two share it.
        func enumName(_ name: String?, number: Int32) -> String? {
            name.flatMap { enums[$0] }?.filter { $0.value == number }.keys.sorted().first
        }

        /// The value of enum `name` called `value`.
        func enumNumber(_ name: String?, value: String) -> Int32? {
            name.flatMap { enums[$0]?[value] }
        }

        /// The message named `fullName`, or nil when the descriptor set does
        /// not declare it.
        public func message(_ fullName: String) -> Message? {
            messages[fullName]
        }

        /// All indexed message names, sorted.
        public var messageNames: [String] { messages.keys.sorted() }

        // MARK: - bind-time checks

        /// Rejects a schema the draft refuses, anywhere in the import closure
        /// of the file declaring `fullName`, not just in that file: a decoder
        /// recurses into imported types, and the schema must fail whether or
        /// not a document reaches them (draft -01, "Scope of Bind-Time
        /// Checks"). A file outside the closure is not this message's schema
        /// and is not reported, and an import the descriptor set does not
        /// contain cannot be checked.
        public func validateSchema(message fullName: String) throws {
            try throwFirst(inClosureOf: fullName) { _ in true }
        }

        /// `validateSchema(message:)`, for `(pxf.required)` with `(pxf.default)`
        /// on one field. `(pxf.required) = false` requires nothing and is not
        /// a conflict.
        public func validateRequiredDefault(message fullName: String) throws {
            try throwFirst(inClosureOf: fullName) {
                if case .requiredWithDefault = $0 { return true }
                return false
            }
        }

        /// `validateSchema(message:)`, for a misplaced `(pxf.key)`.
        public func validateKeyPlacement(message fullName: String) throws {
            try throwFirst(inClosureOf: fullName) {
                if case .invalidKeyPlacement = $0 { return true }
                return false
            }
        }

        private func throwFirst(inClosureOf fullName: String, where matches: (AnnotationError) -> Bool) throws {
            guard !violations.isEmpty, let root = messageFiles[fullName] else { return }
            var visited: Set<String> = []
            var pending = [root]
            while let file = pending.popLast() {
                guard visited.insert(file).inserted else { continue }
                if let first = violations[file]?.first(where: matches) { throw first }
                pending += imports[file] ?? []
            }
        }

        // MARK: - required

        /// Rejects the first `(pxf.required)` field of `message` that has no
        /// entry in `entries`, then recurses into present, non-null singular
        /// message fields. `PXFDecoder` no longer uses this: its schema-bound
        /// pass also covers list elements, map values and `Any` bodies.
        public func validateRequired(entries: [Entry], message fullName: String, path: String = "") throws {
            guard let message = messages[fullName] else { return }
            for field in message.fields {
                let entry = Annotations.entry(named: field.name, in: entries)
                let fieldPath = path + field.name
                if entry == nil {
                    if field.required {
                        throw AnnotationError.requiredFieldAbsent(path: fieldPath)
                    }
                    continue
                }
                guard field.type == .message, !field.isRepeated, !field.isMap, let sub = field.typeName else { continue }
                if let block = entry as? Block {
                    try validateRequired(entries: block.entries, message: sub, path: fieldPath + ".")
                } else if let a = entry as? Assignment, let bv = a.value as? BlockVal {
                    try validateRequired(entries: bv.entries, message: sub, path: fieldPath + ".")
                }
                // `field = null` is present (so satisfies `required`) and is
                // not descended into.
            }
        }

        static func entry(named name: String, in entries: [Entry]) -> Entry? {
            entries.first {
                if let a = $0 as? Assignment { return a.key == name }
                if let b = $0 as? Block { return b.name == name }
                if let m = $0 as? MapEntry { return m.key == name }
                return false
            }
        }

        // MARK: - default

        /// The value an absent `field` takes, or nil when it declares no
        /// default. The literal is read by the field's proto type the way
        /// the Go reference's `applyDefaultImpl` reads it: a `string` takes
        /// the literal verbatim, `bytes` decodes it as base64, `bool` accepts
        /// exactly `true` / `false`, numbers must parse in their width, an
        /// enum names a value, and a message is one of the types with a
        /// literal form.
        public func defaultValue(for field: Field) throws -> Value? {
            guard let literal = field.defaultLiteral else { return nil }
            return try defaultValue(literal, type: field.type, typeName: field.typeName, field: field.name)
        }

        private func defaultValue(_ literal: String, type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                                  typeName: String?, field: String) throws -> Value {
            let pos = Position(line: 0, column: 0)
            func invalid(_ reason: String) -> AnnotationError {
                .invalidDefault(field: field, literal: literal, reason: reason)
            }
            switch type {
            case .string:
                return StringVal(pos: pos, value: literal)
            case .bytes:
                guard let data = PXF.decodeBase64Lenient(literal) else { throw invalid("not base64") }
                return BytesVal(pos: pos, value: data)
            case .bool:
                switch literal {
                case "true": return BoolVal(pos: pos, value: true)
                case "false": return BoolVal(pos: pos, value: false)
                default: throw invalid("not a bool")
                }
            case .int32, .sint32, .sfixed32:
                guard Int32(literal) != nil else { throw invalid("not an int32") }
                return IntVal(pos: pos, raw: literal)
            case .int64, .sint64, .sfixed64:
                guard Int64(literal) != nil else { throw invalid("not an int64") }
                return IntVal(pos: pos, raw: literal)
            case .uint32, .fixed32:
                guard UInt32(literal) != nil else { throw invalid("not a uint32") }
                return IntVal(pos: pos, raw: literal)
            case .uint64, .fixed64:
                guard UInt64(literal) != nil else { throw invalid("not a uint64") }
                return IntVal(pos: pos, raw: literal)
            case .float:
                guard Float(literal) != nil else { throw invalid("not a float") }
                return FloatVal(pos: pos, raw: literal)
            case .double:
                guard Double(literal) != nil else { throw invalid("not a double") }
                return FloatVal(pos: pos, raw: literal)
            case .enum:
                if Int32(literal) != nil { return IntVal(pos: pos, raw: literal) }
                return IdentVal(pos: pos, name: literal)
            case .message, .group:
                return try messageDefault(literal, typeName: typeName, field: field)
            }
        }

        /// The message types a single literal denotes, read as a document
        /// would write them. The bind-time check refuses every other type.
        private func messageDefault(_ literal: String, typeName: String?, field: String) throws -> Value {
            let pos = Position(line: 0, column: 0)
            func invalid(_ reason: String) -> AnnotationError {
                .invalidDefault(field: field, literal: literal, reason: reason)
            }
            let name = typeName ?? ""
            if let inner = WellKnown.wrapperKinds[name] {
                return try defaultValue(literal, type: inner, typeName: nil, field: field)
            }
            switch name {
            case WellKnown.timestamp:
                guard let (seconds, nanos) = WellKnown.parseTimestamp(literal) else { throw invalid("not a timestamp") }
                return TimestampVal(pos: pos, value: Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9), raw: literal)
            case WellKnown.duration:
                guard let (seconds, nanos) = WellKnown.parseDuration(literal) else { throw invalid("not a duration") }
                return DurationVal(pos: pos, value: Double(seconds) + Double(nanos) / 1e9, raw: literal)
            case WellKnown.bigInt:
                guard WellKnown.isDecimalLiteral(literal, fraction: false) else { throw invalid("not a big integer") }
                return IntVal(pos: pos, raw: literal)
            case WellKnown.decimal:
                guard WellKnown.isDecimalLiteral(literal, fraction: true) else { throw invalid("not a decimal") }
                return literal.contains(".") ? FloatVal(pos: pos, raw: literal) : IntVal(pos: pos, raw: literal)
            case WellKnown.bigFloat:
                let number = literal.split(separator: "p", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard Double(number) != nil else { throw invalid("not a big float") }
                return FloatVal(pos: pos, raw: literal)
            default:
                throw invalid("default values not supported for message type \(name)")
            }
        }
    }

    public enum AnnotationError: Error, CustomStringConvertible, Equatable {
        /// A `(pxf.required)` field had no entry in the input (Go: `required field "x" is absent`).
        case requiredFieldAbsent(path: String)
        /// A `(pxf.default)` literal does not read as the field's type.
        case invalidDefault(field: String, literal: String, reason: String)
        /// A field carries both `(pxf.required)` and `(pxf.default)`.
        case requiredWithDefault(file: String, element: String)
        /// A `(pxf.key)` placement the schema layer must refuse.
        case invalidKeyPlacement(file: String, element: String, key: String, detail: String)
        /// A default no single literal can denote, one that spells two values,
        /// or a second default in a oneof. `spelling` is the form the author
        /// wrote, and `literal` is nil when the default reduced to none.
        case invalidDefaultPlacement(file: String, element: String, spelling: String, literal: String?, detail: String)
        /// `(pxf.required)` where it can't hold, such as on a oneof member.
        case invalidRequiredPlacement(file: String, element: String, spelling: String, detail: String)
        /// Two messages with one fully qualified name.
        case duplicateName(file: String, name: String)

        public var description: String {
            switch self {
            case .requiredFieldAbsent(let path):
                return "required field \"\(path)\" is absent"
            case .invalidDefault(let field, let literal, let reason):
                return "invalid default \"\(literal)\" for field \"\(field)\": \(reason)"
            case .requiredWithDefault(let file, let element):
                return "\(file): field \"\(element)\": (pxf.required) and (pxf.default) are exclusive on one field: "
                    + "the first rejects a document where the field is absent, and the second treats it as supplied "
                    + "(draft -01, \"Required and Default\")"
            case .invalidKeyPlacement(let file, let element, let key, let detail):
                return "\(file): field \"\(element)\": invalid (pxf.key) = \"\(key)\": \(detail) (draft -01 §3.13)"
            case .invalidDefaultPlacement(let file, let element, let spelling, let literal, let detail):
                let shown = literal.map { "\(spelling) = \"\($0)\"" } ?? spelling
                return "\(file): field \"\(element)\": invalid \(shown): \(detail) (draft -01 §annotation-extensions)"
            case .invalidRequiredPlacement(let file, let element, let spelling, let detail):
                return "\(file): field \"\(element)\": invalid \(spelling): \(detail) (draft -01 §annotation-extensions)"
            case .duplicateName(let file, let name):
                return "\(file): message \"\(name)\" is declared twice"
            }
        }
    }
}
