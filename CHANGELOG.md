# Changelog

All notable changes to `protowire-swift` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

SwiftPM consumers pin against git tags; the version number is kept
aligned with the rest of the `protowire-*` stack — releases bump in
lockstep across language ports when the wire format changes.

## [Unreleased]

### Fixed

- **`PXF.Result` reports a keyed entry's key field, and every other nested
  field, at its real path** ([trendvidia/protowire-go#214](https://github.com/trendvidia/protowire-go/issues/214)).
  After decoding `kd { alpha {} }`, `isSet("kd[0].name")` is now true. Paths
  used to lose the message they belong to: that key was recorded as a root
  field `name`, and `limits { max = 1 }` as `max`, where a caller checking
  `isSet("name")` got the wrong answer. Paths now follow the Go reference
  (`limits.max`, `regions[0].name`), and list elements read `kd[0]` instead of
  `.0`. Any code that matched the old flat paths needs the full path.
- **A field the document sets is present whatever the Swift type does with
  it.** A non-optional property, or a field the type does not declare, used to
  stay absent in `PXF.Result`.
- **`_null` no longer collects nulls from list elements**, as in the Go
  reference (trendvidia/protowire-go#170); `allNullFields` still reports them.
  A null inside a singular message appears in `_null` under its full path. A
  nested message's own `_null` property is no longer filled with the root's
  mask.

## [1.1.0]

### Fixed

- **`(pxf.required)` with `(pxf.default)` on one field is a schema error**
  (#35), as draft -01 requires (trendvidia/protowire#453). Such a schema used
  to bind, and the required check won when a document omitted the field. Every
  decode through `PXFDecoder(annotations:rootMessage:)` now fails with
  `PXF.AnnotationError.requiredWithDefault`, before the document is read,
  when the pair is anywhere in the import closure of the file declaring the
  root message. `PXF.Annotations.validateRequiredDefault(message:)` reports
  the same thing without a document. `(pxf.required) = false` beside a default
  stays accepted. `PXF.AnnotationError` gains a case, so an exhaustive `switch`
  over it needs one more arm.
### Changed

- **The vendored shared schemas are re-synced with [trendvidia/protos](https://github.com/trendvidia/protos) v0.1.2** ([trendvidia/protowire#447](https://github.com/trendvidia/protowire/issues/447)). They gain protos' file options, and `envelope.proto`'s `go_package` now names a published package. Declarations and field numbers are unchanged, and so is this port's public API.

### Added

- **Quoted entry names and keyed repeated fields** (draft `-01` "Keyed Repeated
  Fields"; [#7](https://github.com/trendvidia/protowire-swift/issues/7),
  [trendvidia/protowire#116](https://github.com/trendvidia/protowire/issues/116)).
  The grammar accepts a string as an entry name anywhere (`field_entry =
  (identifier | string), (assignment_tail | block_tail)`); `Assignment.keyQuoted`
  and `Block.nameQuoted` record it, and `PXF.Format.formatDocument` reproduces
  it. `(pxf.key)` = 1316 is back in the vendored annotations and indexed by
  `PXF.Annotations`, which rejects a misplaced one across the bound file's import
  closure (`validateKeyPlacement`, also run by the decoder and encoder). With
  annotations, `PXFDecoder` reads the keyed block form, in either spelling and
  concatenated across bindings, and rejects duplicate names (compared unquoted,
  byte for byte), the empty key in either form and a disagreeing key assignment;
  a quoted name anywhere else is rejected, with or without a schema.
  `PXFEncoder(annotations:rootMessage:)` writes the keyed form whenever every key
  is present, non-empty and distinct, unquoted exactly when identifier-safe, and
  the anonymous list otherwise. `Annotations.canonicalizeKeyed` is the schema half
  of `pxf fmt`: anonymous to keyed where eligible, `name = { }` to `name { }`,
  identifier-safe names unquoted, redundant key assignments dropped. The spec
  repo's `testdata/keyed/` corpus is vendored and driven by `PXFKeyedTests`.
  This port has no tolerant parse mode, so the keyed errors are always hard
  failures. Wire output is unchanged: a keyed field is a plain repeated field in
  `pb`.
- **`pxf.BigInt` literals and `MaxNumericLiteralDigits`** (#17,
  trendvidia/protowire#279). `Pxf_BigInt` is now `Decodable`: a PXF integer
  literal decodes to its value, and one with more than
  `Hardening.maxNumericLiteralDigits` (4096) significant digits throws
  `DecoderError.numericLiteralTooLong`, naming the limit. Exactly 4096 digits
  is accepted. Leading zeros and the sign do not count. The message form, a
  PXF block or PB, is not bounded by the cap.
- `Pxf_Decimal` and `Pxf_BigFloat` are `Decodable` in the message form only.
  A PXF literal on either is an error.
- `check-decode` links `adversarial.v1.BigNumHolder`. It used to refuse the
  schema by name, so `pxf/long-numeric.pxf` passed without reaching a decoder.
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
- `check-decode`'s `Tree` declares `children`, `branches` and `tags`, so the
  corpus's map rows reach the PB decoder instead of being skipped as unknown
  fields (trendvidia/protowire#449). The decoders already count a map's `{` and
  every PB map entry toward `MaxNestingDepth`; `HardeningTests` now pins both
  sides of that bound.
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
