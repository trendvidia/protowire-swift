// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

extension PXF {
    /// The schema-side half of `(pxf.required)` = 1314 and `(pxf.default)`
    /// = 1315 (protowire `proto/pxf/annotations.proto`), indexed from a
    /// descriptor set for the Codable decoder to consult.
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
    /// counts as present; validation and defaults recurse into present,
    /// non-null *singular* message fields, not into list elements or map
    /// values; a defaulted field is still reported absent by `PXF.Result`,
    /// since it was not in the input.
    ///
    /// The descriptor set must have been parsed with
    /// `Pxf_Annotations_Extensions` (or a map containing it), otherwise the
    /// options are unknown fields and nothing is annotated.
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
            /// The `(pxf.default)` literal as written in the schema.
            public var defaultLiteral: String?
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

        /// Every message declared in `descriptorSet`, including nested ones.
        public init(descriptorSet: Google_Protobuf_FileDescriptorSet) {
            self.init(files: descriptorSet.file)
        }

        public init(files: [Google_Protobuf_FileDescriptorProto]) {
            for file in files {
                let prefix = file.package.isEmpty ? "" : file.package + "."
                for m in file.messageType { index(m, prefix: prefix) }
            }
        }

        private mutating func index(_ m: Google_Protobuf_DescriptorProto, prefix: String) {
            let fullName = prefix + m.name
            let nested = Dictionary(uniqueKeysWithValues: m.nestedType.map { (fullName + "." + $0.name, $0) })
            var fields: [Field] = []
            for fd in m.field {
                let typeName = fd.typeName.hasPrefix(".") ? String(fd.typeName.dropFirst()) : (fd.typeName.isEmpty ? nil : fd.typeName)
                let isMap = fd.type == .message && typeName.flatMap { nested[$0]?.options.mapEntry } == true
                fields.append(Field(
                    name: fd.name,
                    number: fd.number,
                    type: fd.type,
                    typeName: typeName,
                    isRepeated: fd.label == .repeated,
                    isMap: isMap,
                    required: fd.options.hasPxf_required && fd.options.Pxf_required,
                    defaultLiteral: fd.options.hasPxf_default ? fd.options.Pxf_default : nil))
            }
            messages[fullName] = Message(fullName: fullName, fields: fields)
            for n in m.nestedType { index(n, prefix: fullName + ".") }
        }

        /// The message named `fullName`, or nil when the descriptor set does
        /// not declare it.
        public func message(_ fullName: String) -> Message? {
            messages[fullName]
        }

        /// All indexed message names, sorted.
        public var messageNames: [String] { messages.keys.sorted() }

        // MARK: - required

        /// Rejects the first `(pxf.required)` field of `message` that has no
        /// entry in `entries`, then recurses into present, non-null singular
        /// message fields, as the Go reference's `postDecode` does.
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
        /// `(pxf.default)`. The literal is read by the field's proto type
        /// the way the Go reference's `parseScalarDefault` reads it: a
        /// `string` takes the literal verbatim, `bytes` decodes it as
        /// base64, `bool` accepts `true` / `false`, numbers must parse in
        /// their width, an enum names a value, and a message default is a
        /// PXF block.
        public func defaultValue(for field: Field) throws -> Value? {
            guard let literal = field.defaultLiteral else { return nil }
            let pos = Position(line: 0, column: 0)
            func invalid(_ reason: String) -> AnnotationError {
                .invalidDefault(field: field.name, literal: literal, reason: reason)
            }
            switch field.type {
            case .string:
                return StringVal(pos: pos, value: literal)
            case .bytes:
                guard let data = Data(base64Encoded: literal) else { throw invalid("not base64") }
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
                // Parsed as a document body so the block is checked by the
                // same grammar as the input; a scalar literal here is an
                // error, as in Go's applyMessageDefault.
                let doc: Document
                do { doc = try Parser(string: "__default = " + literal).parseDocument() } catch { throw invalid("\(error)") }
                guard let a = doc.entries.first as? Assignment, let bv = a.value as? BlockVal else {
                    throw invalid("a message default must be a { ... } block")
                }
                return bv
            }
        }
    }

    public enum AnnotationError: Error, CustomStringConvertible, Equatable {
        /// A `(pxf.required)` field had no entry in the input (Go: `required field "x" is absent`).
        case requiredFieldAbsent(path: String)
        /// A `(pxf.default)` literal does not read as the field's type.
        case invalidDefault(field: String, literal: String, reason: String)

        public var description: String {
            switch self {
            case .requiredFieldAbsent(let path):
                return "required field \"\(path)\" is absent"
            case .invalidDefault(let field, let literal, let reason):
                return "invalid default \"\(literal)\" for field \"\(field)\": \(reason)"
            }
        }
    }
}
