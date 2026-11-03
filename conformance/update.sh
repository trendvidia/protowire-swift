#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 TrendVidia, LLC.
#
# Regenerates Tests/ProtowireTests/testdata/conformance from a protowire
# checkout, by default the sibling one. See conformance/README.md.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
spec="${SPEC_DIR:-$repo/../protowire}"

cd "$repo/conformance/refgen"
GOWORK=off go run . --spec "$spec" --out "$repo/Tests/ProtowireTests/testdata/conformance"
