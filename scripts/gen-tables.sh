#!/usr/bin/env bash
# Regenerates the static grammar tables in test/generated with JExi.SchemaGen.
#
#   scripts/gen-tables.sh           write them
#   scripts/gen-tables.sh --check   exit 1 if any is out of date
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec julia --startup-file=no --project="$ROOT" "$ROOT/scripts/gen-tables.jl" "$@"
