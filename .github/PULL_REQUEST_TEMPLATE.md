<!--
For changes that touch wire-format behaviour: please open the upstream
PR in trendvidia/protowire FIRST. This port implements the spec; it
shouldn't lead spec changes. See CONTRIBUTING.md.
-->

## Summary

What this PR changes, in 1–3 sentences.

## Why

Link to the issue or upstream spec change that motivated this.

## Scope

- [ ] Wire-impacting source (`Sources/Protowire/`)
- [ ] Vendored proto annotations (`proto/`)
- [ ] Tests / cross-port harnesses (`Tests/`, `cmd/`)
- [ ] Build / CI / repo plumbing (`Package.swift`, `.github/`)
- [ ] Documentation only

## Test plan

- [ ] `swift build` clean (`-warnings-as-errors` is on by default)
- [ ] `swift test` clean
- [ ] If parser/encoder change: `swift run check-decode` clean against
      the upstream adversarial corpus
- [ ] If wire-impacting: matching upstream spec PR linked above
- [ ] If new public symbol: covered by a test in `Tests/ProtowireTests/`
