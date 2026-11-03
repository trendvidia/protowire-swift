# Changelog

All notable changes to `protowire-swift` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

SwiftPM consumers pin against git tags; the version number is kept
aligned with the rest of the `protowire-*` stack — releases bump in
lockstep across language ports when the wire format changes.

## [Unreleased]

### Added

- **`pxf.BigFloat`, `pxf.BigInt` and `pxf.Decimal` read and write as literals**
  ([#26](https://github.com/trendvidia/protowire-swift/issues/26)). A BigFloat
  literal is read exactly, at the precision its `p<bits>` suffix states or 256
  bits without one, and written with enough digits to read back. All three are
  now `Encodable`: `PXFEncoder` writes the literal and `PBEncoder` the message
  fields. A precision suffix on any other field is an error naming the field.
  `Hardening.maxBigFloatExponent` is new.
### Fixed

- **`PXFEncoder` writes what the reference writes**, and `ConformanceTests` now
  compares its text with `pxf.Marshal` over the corpus. Lists were invalid text and
  now round-trip ([#32](https://github.com/trendvidia/protowire-swift/issues/32)). A
  nested `_null` path is written inside its own block, not as a dotted root entry
  ([#42](https://github.com/trendvidia/protowire-swift/issues/42)). **The text
  changes for existing types:** nested messages are `name { ... }` rather than
  `name = { ... }`, lists are one element per line, map keys are sorted, an empty list
  or map is left out unless `emitDefaults` is set, floats use Go's `%g` spelling,
  and a timestamp has no trailing zeros. With a schema, an enum's name is written bare.
- `Protowire.consumeFixed32`, `consumeFixed64` and `SBE.readHeader` read a `Data`
  slice at any offset. They trapped on a misaligned one.

### Changed

- **A schema the draft refuses now fails every decode**, before the document is
  read ([#38](https://github.com/trendvidia/protowire-swift/issues/38),
  [#39](https://github.com/trendvidia/protowire-swift/issues/39)), anywhere in the
  import closure: a default on a repeated, map or group field or on a message
  type with no literal, `(pxf.required)` on a oneof member, two defaults in one
  oneof, and two messages with one name. `PXF.Annotations.validateSchema(message:)`
  reports the same without a document. `PXF.AnnotationError` gains three cases, so
  an exhaustive `switch` over it needs them. `validateRequiredDefault` and
  `validateKeyPlacement` still report their one rule each.
- **`@required` and `@default` are read**, from the 1327 annotation carrier, so a
  schema migrated to the annotation form is enforced as the bracket form is. Two
  spellings of one default that differ refuse the schema. An `@default` holding a
  `big_float_value` refuses it too, until #26.
- Bracket annotations are read from a descriptor set parsed without
  `Pxf_Annotations_Extensions`, where they used to be ignored.
- A message-typed `(pxf.default)` is a literal, as in the reference: a Timestamp,
  Duration, wrapper, `pxf.BigInt`, `pxf.Decimal` or `pxf.BigFloat`. **A `{ ... }`
  block as a default is now refused**; `defaultValue(for:)` used to accept one.
- A `pxf.Decimal` literal binds in a schema-bound decode. A Swift `Pxf_Decimal`
  still reads only the block form.
- **A decoder with a schema now enforces the draft's binding rules across the
  whole document**, whatever the Swift type asks for. `PXFDecoder(annotations:rootMessage:)`
  rejects a singular field or a map key bound twice
  ([#25](https://github.com/trendvidia/protowire-swift/issues/25),
  [#27](https://github.com/trendvidia/protowire-swift/issues/27)), a second oneof
  member, `null` where the field has no unset state
  ([#24](https://github.com/trendvidia/protowire-swift/issues/24)), a body that undoes
  a keyed entry's name ([#44](https://github.com/trendvidia/protowire-swift/issues/44)),
  a bare identifier on a string field, an unknown field, and a type entry that
  doesn't resolve ([#22](https://github.com/trendvidia/protowire-swift/issues/22)).
  **Documents and schemas this port used to accept can now fail.** Set
  `discardUnknown` to keep skipping unknown fields.
- `(pxf.required)` and `(pxf.default)` apply in every message body: list
  elements, map values and `Any` bodies
  ([#41](https://github.com/trendvidia/protowire-swift/issues/41)). A oneof
  member's default stays off when a sibling is present.
- Without a schema, the Codable path also rejects a singular field or a map key
  bound twice, concatenates repeated bindings and merges a map's bindings
  ([#33](https://github.com/trendvidia/protowire-swift/issues/33)). It can't reject
  a bare identifier there, because a Swift enum decodes from one.

### Fixed

- A `[String: T]` of messages keeps its values
  ([#28](https://github.com/trendvidia/protowire-swift/issues/28)), and a map's keys
  can be any integer type or `Bool`.
- An out-of-range integer throws instead of trapping the process, and a list
  element of the wrong type throws instead of decoding as zero.

### Added

- `PXFDecoder.decodeRows(_:of:)` binds each row of a `@dataset` as the message
  body it stands for, list and block cells and dotted columns included
  ([#21](https://github.com/trendvidia/protowire-swift/issues/21),
  [#23](https://github.com/trendvidia/protowire-swift/issues/23)).
- **`swift test` compares this port with protowire-go over the whole spec
  corpus** ([#45](https://github.com/trendvidia/protowire-swift/issues/45)):
  parse verdicts, schema-bound decode verdicts, protobuf bytes and formatted text, for 250
  documents. `conformance/README.md` explains the record, the ledger of known
  disagreements, and how to refresh them.
- **`PXF.Parser` reads every form in the spec's syntax corpus.** The parse leg
  of the comparison above goes from 68 disagreements to 0.
  - Duration literals with a fraction, `µs` or a sign, such as `1.5ms` and
    `-312.5µs` ([#8](https://github.com/trendvidia/protowire-swift/issues/8)),
    which is what other ports write for a measured latency. U+03BC is not a
    unit, and a duration past 64-bit nanoseconds is an error.
  - The type entry of an `Any` block, `@type = "..."` as a block's first entry
    ([#22](https://github.com/trendvidia/protowire-swift/issues/22)). It is in
    `typeURL` on `PXF.Block` and `PXF.BlockVal`, and not in `entries`.
  - List and block cells, and dotted column paths, in a `@dataset`
    ([#21](https://github.com/trendvidia/protowire-swift/issues/21),
    [#23](https://github.com/trendvidia/protowire-swift/issues/23)). A header
    that names a path twice, a field beside a path inside it, or an empty path
    segment is rejected at that column.
  - `true:` and `false:` as map keys. `PXF.MapEntry.keyKind` records how a key
    was spelled.
  - A `p<prec>` suffix on a number stays in `IntVal.raw` / `FloatVal.raw`
    ([#26](https://github.com/trendvidia/protowire-swift/issues/26)). No value
    is computed from it yet.
  - A comment on the same line, after a value, is that entry's `trailingComment`.
  - `b"..."` accepts URL-safe and unpadded base64.

### Fixed

- **`PXF.Format.formatDocument` writes what `pxf fmt` writes**: the comparison's
  format leg goes from 16 disagreements to 0. A type entry and a trailing
  comment are kept, and strings are quoted as the reference quotes them.
- **A map key's spelling follows draft -01 § Entries and Keys**
  ([#18](https://github.com/trendvidia/protowire-swift/issues/18),
  [#19](https://github.com/trendvidia/protowire-swift/issues/19)). The formatter
  used to turn `"true":` into `true:`, which no longer binds on a string key. It
  now keeps a key's quotes unless the key is identifier-safe, dots included, and
  a bare key stays bare.
- **`PXFEncoder` writes a dictionary as a map**, `by_label = { a.b: 1 }`, with
  string keys spelled by that same rule. It used to write `a.b = 1`, and a key
  like `my key` came out unquoted. Key order is still the dictionary's.

### Changed

- **`PXF.Parser` rejects what the grammar does.** A raw line feed in a simple
  string, in a `@dataset` cell too
  ([#24](https://github.com/trendvidia/protowire-swift/issues/24)); an
  unterminated block comment, triple-quoted string or bytes literal; invalid
  base64 at the literal; a `+` on anything but `+inf`.
- **The `@type <identifier>` value prefix is gone**
  ([#22](https://github.com/trendvidia/protowire-swift/issues/22)). It was never
  in the grammar. Write `payload = { @type = "<url>" ... }`.
- **A triple-quoted string is dedented**
  ([#24](https://github.com/trendvidia/protowire-swift/issues/24)): the line feed
  after the opening quotes goes, and when the closing quotes sit on their own
  line, that line goes and its indent is stripped from the others.
- **A comment keeps its text.** A block comment's `Comment.text` now includes
  `/*` and `*/`, as a line comment's includes its marker, and non-ASCII comments
  and triple-quoted strings are no longer garbled.
- `PXF.ParserError` loses `datasetDottedColumn` and `datasetCellRejected` and
  gains `datasetColumn` and `lexical`, so an exhaustive `switch` needs updating.

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
