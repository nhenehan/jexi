#!/usr/bin/env bash
# Everything a commit must pass.
#
#   scripts/gate.sh           tests (with Aqua and JET) on the oldest supported
#                             Julia and the current one, then the generated-table
#                             and fixture checks
#   scripts/gate.sh --quick   tests on the current Julia only
#
# The full gate needs the judges (exipd, exip's test data): it sets
# JEXI_REQUIRE_JUDGES, so tests that need them fail instead of skipping.
# Run scripts/fetch-third-party.sh --build first.
#
# Env: JEXI_JULIA_LTS      juliaup channel of the oldest Julia (default release;
#                          it must be a 1.10.x)
#      JEXI_JULIA_CURRENT  juliaup channel of the current Julia (default 1.12)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LTS="${JEXI_JULIA_LTS:-release}"
CURRENT="${JEXI_JULIA_CURRENT:-1.12}"

QUICK=0
case "${1:-}" in
    --quick) QUICK=1 ;;
    "") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

step() { echo; echo "== $*"; }

run_tests() { # channel
    # Manifests are not committed; each Julia resolves its own (JET's version
    # follows the Julia release).
    rm -f Manifest.toml test/Manifest.toml
    julia +"$1" --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
}

if [[ $QUICK -eq 0 ]]; then
    export JEXI_REQUIRE_JUDGES=1
    lts_version="$(julia +"$LTS" --startup-file=no -e 'print(VERSION)')"
    [[ "$lts_version" == 1.10.* ]] || {
        echo "juliaup channel '$LTS' is Julia $lts_version, not 1.10.x (set JEXI_JULIA_LTS)" >&2
        exit 1
    }
    step "tests on Julia $lts_version ($LTS)"
    run_tests "$LTS"
fi

step "tests on Julia $(julia +"$CURRENT" --startup-file=no -e 'print(VERSION)') ($CURRENT)"
run_tests "$CURRENT"

if [[ $QUICK -eq 0 ]]; then
    if [[ -x scripts/gen-tables.sh ]]; then
        step "generated tables"
        scripts/gen-tables.sh --check
    fi
    step "fixtures"
    scripts/sync-fixtures.sh --check
fi

echo
echo "gate passed"
