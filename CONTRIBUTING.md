# Contributing to protowire-swift

Welcome — this is the Swift port of [protowire](https://protowire.org), a
language-neutral wire-format toolkit. It tracks the canonical specification
in [`trendvidia/protowire`](https://github.com/trendvidia/protowire) and is
one of nine sibling ports (Go, C++, Rust, Java, TypeScript, Python, C#,
Swift, Dart). The port is pure Swift (SwiftPM) and uses
[`apple/swift-protobuf`](https://github.com/apple/swift-protobuf) as its
only runtime dependency.

> **Steward integration is rolling out.** The governance described in
> [GOVERNANCE.md](GOVERNANCE.md) is the steady-state model. While Steward
> is being finalised, pull requests are reviewed by human maintainers in
> the conventional way — open a PR, expect review, iterate.

## Where bugs go

| Symptom | File against |
|---|---|
| Swift port-only crash, wrong API ergonomics, performance regression in this port only | `trendvidia/protowire-swift` |
| The same input produces different output here vs another port | upstream [`trendvidia/protowire`](https://github.com/trendvidia/protowire) (cross-port wire-equivalence regression) |
| Spec / grammar / proto annotation question | upstream [`trendvidia/protowire`](https://github.com/trendvidia/protowire) |
| Decoder crash / hang / OOM on adversarial input | **email security@trendvidia.com**, do not file public issue (see [SECURITY.md](SECURITY.md)) |

## Toolchain

Swift 5.10+ (the floor in `Package.swift`'s `swift-tools-version`).
Tested in CI on:

- Latest Xcode toolchain × macOS
- Latest Swift release × Linux

Plus `swift build -Xswiftc -warnings-as-errors` (already enabled via
`Package.swift`'s `sharedSwiftSettings`) gates every PR.

## Local development

```sh
# Build + test
swift build
swift test

# Cross-port harnesses
swift run dump-envelope
swift run bench-pxf
swift run check-decode --format pxf --schema adversarial.v1.Tree \
  --proto ../protowire/testdata/adversarial/adversarial.proto \
  --input ../protowire/testdata/adversarial/pxf/deep-nesting-100.pxf
```

### Regenerating proto bindings

The `proto/` tree mirrors the upstream wire contract. Bindings are
generated through `buf` (see `buf.yaml` / `buf.gen.yaml`).

## Sending changes

1. Open a draft PR early.
2. **For changes that touch parser/encoder behaviour**: comment with
   which fixtures from `Tests/ProtowireTests/` you exercised. Cross-port
   wire-equivalence means a wrong move here can break six other ports'
   contracts.
3. **For changes that touch the wire format itself** — annotation field
   numbers in `proto/`, the PXF grammar, the SBE schema-id semantics —
   open the upstream PR in
   [`trendvidia/protowire`](https://github.com/trendvidia/protowire)
   first. This port shouldn't lead spec changes; it implements them.
4. **Anything that adds a new public symbol** must be re-exported from
   the umbrella `Protowire` module, not just live in an internal type.

## Code style

- `swift-format` recommended; the repo doesn't currently enforce a
  formatter in CI.
- `-warnings-as-errors` is enabled via `Package.swift`'s
  `sharedSwiftSettings`. Suppress with explicit `@available` /
  `#if compiler(...)` guards rather than `// swiftlint:disable`-style
  whole-file silencing.
- Match the existing zero-allocation patterns in `Sources/Protowire/SBE_View.swift` —
  the `View` API is the "zero allocation" reference point.

## What we don't accept

- Changes that break wire-equivalence with another sibling port.
- New top-level dependencies without a one-line justification in the
  PR description. We currently depend only on `swift-protobuf`.
- Static analysis suppressions on a whole file or whole module. Keep
  them line-scoped.

## Releases

This port releases in lockstep with the rest of the `protowire-*` stack.
The version line is `0.70.x` for the first coordinated public release;
ports that share a `0.70.x` minor implement the same wire contract.

Cutting a release:

1. Add a `## [X.Y.Z]` section to `CHANGELOG.md`.
2. Tag `vX.Y.Z` on `main`.
3. SwiftPM consumers pin against the git tag — there is no central
   registry to publish to.
