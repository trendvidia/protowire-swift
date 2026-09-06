// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
//
// Descriptor-driven SBE templates: the layout the Go reference derives from
// a proto file's `(sbe.*)` annotations (protowire-go/encoding/sbe/template.go),
// built here from a `Google_Protobuf_FileDescriptorProto` so a schema compiled
// once can drive this port's codec without hand-written templates.
//
// The descriptor must have been parsed with `Sbe_Annotations_Extensions`;
// otherwise the annotations sit in unknown fields and every file looks as if
// it had no `(sbe.schema_id)`.

import Foundation
import SwiftProtobuf

extension SBE {
    /// Why a descriptor could not be turned into templates.
    public enum DescriptorError: Error, CustomStringConvertible {
        case missingSchemaID(file: String)
        case missingTemplateID(message: String)
        case missingLength(field: String)
        case unknownEncoding(field: String, encoding: String)
        case unsupported(String)
        case unresolvedType(field: String, type: String)

        public var description: String {
            switch self {
            case .missingSchemaID(let f): return "sbe: file \(f) missing (sbe.schema_id) option"
            case .missingTemplateID(let m): return "sbe: message \(m) missing (sbe.template_id)"
            case .missingLength(let f): return "sbe: field \(f): string/bytes field requires (sbe.length) annotation"
            case .unknownEncoding(let f, let e): return "sbe: field \(f): unknown encoding \"\(e)\""
            case .unsupported(let s): return "sbe: \(s)"
            case .unresolvedType(let f, let t): return "sbe: field \(f): cannot resolve type \(t) in this file"
            }
        }
    }

    /// Builds a template for every top-level or nested message in `file`
    /// that carries `(sbe.template_id)`, keyed by fully-qualified name
    /// (`bench.v1.Order`). `(sbe.schema_id)` and `(sbe.version)` come from
    /// the file's options, `(sbe.length)` and `(sbe.encoding)` from each
    /// field's. Layout rules mirror the Go reference: fields in field-number
    /// order; bool and enum as `uint8`; string and bytes as `char[length]`;
    /// a singular message field is an inlined composite; a repeated message
    /// field is a group after the root block; repeated scalars, maps and
    /// oneofs are rejected. Message types are resolved within `file` only.
    public static func templates(from file: Google_Protobuf_FileDescriptorProto) throws -> [String: MessageTemplate] {
        guard file.options.hasSbe_schemaID else {
            throw DescriptorError.missingSchemaID(file: file.name)
        }
        let schemaID = UInt16(truncatingIfNeeded: file.options.Sbe_schemaID)
        let version = UInt16(truncatingIfNeeded: file.options.Sbe_version)

        let types = DescriptorIndex(file: file)
        var out: [String: MessageTemplate] = [:]
        for (fullName, message) in types.messages where message.options.hasSbe_templateID {
            let (fields, groups, blockLength) = try types.layout(of: message, named: fullName, allowGroups: true)
            out[fullName] = MessageTemplate(
                templateID: UInt16(truncatingIfNeeded: message.options.Sbe_templateID),
                schemaID: schemaID,
                version: version,
                blockLength: blockLength,
                fields: fields,
                groups: groups)
        }
        return out
    }
}

/// Fully-qualified name → descriptor, for every message in a file including
/// nested ones, plus the layout rules.
struct DescriptorIndex {
    var messages: [String: Google_Protobuf_DescriptorProto] = [:]

    init(file: Google_Protobuf_FileDescriptorProto) {
        let prefix = file.package.isEmpty ? "" : file.package + "."
        for m in file.messageType { index(m, prefix: prefix) }
    }

    private mutating func index(_ m: Google_Protobuf_DescriptorProto, prefix: String) {
        let name = prefix + m.name
        messages[name] = m
        for n in m.nestedType { index(n, prefix: name + ".") }
    }

    func resolve(_ typeName: String, for field: String) throws -> Google_Protobuf_DescriptorProto {
        let key = typeName.hasPrefix(".") ? String(typeName.dropFirst()) : typeName
        guard let m = messages[key] else {
            throw SBE.DescriptorError.unresolvedType(field: field, type: typeName)
        }
        return m
    }

    /// Fields (and, when `allowGroups`, groups) of `message` in SBE order.
    func layout(of message: Google_Protobuf_DescriptorProto, named fullName: String, allowGroups: Bool)
        throws -> (fields: [SBE.FieldTemplate], groups: [SBE.GroupTemplate], blockLength: Int) {
        var fields: [SBE.FieldTemplate] = []
        var groups: [SBE.GroupTemplate] = []
        var offset = 0
        for fd in message.field.sorted(by: { $0.number < $1.number }) {
            let qualified = fullName + "." + fd.name
            if fd.hasOneofIndex && !fd.proto3Optional {
                throw SBE.DescriptorError.unsupported("oneof field \(qualified) not supported")
            }
            let repeated = fd.label == .repeated
            if fd.type == .message {
                let sub = try resolve(fd.typeName, for: qualified)
                if sub.options.mapEntry {
                    throw SBE.DescriptorError.unsupported("map field \(qualified) not supported")
                }
                if repeated {
                    guard allowGroups else {
                        throw SBE.DescriptorError.unsupported("nested repeated field in group \(fullName) not supported")
                    }
                    let (gf, _, gl) = try layout(of: sub, named: String(fd.typeName.dropFirst()), allowGroups: false)
                    groups.append(SBE.GroupTemplate(name: fd.name, blockLength: gl, fields: gf))
                    continue
                }
                let (cf, _, size) = try layout(of: sub, named: String(fd.typeName.dropFirst()), allowGroups: false)
                fields.append(SBE.FieldTemplate(name: fd.name, offset: offset, size: size, composite: cf))
                offset += size
                continue
            }
            if repeated {
                throw SBE.DescriptorError.unsupported("repeated scalar field \(qualified) not supported; wrap in a message")
            }
            let (enc, size) = try encodingSize(of: fd, qualified: qualified)
            fields.append(SBE.FieldTemplate(name: fd.name, offset: offset, size: size, encoding: enc))
            offset += size
        }
        return (fields, groups, offset)
    }

    private func encodingSize(of fd: Google_Protobuf_FieldDescriptorProto, qualified: String) throws -> (SBE.Encoding, Int) {
        if fd.options.hasSbe_encoding {
            let raw = fd.options.Sbe_encoding
            guard let enc = SBE.Encoding(rawValue: raw), enc != .char else {
                throw SBE.DescriptorError.unknownEncoding(field: qualified, encoding: raw)
            }
            switch enc {
            case .int8, .uint8: return (enc, 1)
            case .int16, .uint16: return (enc, 2)
            case .int32, .uint32, .float: return (enc, 4)
            case .int64, .uint64, .double: return (enc, 8)
            case .char: return (enc, 0) // unreachable: excluded above
            }
        }
        switch fd.type {
        case .bool: return (.uint8, 1)
        case .int32, .sint32, .sfixed32: return (.int32, 4)
        case .int64, .sint64, .sfixed64: return (.int64, 8)
        case .uint32, .fixed32: return (.uint32, 4)
        case .uint64, .fixed64: return (.uint64, 8)
        case .float: return (.float, 4)
        case .double: return (.double, 8)
        case .enum: return (.uint8, 1)
        case .string, .bytes:
            guard fd.options.hasSbe_length else { throw SBE.DescriptorError.missingLength(field: qualified) }
            return (.char, Int(fd.options.Sbe_length))
        default:
            throw SBE.DescriptorError.unsupported("field \(qualified): unsupported proto type \(fd.type)")
        }
    }
}
