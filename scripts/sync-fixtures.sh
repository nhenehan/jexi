#!/usr/bin/env bash
# Copy the test fixtures from the pinned rexi checkout into test/fixtures, and
# record rexi's grammar listings for the interop schemas.
#
#   interop/      EXIficient 1.0.7 bytes, decoded events and grammar dumps
#                 (rexi's scripts/gen-fixtures.sh made them; rexi only carries
#                 them), verified against manifest.tsv
#   spec/         the Appendix C options schema
#   whitespace/   rexi-xml's whitespace schemas
#   listings/     `rexi dump-grammar` of each interop case, which the schema
#                 compiler must reproduce exactly
#
#   scripts/sync-fixtures.sh           copy and regenerate
#   scripts/sync-fixtures.sh --check   exit 1 if anything differs from the pin
#                                      or a file does not match its sha256
#
# Env: JEXI_THIRD_PARTY  cache directory (see scripts/fetch-third-party.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${JEXI_THIRD_PARTY:-${XDG_CACHE_HOME:-$HOME/.cache}/jexi/third_party}"
REXI="$DIR/rexi"
REXI_BIN="$REXI/target/release/rexi"
DST="$ROOT/test/fixtures"
# published directory -> source directory in the rexi checkout
COPIES=(
    "interop:crates/rexi-tests/fixtures/interop"
    "spec:crates/rexi-tests/fixtures/spec"
    "whitespace:crates/rexi-xml/tests/whitespace"
)

CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    "") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

# Every file the manifest lists must have its recorded sha256.
verify() { # dir
    local st=0 name profile file sha rest
    while IFS=$'\t' read -r name profile file sha rest; do
        [[ "$name" == name ]] && continue
        if [[ "$(sha256sum "$1/$file" | cut -d' ' -f1)" != "$sha" ]]; then
            echo "SHA      $file" >&2
            st=1
        fi
    done <"$1/manifest.tsv"
    return $st
}

# Writes `rexi dump-grammar` of each interop case into $1.
listings() { # out dir
    mkdir -p "$1"
    local name xml main imports xsd
    while IFS=$'\t' read -r name xml main imports; do
        [[ "$name" == name ]] && continue
        xsd="$DST/interop/$main"
        [[ -n "$imports" ]] && xsd="$xsd,$DST/interop/$imports"
        "$REXI_BIN" dump-grammar --xsd "$xsd" >"$1/$name.txt"
    done <"$DST/interop/cases.tsv"
}

if [[ $CHECK -eq 1 ]]; then
    st=0
    if [[ -d "$REXI" ]]; then
        for c in "${COPIES[@]}"; do
            diff -r -q "$REXI/${c#*:}" "$DST/${c%%:*}" >&2 || st=1
        done
        if [[ -x "$REXI_BIN" ]]; then
            tmp="$(mktemp -d)"
            listings "$tmp"
            diff -r -q "$tmp" "$DST/listings" >&2 || st=1
            rm -rf "$tmp"
        else
            echo "skipping the listings: $REXI_BIN is missing (scripts/fetch-third-party.sh --build)" >&2
        fi
    else
        echo "skipping the comparison with rexi: $REXI is missing (scripts/fetch-third-party.sh)" >&2
    fi
    verify "$DST/interop" || st=1
    [[ $st -eq 0 ]] && echo "fixtures ok"
    exit $st
fi

[[ -d "$REXI" ]] || { echo "missing $REXI; run scripts/fetch-third-party.sh" >&2; exit 1; }
[[ -x "$REXI_BIN" ]] || { echo "missing $REXI_BIN; run scripts/fetch-third-party.sh --build" >&2; exit 1; }
for c in "${COPIES[@]}"; do
    rm -rf "${DST:?}/${c%%:*}"
    mkdir -p "$DST/${c%%:*}"
    cp -a "$REXI/${c#*:}/." "$DST/${c%%:*}/"
done
verify "$DST/interop"
rm -rf "$DST/listings"
listings "$DST/listings"
echo "fixtures copied from $REXI"
