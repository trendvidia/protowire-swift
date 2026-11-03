// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

// The bind-time checks that read a file's declarations rather than its
// annotations: names a document can't reach, options at retired extension
// numbers, and messages that take a well-known type's name without its shape.
// They read the descriptor protos as given, so a message the index drops as a
// duplicate is still checked. Mirrors protowire-go's encoding/pxf/schema.go,
// retired.go and wellknown.go (`wktShapes`).

extension PXF.Annotations {
    /// The violations `file` declares that `schemaViolations(of:file:)` does not
    /// look for, in the order the reference's walk appends them.
    static func declarationViolations(of file: Google_Protobuf_FileDescriptorProto) -> [PXF.AnnotationError] {
        var out: [PXF.AnnotationError] = []
        let prefix = file.package.isEmpty ? "" : file.package + "."
        walkNames(file.messageType, prefix: prefix, file: file, into: &out)
        walkEnumNames(file.enumType, prefix: prefix, file: file.name, into: &out)
        return out
    }

    // MARK: - reserved names (draft §3.13)

    /// PXF's value keywords, case-sensitive: an element with one of these
    /// names lexes as the keyword, so no document can reach it.
    static let reservedNames: Set<String> = ["null", "true", "false"]

    private static func walkNames(_ messages: [Google_Protobuf_DescriptorProto], prefix: String,
                                  file: Google_Protobuf_FileDescriptorProto, into out: inout [PXF.AnnotationError]) {
        for m in messages {
            let fullName = prefix + m.name
            if let detail = wellKnownShapeProblem(fullName, m) {
                out.append(.wellKnownShape(file: file.name, element: fullName, detail: detail))
            }
            for f in m.field where reservedNames.contains(f.name) {
                out.append(.reservedName(file: file.name, kind: "message field", element: fullName + "." + f.name, name: f.name))
            }
            for (i, o) in m.oneofDecl.enumerated() where reservedNames.contains(o.name) {
                guard !isSynthetic(oneof: i, in: m, syntax: file.syntax) else { continue }
                out.append(.reservedName(file: file.name, kind: "oneof", element: fullName + "." + o.name, name: o.name))
            }
            walkNames(m.nestedType, prefix: fullName + ".", file: file, into: &out)
            walkEnumNames(m.enumType, prefix: fullName + ".", file: file.name, into: &out)
        }
    }

    /// An enum value's full name is a sibling of its enum's, as protobuf
    /// scopes it: `prefix` is the scope the enum is declared in.
    private static func walkEnumNames(_ enums: [Google_Protobuf_EnumDescriptorProto], prefix: String,
                                      file: String, into out: inout [PXF.AnnotationError]) {
        for e in enums {
            for v in e.value where reservedNames.contains(v.name) {
                out.append(.reservedName(file: file, kind: "enum value", element: prefix + v.name, name: v.name))
            }
        }
    }

    /// The oneof a proto3 `optional` field sits in alone, which no document
    /// names, as protobuf-go's `IsSynthetic` decides it.
    private static func isSynthetic(oneof index: Int, in m: Google_Protobuf_DescriptorProto, syntax: String) -> Bool {
        let members = m.field.filter { $0.hasOneofIndex && Int($0.oneofIndex) == index }
        return syntax == "proto3" && members.count == 1 && members[0].proto3Optional
    }

    // MARK: - well-known shapes (draft -01 §wkt-shapes)

    /// One field a codec reads on a well-known type.
    struct WellKnownField {
        var name: String
        var type: Google_Protobuf_FieldDescriptorProto.TypeEnum
        var repeated = false
        /// May be undeclared; when declared it must still match.
        var optional = false
    }

    /// The fields a message must declare to be treated as the well-known type
    /// its full name says it is. Field numbers are not in it, since PXF binds
    /// fields by name. protowire-go's `wktShapes`, entry for entry.
    static let wellKnownShapes: [String: [WellKnownField]] = {
        let seconds = [WellKnownField(name: "seconds", type: .int64), WellKnownField(name: "nanos", type: .int32)]
        var m: [String: [WellKnownField]] = [
            "google.protobuf.Timestamp": seconds,
            "google.protobuf.Duration": seconds,
            "google.protobuf.Any": [WellKnownField(name: "type_url", type: .string), WellKnownField(name: "value", type: .bytes)],
            "google.protobuf.FieldMask": [WellKnownField(name: "paths", type: .string, repeated: true)],
            "pxf.BigInt": [WellKnownField(name: "abs", type: .bytes), WellKnownField(name: "negative", type: .bool)],
            "pxf.Decimal": [WellKnownField(name: "unscaled", type: .bytes), WellKnownField(name: "scale", type: .int32),
                            WellKnownField(name: "negative", type: .bool)],
            "pxf.BigFloat": [WellKnownField(name: "mantissa", type: .bytes), WellKnownField(name: "exponent", type: .int32),
                             WellKnownField(name: "prec", type: .uint32), WellKnownField(name: "negative", type: .bool)],
            "pxf.Secret": [WellKnownField(name: "value", type: .string),
                           WellKnownField(name: "hint", type: .string, optional: true),
                           WellKnownField(name: "fingerprint", type: .string, optional: true)],
        ]
        for (name, type) in PXF.WellKnown.wrapperKinds { m[name] = [WellKnownField(name: "value", type: type)] }
        return m
    }()

    /// What stops `m` having the shape its full name needs, or nil when it has
    /// it or the name needs none.
    static func wellKnownShapeProblem(_ fullName: String, _ m: Google_Protobuf_DescriptorProto) -> String? {
        for want in wellKnownShapes[fullName] ?? [] {
            guard let f = m.field.first(where: { $0.name == want.name }) else {
                if want.optional { continue }
                return "it has no field \"\(want.name)\""
            }
            if f.type != want.type {
                return "field \"\(want.name)\" is \(kindName(f.type)), and must be \(kindName(want.type))"
            }
            let isMap = f.type == .message && m.nestedType.contains {
                $0.options.mapEntry && "." + fullName + "." + $0.name == f.typeName
            }
            if isMap || (f.label == .repeated) != want.repeated {
                return "field \"\(want.name)\" has the wrong cardinality"
            }
        }
        return nil
    }

    /// A field type as protobuf-go's `Kind.String` spells it.
    static func kindName(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> String {
        switch type {
        case .double: return "double"
        case .float: return "float"
        case .int64: return "int64"
        case .uint64: return "uint64"
        case .int32: return "int32"
        case .fixed64: return "fixed64"
        case .fixed32: return "fixed32"
        case .bool: return "bool"
        case .string: return "string"
        case .group: return "group"
        case .message: return "message"
        case .bytes: return "bytes"
        case .uint32: return "uint32"
        case .enum: return "enum"
        case .sfixed32: return "sfixed32"
        case .sfixed64: return "sfixed64"
        case .sint32: return "sint32"
        case .sint64: return "sint64"
        }
    }

    // MARK: - retired option numbers (STABILITY.md promise 3)

    /// What a retired option number used to be and where it went.
    struct RetiredNumber {
        var was: String
        var now: Int
        var file: String
    }

    // Before protowire v1.12.0 the family's extensions sat in the unregistered
    // 50000–59999 range; they moved to the registered block 1314–1363, and a
    // descriptor compiled before the move binds with none of its annotations
    // read. A retired number counts only on the Options kind its allocation
    // used. protowire-go's tables, entry for entry.
    static let retiredFileOptions: [Int: RetiredNumber] = [
        50100: RetiredNumber(was: "(sbe.schema_id)", now: 1319, file: "sbe/annotations.proto"),
        50101: RetiredNumber(was: "(sbe.version)", now: 1320, file: "sbe/annotations.proto"),
        50400: RetiredNumber(was: "the file_annotations carrier", now: 1327, file: "protowire/schema/v1/descriptor.proto"),
        50401: RetiredNumber(was: "the functions carrier", now: 1328, file: "protowire/schema/v1/descriptor.proto"),
        50402: RetiredNumber(was: "the annotation_decls carrier", now: 1329, file: "protowire/schema/v1/descriptor.proto"),
        50403: RetiredNumber(was: "the type_decls carrier", now: 1330, file: "protowire/schema/v1/descriptor.proto"),
        50404: RetiredNumber(was: "the source_map carrier", now: 1331, file: "protowire/schema/v1/descriptor.proto"),
    ]
    static let retiredMessageOptions: [Int: RetiredNumber] = [
        50200: RetiredNumber(was: "(sbe.template_id)", now: 1321, file: "sbe/annotations.proto"),
        50400: RetiredNumber(was: "the message_annotations carrier", now: 1327, file: "protowire/schema/v1/descriptor.proto"),
        51001: RetiredNumber(was: "a protocheck message constraint", now: 1348, file: "protocheck's annotations"),
    ]
    static let retiredFieldOptions: [Int: RetiredNumber] = [
        50000: RetiredNumber(was: "(pxf.required)", now: 1314, file: "pxf/annotations.proto"),
        50001: RetiredNumber(was: "(pxf.default)", now: 1315, file: "pxf/annotations.proto"),
        50002: RetiredNumber(was: "(pxf.key)", now: 1316, file: "pxf/annotations.proto"),
        50300: RetiredNumber(was: "(sbe.length)", now: 1322, file: "sbe/annotations.proto"),
        50301: RetiredNumber(was: "(sbe.encoding)", now: 1323, file: "sbe/annotations.proto"),
        50400: RetiredNumber(was: "the field_annotations carrier", now: 1327, file: "protowire/schema/v1/descriptor.proto"),
        51000: RetiredNumber(was: "a protocheck field constraint", now: 1347, file: "protocheck's annotations"),
    ]
    static let retiredOneofOptions: [Int: RetiredNumber] = [
        50400: RetiredNumber(was: "the oneof_annotations carrier", now: 1327, file: "protowire/schema/v1/descriptor.proto"),
        51002: RetiredNumber(was: "a protocheck oneof constraint", now: 1349, file: "protocheck's annotations"),
    ]
    /// Enum, enum value, service and method options carried only the carrier.
    static let retiredCarrierOnly: [Int: RetiredNumber] = [
        50400: RetiredNumber(was: "the *_annotations carrier", now: 1327, file: "protowire/schema/v1/descriptor.proto"),
    ]

    /// The imports that mark a file as compiled against protowire's
    /// annotations, in either era. 50000 and up is where every project that
    /// never registered its numbers puts them, so a file importing none of
    /// these is a third party's business.
    static let protowireAnnotationFiles: Set<String> = [
        "pxf/annotations.proto",
        "sbe/annotations.proto",
        "protowire/schema/v1/annotations.proto",
        "protowire/schema/v1/descriptor.proto",
    ]

    /// A violation for every retired option number `file`'s elements carry, in
    /// the reference's walk order. Only unknown bytes are read: nothing
    /// declares the retired numbers any more, so that is where they land.
    static func retiredViolations(of file: Google_Protobuf_FileDescriptorProto) -> [PXF.AnnotationError] {
        guard file.dependency.contains(where: protowireAnnotationFiles.contains) else { return [] }
        var out: [PXF.AnnotationError] = []
        func scan(_ element: String, _ kind: String, _ unknown: SwiftProtobuf.UnknownStorage, _ table: [Int: RetiredNumber]) {
            for number in optionNumbers(unknown.data) {
                guard let r = table[number] else { continue }
                out.append(.retiredNumber(file: file.name, element: element, number: number,
                    detail: "option number \(number) on \(kind) was \(r.was) before protowire v1.12.0 and is \(r.now) now; "
                        + "the descriptor predates the registered extension block and must be recompiled against the current \(r.file)"))
            }
        }
        func enums(_ es: [Google_Protobuf_EnumDescriptorProto], prefix: String) {
            for e in es {
                scan(prefix + e.name, "EnumOptions", e.options.unknownFields, retiredCarrierOnly)
                for v in e.value {
                    scan(prefix + v.name, "EnumValueOptions", v.options.unknownFields, retiredCarrierOnly)
                }
            }
        }
        func messages(_ ms: [Google_Protobuf_DescriptorProto], prefix: String) {
            for m in ms {
                let fullName = prefix + m.name
                scan(fullName, "MessageOptions", m.options.unknownFields, retiredMessageOptions)
                for f in m.field {
                    scan(fullName + "." + f.name, "FieldOptions", f.options.unknownFields, retiredFieldOptions)
                }
                for o in m.oneofDecl {
                    scan(fullName + "." + o.name, "OneofOptions", o.options.unknownFields, retiredOneofOptions)
                }
                enums(m.enumType, prefix: fullName + ".")
                messages(m.nestedType, prefix: fullName + ".")
            }
        }
        let prefix = file.package.isEmpty ? "" : file.package + "."
        scan(file.name, "FileOptions", file.options.unknownFields, retiredFileOptions)
        messages(file.messageType, prefix: prefix)
        enums(file.enumType, prefix: prefix)
        for s in file.service {
            let service = prefix + s.name
            scan(service, "ServiceOptions", s.options.unknownFields, retiredCarrierOnly)
            for method in s.method {
                scan(service + "." + method.name, "MethodOptions", method.options.unknownFields, retiredCarrierOnly)
            }
        }
        return out
    }

    /// The numbers of the top-level fields in `data`, up to the first that is
    /// malformed. A field counts once its whole value is read, groups
    /// included, as protobuf-go's `ConsumeTag` and `ConsumeFieldValue` read it.
    static func optionNumbers(_ data: Data) -> [Int] {
        let b = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0
            for k in 0..<10 {
                guard i < b.count else { return nil }
                let c = b[i]
                i += 1
                if k == 9, c > 1 { return nil }
                v |= UInt64(c & 0x7F) << (7 * UInt64(k))
                if c & 0x80 == 0 { return v }
            }
            return nil
        }
        func tag() -> (number: Int, type: UInt64)? {
            guard let v = varint(), v >> 3 >= 1, v >> 3 <= UInt64(Int32.max) else { return nil }
            return (Int(v >> 3), v & 7)
        }
        func skip(_ n: UInt64) -> Bool {
            guard n <= UInt64(b.count - i) else { return false }
            i += Int(n)
            return true
        }
        // protowire.DefaultRecursionLimit: how deep groups may nest.
        let groupLimit = 10_000
        func value(_ number: Int, _ type: UInt64) -> Bool {
            var (number, type) = (number, type)
            var open: [Int] = []
            while true {
                switch type {
                case 0: guard varint() != nil else { return false }
                case 1: guard skip(8) else { return false }
                case 2: guard let n = varint(), skip(n) else { return false }
                case 3:
                    guard open.count < groupLimit else { return false }
                    open.append(number)
                case 5: guard skip(4) else { return false }
                default: return false // an end group outside one, or a reserved type
                }
                var next: (number: Int, type: UInt64)?
                while next == nil, let top = open.last {
                    guard let t = tag() else { return false }
                    if t.type == 4 {
                        guard t.number == top else { return false }
                        open.removeLast()
                    } else {
                        next = t
                    }
                }
                guard let next else { return true }
                (number, type) = next
            }
        }
        var out: [Int] = []
        while i < b.count {
            guard let t = tag(), value(t.number, t.type) else { break }
            out.append(t.number)
        }
        return out
    }
}
