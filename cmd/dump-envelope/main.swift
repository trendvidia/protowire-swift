// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
// Cross-port wire-compatibility dumper, driven by protowire's
// scripts/cross_envelope_check.sh. Every port carries the same program and
// the script compares their output byte for byte. Mirrors
// protowire-go/scripts/dump_envelope.
//
//   dump-envelope                        canonical Envelope → pb hex
//   dump-envelope --sbe FDS MESSAGE DOC  PXF DOC decoded against MESSAGE in FDS → SBE hex
//   dump-envelope --pb  FDS MESSAGE DOC  not implemented here (exit 3): the PXF
//                                        decoder is a Codable bridge and reads
//                                        no (pxf.*) annotation (issue #11)
//
// --sbe is how the gate proves this port reads (sbe.schema_id) = 1319,
// (sbe.version) = 1320, (sbe.template_id) = 1321, (sbe.length) = 1322 and
// (sbe.encoding) = 1323 from a descriptor it did not compile itself
// (STABILITY.md promise 3, protowire#244): the template comes from
// `SBE.templates(from:)` over the descriptor set, and a port looking for the
// wrong number builds a different layout or refuses the file. The PXF side
// of this port decodes into Codable types rather than descriptor-bound
// messages, so this program turns the parsed document into the
// `[String: Any]` the marshaller takes, typed by the template it is about to
// write with; enum identifiers resolve through the descriptor set.
//
// Exit 0 with hex on stdout; 1 with "reject: <reason>" on stderr when the
// document cannot be decoded against the message; 2 for anything that is
// the harness's fault; 3 with "not-implemented: <reason>" for a leg this
// port does not have.

import Foundation
import Protowire
import SwiftProtobuf

func fatal(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write(Data("dump-envelope: \(msg)\n".utf8))
    exit(code)
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func dumpEnvelope() throws {
    var ae = AppError(code: "INSUFFICIENT_FUNDS",
                      message: "balance too low",
                      args: ["$3.50", "$10.00"])
    ae.withField(field: "amount", code: "MIN_VALUE", message: "below minimum", args: "10.00")
    ae.withMeta(key: "request_id", value: "req-123")

    let env = Envelope(status: 402,
                       data: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                       error: ae)

    print(hex(try PBEncoder().encode(env)))
}

/// Enum value names for every enum in a file, keyed by fully-qualified
/// enum name — what `IdentVal` resolves against.
func enumValues(in file: Google_Protobuf_FileDescriptorProto) -> [String: [String: Int32]] {
    var out: [String: [String: Int32]] = [:]
    func add(_ e: Google_Protobuf_EnumDescriptorProto, prefix: String) {
        out[prefix + e.name] = Dictionary(uniqueKeysWithValues: e.value.map { ($0.name, $0.number) })
    }
    func walk(_ m: Google_Protobuf_DescriptorProto, prefix: String) {
        for e in m.enumType { add(e, prefix: prefix + m.name + ".") }
        for n in m.nestedType { walk(n, prefix: prefix + m.name + ".") }
    }
    let prefix = file.package.isEmpty ? "" : file.package + "."
    for e in file.enumType { add(e, prefix: prefix) }
    for m in file.messageType { walk(m, prefix: prefix) }
    return out
}

/// Field name → enum type name, for a message and (recursively) its nested
/// message-typed fields, keyed by "Message.field" paths relative to the root.
func enumFields(of message: Google_Protobuf_DescriptorProto, in file: Google_Protobuf_FileDescriptorProto) -> [String: String] {
    var byName: [String: Google_Protobuf_DescriptorProto] = [:]
    func index(_ m: Google_Protobuf_DescriptorProto, prefix: String) {
        byName[prefix + m.name] = m
        for n in m.nestedType { index(n, prefix: prefix + m.name + ".") }
    }
    let prefix = file.package.isEmpty ? "" : file.package + "."
    for m in file.messageType { index(m, prefix: prefix) }

    var out: [String: String] = [:]
    func walk(_ m: Google_Protobuf_DescriptorProto, path: String) {
        for f in m.field {
            let key = path.isEmpty ? f.name : path + "." + f.name
            if f.type == .enum { out[key] = String(f.typeName.dropFirst()) }
            if f.type == .message, let sub = byName[String(f.typeName.dropFirst())] { walk(sub, path: key) }
        }
    }
    walk(message, path: "")
    return out
}

struct Reject: Error { let message: String }

/// Converts a parsed PXF document into the `[String: Any]` the marshaller
/// takes, typed by the template's encodings.
struct DocumentConverter {
    let enums: [String: [String: Int32]]
    let enumFields: [String: String]

    func convert(_ entries: [PXF.Entry], fields: [SBE.FieldTemplate], groups: [SBE.GroupTemplate], path: String) throws -> [String: Any] {
        var out: [String: Any] = [:]
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
        let groupByName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
        for entry in entries {
            switch entry {
            case let a as PXF.Assignment:
                let key = path.isEmpty ? a.key : path + "." + a.key
                if let ft = byName[a.key] {
                    out[a.key] = try scalar(a.value, ft, at: key)
                } else if let gt = groupByName[a.key] {
                    guard let list = a.value as? PXF.ListVal else { throw Reject(message: "\(key): repeated field must use list syntax") }
                    out[a.key] = try list.elements.map { v -> [String: Any] in
                        guard let b = v as? PXF.BlockVal else { throw Reject(message: "\(key): group entries must be blocks") }
                        return try convert(b.entries, fields: gt.fields, groups: [], path: key)
                    }
                } else {
                    throw Reject(message: "unknown field \"\(a.key)\"")
                }
            case let b as PXF.Block:
                let key = path.isEmpty ? b.name : path + "." + b.name
                guard let ft = byName[b.name], let composite = ft.composite else { throw Reject(message: "unknown field \"\(b.name)\"") }
                out[b.name] = try convert(b.entries, fields: composite, groups: [], path: key)
            default:
                throw Reject(message: "unsupported entry \(type(of: entry))")
            }
        }
        return out
    }

    func scalar(_ v: PXF.Value, _ ft: SBE.FieldTemplate, at key: String) throws -> Any {
        if let composite = ft.composite {
            guard let b = v as? PXF.BlockVal else { throw Reject(message: "\(key): expected a block") }
            return try convert(b.entries, fields: composite, groups: [], path: key)
        }
        guard let enc = ft.encoding else { throw Reject(message: "\(key): field has no encoding") }
        switch enc {
        case .char:
            guard let s = v as? PXF.StringVal else { throw Reject(message: "\(key): expected a string") }
            return s.value
        case .float, .double:
            let raw = (v as? PXF.FloatVal)?.raw ?? (v as? PXF.IntVal)?.raw
            guard let raw, let d = Double(raw.replacingOccurrences(of: "_", with: "")) else { throw Reject(message: "\(key): expected a number") }
            return enc == .float ? Float(d) as Any : d as Any
        case .int8, .int16, .int32, .int64:
            guard let i = v as? PXF.IntVal, let n = Int64(i.raw.replacingOccurrences(of: "_", with: "")) else { throw Reject(message: "\(key): expected an integer") }
            return n
        case .uint8, .uint16, .uint32, .uint64:
            if let b = v as? PXF.BoolVal { return UInt64(b.value ? 1 : 0) }
            if let id = v as? PXF.IdentVal {
                guard let enumName = enumFields[key], let n = enums[enumName]?[id.name] else {
                    throw Reject(message: "\(key): unknown enum value \(id.name)")
                }
                return UInt64(n)
            }
            guard let i = v as? PXF.IntVal, let n = UInt64(i.raw.replacingOccurrences(of: "_", with: "")) else { throw Reject(message: "\(key): expected an unsigned integer") }
            return n
        }
    }
}

func dumpFixture(mode: String, fdsPath: String, message: String, docPath: String) throws {
    if mode == "--pb" {
        FileHandle.standardError.write(Data("not-implemented: the Swift PXF decoder reads no (pxf.required)/(pxf.default) annotation (protowire-swift#11)\n".utf8))
        exit(3)
    }
    let fdsData: Data
    let doc: String
    do {
        fdsData = try Data(contentsOf: URL(fileURLWithPath: fdsPath))
        doc = try String(contentsOfFile: docPath, encoding: .utf8)
    } catch { fatal(2, "\(error)") }

    let fds: Google_Protobuf_FileDescriptorSet
    do {
        fds = try Google_Protobuf_FileDescriptorSet(serializedBytes: fdsData, extensions: Sbe_Annotations_Extensions)
    } catch { fatal(2, "\(fdsPath): \(error)") }

    guard let file = fds.file.first(where: { f in
        let prefix = f.package.isEmpty ? "" : f.package + "."
        return message.hasPrefix(prefix) && f.messageType.contains { message == prefix + $0.name || message.hasPrefix(prefix + $0.name + ".") }
    }) else { fatal(2, "\(fdsPath): \(message) not found") }

    let templates: [String: SBE.MessageTemplate]
    do { templates = try SBE.templates(from: file) } catch { fatal(2, "\(error)") }
    guard let tmpl = templates[message] else { fatal(2, "\(fdsPath): \(message) carries no (sbe.template_id)") }

    let root = DescriptorIndexLookup.message(named: message, in: file)
    let converter = DocumentConverter(enums: enumValues(in: file), enumFields: root.map { enumFields(of: $0, in: file) } ?? [:])
    let values: [String: Any]
    do {
        let document = try PXF.Parser(input: Data(doc.utf8)).parseDocument()
        values = try converter.convert(document.entries, fields: tmpl.fields, groups: tmpl.groups, path: "")
    } catch let r as Reject {
        FileHandle.standardError.write(Data("reject: \(r.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("reject: \(error)\n".utf8))
        exit(1)
    }
    do { print(hex(try SBEMarshaller().marshal(values, template: tmpl))) } catch { fatal(2, "\(error)") }
}

enum DescriptorIndexLookup {
    static func message(named fullName: String, in file: Google_Protobuf_FileDescriptorProto) -> Google_Protobuf_DescriptorProto? {
        var found: Google_Protobuf_DescriptorProto?
        func walk(_ m: Google_Protobuf_DescriptorProto, prefix: String) {
            if prefix + m.name == fullName { found = m }
            for n in m.nestedType { walk(n, prefix: prefix + m.name + ".") }
        }
        let prefix = file.package.isEmpty ? "" : file.package + "."
        for m in file.messageType { walk(m, prefix: prefix) }
        return found
    }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.isEmpty {
        try dumpEnvelope()
    } else if args.count == 4, args[0] == "--pb" || args[0] == "--sbe" {
        try dumpFixture(mode: args[0], fdsPath: args[1], message: args[2], docPath: args[3])
    } else {
        fatal(2, "usage: dump-envelope [--pb|--sbe FDS MESSAGE DOC]")
    }
} catch {
    fatal(2, "\(error)")
}
