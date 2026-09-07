# Changelog

All notable changes to `protowire-swift` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

SwiftPM consumers pin against git tags; the version number is kept
aligned with the rest of the `protowire-*` stack — releases bump in
lockstep across language ports when the wire format changes.

## [Unreleased]

### Added

- **`(pxf.required)` and `(pxf.default)` on the Codable decode path**
  (#11). `PXF.Annotations(descriptorSet:)` indexes the two annotations
  (extension numbers 1314 and 1315) per message from a
  `Google_Protobuf_FileDescriptorSet` parsed with
  `Pxf_Annotations_Extensions`; `PXFDecoder(annotations:rootMessage:)`
  then rejects an absent required field before the Swift type sees the
  document (every field the schema declares, whether or not the type asks
  for it), synthesises the schema's default for an absent field the type
  does ask for, and follows the descriptor into singular nested messages.
  Semantics mirror protowire-go's `postDecode`: `null` counts as present,
  list elements and map values are not annotated, and a defaulted field is
  still reported absent by `PXF.Result`. A decoder without annotations
  behaves exactly as before.
- `dump-envelope --pb FDS MESSAGE DOC`, the gate leg protowire's
  `cross_envelope_check.sh` had listed as a declared omission for this port
  (#10): the fixture document is decoded into a hand-mirrored Codable type
  with the annotations from FDS and marshalled with `PBEncoder`.

## [1.0.0]

Lockstep release with the rest of the `protowire-*` stack at the v1.0.0
spec freeze. Catches the Swift port up from v0.70 to the full v0.72–v1.0
directive grammar (drafts §3.4.2–§3.4.6).

### Added

- **`@<name>` generic directives** (draft §3.4.2): top-of-document
  `@<name> *(<prefix-id>) [{ ... }]` blocks, e.g. chameleon's
  `@header chameleon.v1.LayerHeader { id = "x" }`. Captured on
  `Document.directives` and on `Result.directives` from `unmarshalFull`.
- **`@entry` named directive** (draft §3.4.3): zero/one/two-prefix
  shape, handled by the same generic mechanism.
- **`@dataset <type> ( cols ) row*`** (draft §3.4.4): the protowire-native
  CSV — many instances of one message type in a single document.
  Mutually exclusive with `@type` and top-level field entries.
  Exposed on `Document.datasets` / `Result.datasets`.
- **`@proto`** (draft §3.4.5): embedded protobuf schema with four
  lexically-distinguished body shapes — anonymous `{ ... }`, named
  `<dotted-name> { ... }`, source `""" ... """`, descriptor `b"..."`.
- **`PXF.Schema.isFutureReservedDirective`** (draft §3.4.6): v1 decoders
  reject `@table`, `@datasource`, `@view`, `@procedure`, `@function`,
  `@permissions` so applications cannot squat the names before the spec
  allocates semantics.

### Changed (breaking)

- **`@table` removed**; use `@dataset` (no alias period — same hard
  cutover the rest of the stack made for v1.0).
- **`PXF.Document` extended** with `directives`, `datasets`, `protos`,
  `bodyOffset` fields. Existing consumers of `typeURL` / `entries`
  remain source-compatible.

## [0.70.0]

Initial public release. The version number aligns this port with the rest
of the `protowire-*` stack, which targets the 0.70.x series for the first
coordinated public release.

### Changed (breaking)

- **PXF parser stricter on key forms**, mirroring the upstream grammar
  tightening in
  [`trendvidia/protowire@8262bbb`](https://github.com/trendvidia/protowire/commit/8262bbb)
  (`docs/grammar.ebnf`, `docs/draft-trendvidia-protowire-00.txt`):
  - `=` (field assignment) and `{ … }` (submessage) now require an
    identifier key. Inputs like `123 = 234` or `child { 123 = 123 }`
    are now parse errors with
    `"field assignment with '=' requires an identifier key, got integer
    (\"123\"); use ':' for map entries"`.
  - `:` (map entry) is rejected at document top level — the document
    represents a proto message, never a `map<K,V>`. Use `=` for
    top-level field assignments. Map literals (`field = { 1: "x" }`)
    still work because `:` remains valid inside `{ … }` blocks.

  Three new cases on the `PXF.ParserError` enum carry the new error
  positions and messages:
  `fieldAssignmentRequiresIdentifierKey`,
  `submessageBlockRequiresIdentifierKey`,
  `mapEntryNotAllowedAtTopLevel`.
