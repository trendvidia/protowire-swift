// Cross-port PXF microbench: Swift implementation.
//
// Reads `<testdata>/bench-test.pxf` (text payload), times unmarshal +
// marshal of `bench.v1.Config` for at least `--seconds` (default 3), and
// prints one JSON line per op:
//
//   {"port":"swift","op":"unmarshal","ns_per_op":...,"mib_per_sec":...,"iterations":...,"bytes":...}
//   {"port":"swift","op":"marshal","ns_per_op":...,"iterations":...}
//
// The other ports' bench-pxf binaries print the same shape; the spec
// repo's `scripts/cross_pxf_bench.sh` runner aggregates them.
//
// `Config` here is a hand-written Codable mirror of the canonical
// `bench.v1.Config` proto. The two PXF-typed fields the canonical
// fixture carries — `created_at` (Timestamp) and `timeout` (Duration) —
// are read-and-discarded by the decoder because the PXF Codable bridge
// doesn't yet decode those into specific Swift types. The remaining 9
// fields cover the same shape every other port times.

import Foundation
import Protowire

struct Config: Codable {
    var hostname: String
    var port: Int32
    var enabled: Bool
    var weight: Double
    var status: Status
    var tags: [String]
    var tls: TLS
    var labels: [String: String]
    var endpoints: [Endpoint]

    enum Status: String, Codable {
        case unspecified = "STATUS_UNSPECIFIED"
        case serving = "STATUS_SERVING"
    }
}

struct TLS: Codable {
    var cert_file: String
    var key_file: String
    var verify: Bool
}

struct Endpoint: Codable {
    var path: String
    var method: String
    var timeout_ms: Int32
}

var seconds: Double = 3.0
var testdataDir: String? = nil

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--seconds":
        i += 1
        guard i < args.count, let v = Double(args[i]) else {
            FileHandle.standardError.write(Data("--seconds expects a number\n".utf8))
            exit(2)
        }
        seconds = v
    case "--testdata":
        i += 1
        guard i < args.count else {
            FileHandle.standardError.write(Data("--testdata expects a path\n".utf8))
            exit(2)
        }
        testdataDir = args[i]
    default:
        FileHandle.standardError.write(Data("unknown flag: \(args[i])\n".utf8))
        exit(2)
    }
    i += 1
}

let dir = testdataDir ?? FileManager.default.currentDirectoryPath + "/testdata"
let pxfURL = URL(fileURLWithPath: dir).appendingPathComponent("bench-test.pxf")
let pxfText = try String(contentsOf: pxfURL, encoding: .utf8)
let payloadBytes = pxfText.utf8.count

// Warm-up.
_ = try PXFDecoder().decode(Config.self, from: pxfText)

func timeLoop(_ secs: Double, _ body: () throws -> Void) rethrows -> (iters: Int, elapsed: Double) {
    let start = Date()
    var iters = 0
    while true {
        for _ in 0..<64 { try body() }
        iters += 64
        if Date().timeIntervalSince(start) >= secs { break }
    }
    return (iters, Date().timeIntervalSince(start))
}

let decoder = PXFDecoder()
let (itersU, elapsedU) = try timeLoop(seconds) {
    _ = try decoder.decode(Config.self, from: pxfText)
}
let nsPerOpU = Int64(elapsedU * 1_000_000_000.0) / Int64(itersU)
let mibPerSec = Double(payloadBytes) * Double(itersU) / (1024.0 * 1024.0) / elapsedU
print(#"{"port":"swift","op":"unmarshal","ns_per_op":\#(nsPerOpU),"mib_per_sec":\#(mibPerSec),"iterations":\#(itersU),"bytes":\#(payloadBytes)}"#)

let seed = try decoder.decode(Config.self, from: pxfText)
let encoder = PXFEncoder()
let (itersM, elapsedM) = try timeLoop(seconds) {
    _ = try encoder.encode(seed)
}
let nsPerOpM = Int64(elapsedM * 1_000_000_000.0) / Int64(itersM)
print(#"{"port":"swift","op":"marshal","ns_per_op":\#(nsPerOpM),"iterations":\#(itersM)}"#)
