---
name: Bug report
about: Report a defect — wrong output, crash, parse error on valid input, etc.
title: "bug: "
labels: bug
---

<!--
Cross-port issues (the same input behaves differently on multiple ports)
belong upstream at trendvidia/protowire, not here. See CONTRIBUTING.md.

Security issues (decoder crash/hang/OOM on adversarial input) go to
security@trendvidia.com instead. See SECURITY.md.
-->

## What happened

A clear description of the bug.

## How to reproduce

Smallest possible PXF / PB / SBE / envelope input + Swift snippet that
triggers it.

```swift
import Protowire
// ...
```

## What you expected

What you thought should happen.

## Versions

- `protowire` version (git tag pinned in `Package.resolved`):
- `swift --version`:
- OS / arch:
