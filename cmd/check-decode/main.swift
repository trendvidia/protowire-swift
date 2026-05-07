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
//   check-decode --format <pxf|pb|sbe|envelope>
//                --schema <fully.qualified.MessageType>
//                --proto  <path-to-adversarial.proto>
//                --input  <path>
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
// The four adversarial types are hand-mirrored as Codable structs.
// PXFDecoder's keyed container matches entries by `Key.stringValue`, while
// PBDecoder's keyed container matches by `Key.intValue` — declaring
// `enum CodingKeys: Int, CodingKey` with case names matching the proto
// field names satisfies both paths.
//
// Drift between this file and adversarial.proto must be caught by the
// conformance run itself: a wrong field name flips PXF expectations; a
// wrong field number flips PB expectations.

import Foundation
import Protowire

// MARK: - Hand-mirrored adversarial.proto types

// Tree is a class so the recursive `child` field is a reference and the
// type has finite size (Swift forbids stored-value recursion). The
// conformance corpus deliberately includes deep `child{child{...}}`
// trees; this is intentional adversarial input.
final class Tree: Codable {
    var child: Tree?
    var label: String?

    enum CodingKeys: Int, CodingKey {
        case child = 1
        case label = 2
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

// MARK: - CLI

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: check-decode --format <pxf|pb|sbe|envelope> --schema <name> [--proto <path>] --input <path>\n".utf8))
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
    default:
        FileHandle.standardError.write(Data("check-decode: unknown arg \(key)\n".utf8))
        exit(2)
    }
    i += 2
}

guard let format = format, !format.isEmpty else { usage() }
guard let schema = schema, !schema.isEmpty else { usage() }
guard let inputPath = inputPath, !inputPath.isEmpty else { usage() }

// Suppress "unused" warning under -warnings-as-errors when the only consumer
// is the pxf format; protoPath is part of the conformance contract.
_ = protoPath

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
    switch schema {
    case "adversarial.v1.Tree":         _ = try dec.decode(Tree.self, from: data)
    case "adversarial.v1.StringHolder": _ = try dec.decode(StringHolder.self, from: data)
    case "adversarial.v1.BytesHolder":  _ = try dec.decode(BytesHolder.self, from: data)
    case "adversarial.v1.BigIntHolder": _ = try dec.decode(BigIntHolder.self, from: data)
    default: throw RuntimeError("unknown schema for pb: \(schema)")
    }
}

func pxfDecode(_ data: Data, schema: String) throws {
    let dec = PXFDecoder()
    switch schema {
    case "adversarial.v1.Tree":         _ = try dec.decode(Tree.self, from: data)
    case "adversarial.v1.StringHolder": _ = try dec.decode(StringHolder.self, from: data)
    case "adversarial.v1.BytesHolder":  _ = try dec.decode(BytesHolder.self, from: data)
    case "adversarial.v1.BigIntHolder": _ = try dec.decode(BigIntHolder.self, from: data)
    default: throw RuntimeError("unknown schema for pxf: \(schema)")
    }
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
    case "pb":
        try pbDecode(inputData, schema: schema)
    case "envelope":
        throw RuntimeError("envelope decode not yet implemented in this reference")
    case "sbe":
        throw RuntimeError("sbe decode not yet implemented in this reference")
    default:
        throw RuntimeError("unsupported format: \(format)")
    }
} catch {
    reject(String(describing: error))
}

exit(0)
