// Cross-port envelope wire-compatibility dumper.
//
// Constructs a canonical envelope, encodes it via PBEncoder, and prints
// the bytes as a hex string. Every other port produces the same hex; the
// spec repo's `scripts/cross_envelope_check.sh` asserts byte-equality.
//
// Mirrors `protowire-go/scripts/dump_envelope/main.go`.

import Foundation
import Protowire

var ae = AppError(code: "INSUFFICIENT_FUNDS",
                  message: "balance too low",
                  args: ["$3.50", "$10.00"])
ae.withField(field: "amount", code: "MIN_VALUE", message: "below minimum", args: "10.00")
ae.withMeta(key: "request_id", value: "req-123")

let env = Envelope(status: 402,
                   data: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                   error: ae)

let bytes = try PBEncoder().encode(env)
print(bytes.map { String(format: "%02x", $0) }.joined())
