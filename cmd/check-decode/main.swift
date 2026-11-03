// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
// check-decode is the Swift reference for the per-port conformance binary
// driven by the protowire HARDENING.md adversarial corpus. See:
//
//   protowire/docs/HARDENING.md
//   protowire/scripts/cross_security_check.sh
//   protowire/testdata/adversarial/README.md
//
// Contract:
//
//   check-decode --format <pxf|pxf-pb|pb|pb-render|sbe|envelope>
//                --schema <fully.qualified.MessageType>
//                --proto  <path-to-adversarial.proto>
//                --input  <path>
//                [--limit NAME=VALUE]...
//
//   pxf-pb decodes the document against --schema and writes the message's PB
//   bytes on stdout, map entries in key order, for the write gate
//   (protowire/scripts/cross_write_check.sh). Like the Java, Rust and C++
//   ports, it reads the descriptor set beside --proto (`<stem>.binpb`, built
//   with its imports), since nothing here compiles `.proto` text.
//
//   --limit sets one HARDENING limit for this run, so the corpus can prove a
//   64 MiB cap with a small fixture.
//
//   Exit 0 → input was accepted (decode succeeded)
//   Exit 1 → input was rejected (decode threw a Swift Error; "reject: ..."
//                                is printed to stderr first)
//   Other  → bug in the decoder (precondition trap, force-unwrap of nil,
//                                stack overflow from unbounded recursion,
//                                Int(_:) overflow trap, ...). The
//                                conformance corpus exists to surface these
//                                as FAIL_CRASH verdicts so they can be
//                                fixed in protowire-swift.
//
// The adversarial types are hand-mirrored as Codable structs, and
// BigNumHolder as a Decodable one over the library's big-number messages.
// PXFDecoder's keyed container matches entries by `Key.stringValue`, while
// PBDecoder's keyed container matches by `Key.intValue` — declaring
// `enum CodingKeys: Int, CodingKey` with case names matching the proto
// field names satisfies both paths.
//
// Drift between this file and adversarial.proto must be caught by the
// conformance run itself: a wrong field name flips PXF expectations; a
// wrong field number flips PB expectations.

import Foundation
@_spi(Conformance) import Protowire
import SwiftProtobuf

// MARK: - Hand-mirrored adversarial.proto types

// Tree is a class so the recursive `child` field is a reference and the
// type has finite size (Swift forbids stored-value recursion). The
// conformance corpus deliberately includes deep `child{child{...}}`
// trees; this is intentional adversarial input.
final class Tree: Codable {
    var child: Tree?
    var label: String?
    var children: [Tree]?
    var branches: [String: Tree]?
    var tags: [String: String]?

    enum CodingKeys: Int, CodingKey {
        case child = 1
        case label = 2
        case children = 3
        case branches = 4
        case tags = 5
    }
}

struct StringHolder: Codable {
    var value: String?

    enum CodingKeys: Int, CodingKey {
        case value = 1
    }
}

struct BytesHolder: Codable {
    var value: Data?

    enum CodingKeys: Int, CodingKey {
        case value = 1
    }
}

struct BigIntHolder: Codable {
    var value: Int64?

    enum CodingKeys: Int, CodingKey {
        case value = 1
    }
}

struct ListHolder: Codable {
    var values: [Int32]?

    enum CodingKeys: Int, CodingKey {
        case values = 1
    }
}

// The arbitrary-precision carriers, so the digit cap is proved on a field
// only the cap can reject (protowire#279). Case names are the proto's.
struct BigNumHolder: Codable {
    var big_int: Pxf_BigInt?
    var decimal: Pxf_Decimal?
    var big_float: Pxf_BigFloat?

    enum CodingKeys: Int, CodingKey {
        case big_int = 1
        case decimal = 2
        case big_float = 3
    }
}

// MARK: - CLI

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: check-decode --format <pxf|pxf-pb|pb|pb-render|sbe|envelope> --schema <name> [--proto <path>] --input <path> [--limit NAME=VALUE]...\n".utf8))
    exit(2)
}

func reject(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("reject: \(msg)\n".utf8))
    exit(1)
}

var format: String?
var schema: String?
var protoPath: String?
var inputPath: String?
var limits = Hardening.Limits()

/// Applies one `--limit NAME=VALUE`. A bad one is the harness's fault: exit 2.
func setLimit(_ spec: String?) {
    let parts = (spec ?? "").split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2, let value = Int(parts[1]), value > 0 else {
        FileHandle.standardError.write(Data("check-decode: --limit wants NAME=VALUE, got \(spec ?? "nothing")\n".utf8))
        exit(2)
    }
    switch parts[0] {
    case "MaxMessageSize":          limits.maxMessageSize = value
    case "MaxNestingDepth":         limits.maxNestingDepth = value
    case "MaxNumericLiteralDigits": limits.maxNumericLiteralDigits = value
    case "MaxBytesLiteralLength":   limits.maxBytesLiteralLength = value
    case "MaxRepeatedCount":        limits.maxRepeatedCount = value
    case "MaxBigFloatExponent":     limits.maxBigFloatExponent = value
    default:
        FileHandle.standardError.write(Data("check-decode: unknown limit \(parts[0])\n".utf8))
        exit(2)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let key = args[i]
    let val: String? = (i + 1 < args.count) ? args[i + 1] : nil
    switch key {
    case "--format": format = val
    case "--schema": schema = val
    case "--proto":  protoPath = val
    case "--input":  inputPath = val
    case "--limit":  setLimit(val)
    default:
        FileHandle.standardError.write(Data("check-decode: unknown arg \(key)\n".utf8))
        exit(2)
    }
    i += 2
}

guard let format = format, !format.isEmpty else { usage() }
guard let schema = schema, !schema.isEmpty else { usage() }
guard let inputPath = inputPath, !inputPath.isEmpty else { usage() }

let inputURL = URL(fileURLWithPath: inputPath)
let inputData: Data
do {
    inputData = try Data(contentsOf: inputURL)
} catch {
    reject("read input: \(error)")
}

// MARK: - Format dispatchers

func pbDecode(_ data: Data, schema: String) throws {
    let dec = PBDecoder()
    dec.limits = limits
    switch schema {
    case "adversarial.v1.Tree":         _ = try dec.decode(Tree.self, from: data)
    case "adversarial.v1.StringHolder": _ = try dec.decode(StringHolder.self, from: data)
    case "adversarial.v1.BytesHolder":  _ = try dec.decode(BytesHolder.self, from: data)
    case "adversarial.v1.BigIntHolder": _ = try dec.decode(BigIntHolder.self, from: data)
    case "adversarial.v1.ListHolder":   _ = try dec.decode(ListHolder.self, from: data)
    case "adversarial.v1.BigNumHolder": _ = try dec.decode(BigNumHolder.self, from: data)
    default: throw RuntimeError("unknown schema for pb: \(schema)")
    }
}

func pxfDecode(_ data: Data, schema: String) throws {
    let dec = PXFDecoder()
    dec.limits = limits
    switch schema {
    case "adversarial.v1.Tree":         _ = try dec.decode(Tree.self, from: data)
    case "adversarial.v1.StringHolder": _ = try dec.decode(StringHolder.self, from: data)
    case "adversarial.v1.BytesHolder":  _ = try dec.decode(BytesHolder.self, from: data)
    case "adversarial.v1.BigIntHolder": _ = try dec.decode(BigIntHolder.self, from: data)
    case "adversarial.v1.ListHolder":   _ = try dec.decode(ListHolder.self, from: data)
    case "adversarial.v1.BigNumHolder": _ = try dec.decode(BigNumHolder.self, from: data)
    default: throw RuntimeError("unknown schema for pxf: \(schema)")
    }
}

/// Reads the PB bytes, then writes them as PXF: the producer's side of the
/// bounds. The decoder stores a big number's fields and checks nothing, so
/// writing them is what is tested. A deep Tree is the producer's depth check
/// (HARDENING.md § Recursion): the reader here allows twice the run's
/// MaxNestingDepth, so a message one past the limit reaches the producer and
/// the reject comes from it, not from the read. The producer keeps the run's
/// limit.
func pbRender(_ data: Data, schema: String) throws {
    let dec = PBDecoder()
    dec.limits = limits
    dec.limits.maxNestingDepth = 2 * limits.maxNestingDepth
    let enc = PXFEncoder()
    enc.limits = limits
    switch schema {
    case "adversarial.v1.Tree":         _ = try enc.encode(dec.decode(Tree.self, from: data))
    case "adversarial.v1.BigNumHolder": _ = try enc.encode(dec.decode(BigNumHolder.self, from: data))
    default: throw RuntimeError("unknown schema for pb-render: \(schema)")
    }
}

/// The SBE messages of adversarial.proto, laid out as its comments say. This
/// harness has no proto compiler, so the templates are written here.
func sbeDecode(_ data: Data, schema: String) throws {
    let template: SBE.MessageTemplate
    switch schema {
    case "adversarial.v1.SbeWithGroup":
        template = SBE.MessageTemplate(
            templateID: 9001, schemaID: 9001, version: 0, blockLength: 4,
            fields: [SBE.FieldTemplate(name: "root_value", offset: 0, size: 4, encoding: .uint32)],
            groups: [SBE.GroupTemplate(name: "entries", blockLength: 4,
                                       fields: [SBE.FieldTemplate(name: "entry_value", offset: 0, size: 4, encoding: .uint32)])])
    case "adversarial.v1.SbeText":
        // string text = 1 [(sbe.length) = 8]; bytes raw = 2 [(sbe.length) = 8].
        template = SBE.MessageTemplate(
            templateID: 9002, schemaID: 9001, version: 0, blockLength: 16,
            fields: [SBE.FieldTemplate(name: "text", offset: 0, size: 8, encoding: .char),
                     SBE.FieldTemplate(name: "raw", offset: 8, size: 8, encoding: .char, isBytes: true)])
    default:
        throw RuntimeError("unknown schema for sbe: \(schema)")
    }
    let dec = SBEUnmarshaller()
    dec.limits = limits
    _ = try dec.unmarshal(data, template: template)
}

/// A fault of the harness or its arguments, not a verdict on the input: exit 2,
/// so a missing descriptor can't pass for a rejected document.
func harnessFault(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("check-decode: \(msg)\n".utf8))
    exit(2)
}

/// The schema `--proto` names, read from the descriptor set beside it.
func loadAnnotations(protoPath: String?) -> PXF.Annotations {
    guard let protoPath, !protoPath.isEmpty else { harnessFault("--proto is required for this format") }
    let setURL = URL(fileURLWithPath: protoPath).deletingPathExtension().appendingPathExtension("binpb")
    do {
        let data = try Data(contentsOf: setURL)
        let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data, extensions: Pxf_Annotations_Extensions)
        return PXF.Annotations(descriptorSet: set)
    } catch {
        harnessFault("read descriptor set \(setURL.path): \(error)")
    }
}

/// pxf-pb: the schema-bound decode, then its bytes. Whatever the decode
/// refuses is a reject; the bytes are written only once it has accepted.
func pxfPB(_ data: Data, schema: String) throws -> Data {
    let annotations = loadAnnotations(protoPath: protoPath)
    guard annotations.message(schema) != nil else { harnessFault("no message \(schema) in the descriptor set") }
    struct Anything: Decodable { init(from decoder: Decoder) throws {} }
    let dec = PXFDecoder(annotations: annotations, rootMessage: schema)
    dec.limits = limits
    _ = try dec.decode(Anything.self, from: data)
    guard let bytes = dec.lastBoundBytes else { harnessFault("the decode accepted but bound nothing") }
    return bytes
}

struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

do {
    switch format {
    case "pxf":
        try pxfDecode(inputData, schema: schema)
    case "pxf-pb":
        FileHandle.standardOutput.write(try pxfPB(inputData, schema: schema))
    case "pb":
        try pbDecode(inputData, schema: schema)
    case "pb-render":
        try pbRender(inputData, schema: schema)
    case "envelope":
        throw RuntimeError("envelope decode not yet implemented in this reference")
    case "sbe":
        try sbeDecode(inputData, schema: schema)
    default:
        throw RuntimeError("unsupported format: \(format)")
    }
} catch {
    reject(String(describing: error))
}

exit(0)
