# Conformance against protowire-go

`swift test` compares this port with the Go reference over the spec repo's
whole `testdata/` corpus. The reference decides every verdict, and Go is not
needed to run the comparison.

| Path | What it is |
|---|---|
| `conformance/refgen/` | Go program, pinned to a protowire-go commit in its `go.mod`, that runs each document through the reference |
| `conformance/update.sh` | Runs refgen against a protowire checkout (`SPEC_DIR`, by default the sibling one) |
| `Tests/ProtowireTests/testdata/conformance/` | Its output: `corpus/`, `descriptors/`, `reference.jsonl`, `provenance.json` |
| `Tests/ProtowireTests/testdata/conformance/ledger.json` | Hand-kept: known disagreements, by leg |
| `Tests/ProtowireTests/ConformanceTests.swift` | The comparison |

## What is compared

Each leg of `ConformanceTests` compares one thing per document:

| Leg | This port | Reference |
|---|---|---|
| `parse` | `PXF.Parser` | `pxf.Parse` |
| `decode` | `PXFDecoder` bound to the document's message | `UnmarshalFullDescriptor`, or `BindRow` for each dataset row |
| `pb` | The schema-bound pass's `BoundMessage`, one per row of a dataset | The decoded message, marshalled deterministically |
| `format` | `PXF.Format.formatDocument` | `pxf.FormatDocument` |

Use the reference's full decode here. The plain `UnmarshalDescriptor` leaves
`(pxf.required)` and `(pxf.default)` to the caller. refgen refuses to write a
record in which `annotations/missing-required.pxf` was accepted, so a run that
skipped the annotations can't pass for a good one.

## The ledger

A disagreement fails the test unless `ledger.json` lists it under its leg with
the issue tracking it. An entry that no longer disagrees fails too, so a fix has
to remove its own entries and the ledger can only shrink.

To see what a leg disagrees on, write it out:

```bash
mkdir -p /tmp/actual
CONFORMANCE_ACTUAL=/tmp/actual swift test --filter ConformanceTests
```

## Refreshing

```bash
conformance/update.sh
```

Then read the diff under `testdata/conformance/`. A changed record is either a
change in the reference, which this port now has to follow, or a new fixture.
To follow a newer reference, run `GOWORK=off go get
github.com/trendvidia/protowire-go@<commit>` in `conformance/refgen/` first.

CI's `conformance-record` workflow checks the record two ways. On a pull request
it regenerates from the revisions in `provenance.json` and fails on any
difference, which proves the record is what the reference writes. On a schedule
it regenerates from the head of protowire and protowire-go, which shows drift.
