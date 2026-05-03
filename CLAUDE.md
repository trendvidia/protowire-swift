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
- `PXF_Decoder.swift`, `PXF_Encoder.swift` — Codable bridges.
- `PXF_Result.swift` — per-field presence (set / null / absent).
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

## Cross-port wire contracts (don't re-derive)

- `pb`: signed-int fields default to proto3 `int32`/`int64` (plain
  varint). Canonical envelope: 129 bytes (258 hex chars) starting
  `08 92 03 1a 04 de ad be ef 22 76 …`.
- `pxf` annotations: `(pxf.required)` = 50000, `(pxf.default)` = 50001.
  Their definitions live in `proto/pxf/annotations.proto`.
- `_null` field of type `google.protobuf.FieldMask` carries null-survival
  across protobuf binary.
- `sbe` annotations: `sbe.schema_id` = 50100, `version` = 50101,
  `template_id` = 50200, `length` = 50300, `encoding` = 50301.
- `sbe` wire: 8-byte LE message header + 4-byte LE group header.

## Design calls (settled)

1. **Codable bridge as the public API.** Users encode/decode their own
   `Codable` types via `PXFEncoder`/`PXFDecoder`/`PBEncoder`/`PBDecoder`.
   This keeps the surface idiomatic Swift even though it forces some
   `Mirror`-based introspection in the encoder paths. A parallel
   descriptor-driven path (against `SwiftProtobuf.Message`) is layered
   on top for things that need real proto semantics (presence,
   `(pxf.required)` / `(pxf.default)`, `_null` FieldMask, WKT defaults).
2. **Final classes** for `Lexer`, `Parser`, `PXFEncoder`/`PXFDecoder`,
   `PBEncoder`/`PBDecoder`, `SBEMarshaller`/`SBEUnmarshaller`,
   `MessageTemplate`. Subclassing isn't a use case.
3. **Throw, don't `fatalError`, in throwing Codable methods.** Some
   non-throwing protocol methods (`Encoder.unkeyedContainer()`,
   `singleValueContainer()`) still `fatalError` when misused — that's
   a Swift Codable API limitation. `SBE.View` uses `fatalError` for
   misuse by deliberate design (fast-path read API, parity with `Array`).
4. **Generated code stays under `Sources/Protowire/*.pb.swift`.** Regen
   via `buf generate` (plugin pin: `buf.build/apple/swift:v1.37.0`,
   matching the swift-protobuf runtime version). If you update the
   runtime in `Package.swift`, bump the plugin pin in `buf.gen.yaml`
   to match — mismatches produce ~50 deprecation warnings about
   `init(dictionaryLiteral:)`.

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
- Cross-port bench harnesses (`bench-pxf`, `bench-sbe`, `dump-envelope`)
  are SwiftPM `executableTarget`s — see `Package.swift`. They each take
  `--seconds N` and `--testdata DIR` and emit one JSON line per op,
  matching the shape that `cross_*_bench.sh` aggregates.
- Don't add `.swift-version` files; the package's `swift-tools-version`
  pin is the canonical source.
