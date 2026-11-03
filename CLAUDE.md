# CLAUDE.md

Notes for future Claude sessions working on this Swift port.

## What this is

Standalone Swift port of `github.com/trendvidia/protowire`. The Go module
at `../protowire-go/` is the canonical reference — when behavior is
ambiguous, that's the source of truth. Annotation field numbers, the
envelope shape, and the `_null` FieldMask convention are cross-port wire
contracts and must not drift.

## Layout

SwiftPM package, single `Protowire` library target plus a `ProtowireTests`
test target. Sources are flat under `Sources/Protowire/`:

- `Protowire.swift` — wire primitives (varint / zigzag / fixed32-64 / tag).
- `PB.swift` — Codable-bridged protobuf binary codec.
- `PXF.swift` — lexer + `TokenKind` + `TypeResolver` protocol.
- `PXF_AST.swift` — Document / Entry / Value structs (custom `isEqual(to:)`
  for heterogeneous Value comparison).
- `PXF_Parser.swift` — tokens → AST.
- `PXF_Keyed.swift` — keyed repeated fields: rules, placement, canonical form.
- `PXF_Decoder.swift`, `PXF_Encoder.swift` — Codable bridges.
- `PXF_Result.swift` — per-field presence (set / null / absent).
- `PXF_Annotations.swift`, `PXF_Carrier.swift` — the descriptor index, and both
  spellings of an annotation: bracket options and the 1327 carrier.
- `PXF_Bind.swift` — the schema-bound pass (design call 8).
- `SBE.swift`, `SBE_Codec.swift`, `SBE_Template.swift`, `SBE_View.swift`
  — SBE primitives + dictionary codec + zero-copy reader.
- `Envelope.swift` — hand-written `Envelope`/`AppError`/`FieldError`.
- `*_v1_*.pb.swift`, `pxf_*.pb.swift`, `sbe_annotations.pb.swift` —
  swift-protobuf generated code (regenerate with `buf generate`).

## Build & test

```bash
swift build                # warning-clean (treats warnings as errors)
swift test                 # XCTest, ~20 cases
buf generate               # regen *.pb.swift files (uses buf.gen.yaml)
```

The package keeps `swift-tools-version: 5.10` for broader compatibility;
`unsafeFlags(["-warnings-as-errors"])` enforces zero warnings (the
`treatAllWarnings` API requires PackageDescription 6.2+).

`ConformanceTests` compares this port with protowire-go over the spec corpus,
and needs no Go toolchain. `conformance/README.md` covers the record and the
ledger. Remove a ledger entry in the commit that fixes it, and refresh the
record with `conformance/update.sh`.

## Cross-port wire contracts (don't re-derive)

- `pb`: signed-int fields default to proto3 `int32`/`int64` (plain
  varint). Canonical envelope: 129 bytes (258 hex chars) starting
  `08 92 03 1a 04 de ad be ef 22 76 …`.
- `pxf` annotations: `(pxf.required)` = 1314, `(pxf.default)` = 1315,
  `(pxf.key)` = 1316. Their definitions live in `proto/pxf/annotations.proto`.
- `_null` field of type `google.protobuf.FieldMask` carries null-survival
  across protobuf binary.
- `sbe` annotations: `sbe.schema_id` = 1319, `version` = 1320,
  `template_id` = 1321, `length` = 1322, `encoding` = 1323.
- `sbe` wire: 8-byte LE message header + 4-byte LE group header.

## Design calls (settled)

1. **Codable bridge as the public API.** Users encode/decode their own
   `Codable` types via `PXFEncoder`/`PXFDecoder`/`PBEncoder`/`PBDecoder`.
   This keeps the surface idiomatic Swift even though it forces some
   `Mirror`-based introspection in the encoder paths.
2. **Wrapper sugar is name-gated, not heuristic.** `PXFEncoder` only
   inlines `field = innerValue` for the nine SwiftProtobuf-generated
   `Google_Protobuf_*Value` types (DoubleValue, FloatValue, Int64Value,
   UInt64Value, Int32Value, UInt32Value, BoolValue, StringValue,
   BytesValue) — see `PXFEncoder.isProtobufWrapper`. A user struct with
   one `value` field gets emitted as a regular nested block; the previous
   "any single-`value`-field type" heuristic was a quiet false-positive
   trap. The decode side still recognizes a single `value` key in a
   `_PXFSingleValueDecoder.WrapperContainer` for symmetry with the
   encode-side hand-off.
3. **`_null` FieldMask round-trip via the Codable container API.**
   `PXFDecoder.unmarshalFull` pre-walks the document for `field = null`
   entries, marks them in the `Result`, then synthesizes a `_null` key
   in the keyed container at the top level. The user's struct can declare
   `_null` as `[String]` or as `Google_Protobuf_FieldMask` — the decoder
   returns the populated value to the synthesized init. Encode side
   already worked: the encoder reads a `_null` field via Mirror and
   emits `field = null` for each path.
4. **Final classes** for `Lexer`, `Parser`, `PXFEncoder`/`PXFDecoder`,
   `PBEncoder`/`PBDecoder`, `SBEMarshaller`/`SBEUnmarshaller`,
   `MessageTemplate`. Subclassing isn't a use case.
5. **Throw, don't `fatalError`, in throwing Codable methods.** Some
   non-throwing protocol methods (`Encoder.unkeyedContainer()`,
   `singleValueContainer()`) still `fatalError` when misused — that's
   a Swift Codable API limitation. `SBE.View` uses `fatalError` for
   misuse by deliberate design (fast-path read API, parity with `Array`).
6. **Generated code stays under `Sources/Protowire/*.pb.swift`.** Regen
   via `buf generate` (plugin pin: `buf.build/apple/swift:v1.37.0`,
   matching the swift-protobuf runtime version). If you update the
   runtime in `Package.swift`, bump the plugin pin in `buf.gen.yaml`
   to match — mismatches produce ~50 deprecation warnings about
   `init(dictionaryLiteral:)`.

7. **Keyed repeated fields are an AST rewrite, not a decode loop.** The
   Codable decoder has no descriptor, so `Annotations.expandKeyed` turns each
   keyed binding into the anonymous list it is equivalent to before the Swift
   type runs. Any quoted name that survives is outside a keyed block, which is
   why `rejectQuotedNames` needs no schema. Keys compare by UTF-8 bytes: Swift's
   `==` is canonical equivalence and would merge two distinct keys.

8. **The schema rules are one pass over the AST, not container logic.** A
   Swift type sees only the fields it asks for, so a rule about a whole body
   can't live in a Codable container. `PXF.Binder` (`PXF_Bind.swift`) walks the
   document against the descriptor, enforces the binding rules, builds a
   `BoundMessage` and adds each applied default as an entry, and the Codable
   decoder then runs on those entries. It mirrors `decodeFields` and `postDecode`
   in protowire-go. `BoundMessage` stays internal: the Codable bridge remains
   the public API, and the bytes exist so `ConformanceTests` can compare them.

9. **The encoder builds a tree, and one function renders it.** `PXFEncoder`
   turns a value into a `PXFNode`, and `PXFRenderer` writes the text, which is
   where a schema changes the output. `PXF_BoundText.swift` puts a `BoundMessage`
   through the same containers a user's type uses, so the `text` leg of
   `ConformanceTests` exercises the real encoder.

10. **A literal carries its call's digit cap.** `Hardening.Limits` reaches the
   parser and the PB and SBE decoders directly. The Codable containers don't
   hold it, so `PXF.Parser` writes `MaxNumericLiteralDigits` onto each `IntVal`
   for a big-number type to read. A list's or map's count is checked by the
   parser as it reads, and across bindings by `PXF.checkRepeatedCounts`.

## Open gaps (not yet implemented)

- **The remaining bind-time checks.** `validateSchema` covers `(pxf.key)`,
  default placement, the oneof rules, required with default and duplicate
  names. Reserved names, retired option numbers and well-known shapes are
  tracked in #55.
- **Message-typed SBE codec.** `SBE.templates(from:)` builds a
  `MessageTemplate` from a descriptor set, but the codec reads and writes
  dictionaries, not message types. The cross-port `bench-sbe` harness isn't
  shipped.

## What this repo does NOT contain

- No CLI. The shared `protowire` CLI lives at
  `../protowire/cmd/protowire/` (Go, depending on `protowire-go` as a
  library). All language ports rely on it.
- No format-spec code. Grammar / annotation `.proto` definitions live
  in the spec repo at `../protowire/`. The `proto/` tree here is a
  mirror used by `buf generate`; it should track the canonical copy.

## Working conventions

- After any change to `PB.swift` or `Envelope.swift`, run the cross-port
  envelope check: `bash ../protowire/scripts/cross_envelope_check.sh`
  (set `SKIP_PORTS=swift` if the swift bench harness is the thing that
  broke).
- Cross-port bench harnesses (`bench-pxf`, `dump-envelope`)
  are SwiftPM `executableTarget`s — see `Package.swift`. They each take
  `--seconds N` and `--testdata DIR` and emit one JSON line per op,
  matching the shape that `cross_*_bench.sh` aggregates.
- Don't add `.swift-version` files; the package's `swift-tools-version`
  pin is the canonical source.
