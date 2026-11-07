#!/usr/bin/env bash
# Fetch the third-party sources pinned in third-party.lock into a cache outside
# the working tree.
#
#   scripts/fetch-third-party.sh                 check out every pin (a commit or a tag)
#   scripts/fetch-third-party.sh --build         ... and build exipd, the oracle jar
#                                                and the rexi CLI
#   scripts/fetch-third-party.sh --check         exit 1 unless every checkout is
#                                                present, clean and at its pin
#   scripts/fetch-third-party.sh --update NAME   re-pin NAME to its remote HEAD
#                                                (rewrites that lock line)
#   scripts/fetch-third-party.sh --print-dir     print the cache directory
#
# Env: JEXI_THIRD_PARTY  cache directory
#      (default ${XDG_CACHE_HOME:-$HOME/.cache}/jexi/third_party)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/third-party.lock"
DIR="${JEXI_THIRD_PARTY:-${XDG_CACHE_HOME:-$HOME/.cache}/jexi/third_party}"

MODE=fetch
BUILD=0
UPDATE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD=1 ;;
        --check) MODE=check ;;
        --update) MODE=update; UPDATE="${2:?--update needs a name}"; shift ;;
        --print-dir) echo "$DIR"; exit 0 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v git >/dev/null || { echo "missing required command: git" >&2; exit 1; }
[[ -f "$LOCK" ]] || { echo "missing $LOCK" >&2; exit 1; }

# Lock entries as "name url sha" lines.
entries() { awk '!/^[[:space:]]*(#|$)/ { print $1, $2, $3 }' "$LOCK"; }

dirty() { [[ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]]; }

# A url without a scheme is a local repository, relative to this one.
resolve() { # url
    if [[ "$1" == *://* || "$1" == /* ]]; then echo "$1"; else echo "$ROOT/$1"; fi
}

# A pin is a 40-character commit or a tag name.
is_commit() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# The commit a pin names in the checkout at $1: the pin itself, or the commit of
# the tag as fetched (empty if that tag is not there yet).
pin_commit() { # path pin
    if is_commit "$2"; then
        echo "$2"
    else
        git -C "$1" rev-parse -q --verify "refs/tags/$2^{commit}" || true
    fi
}

checkout() { # name url pin
    local name="$1" url pin="$3" path="$DIR/$1"
    url="$(resolve "$2")"
    if [[ ! -d "$path/.git" ]]; then
        [[ -e "$path" ]] && { echo "$path exists but is not a git checkout" >&2; return 1; }
        mkdir -p "$path"
        git -C "$path" init -q
        git -C "$path" remote add origin "$url"
    fi
    # The lock may have moved the pin to another url.
    git -C "$path" remote set-url origin "$url"
    if dirty "$path"; then
        echo "$name: $path has local changes; refusing to touch it" >&2
        return 1
    fi
    local want
    want="$(pin_commit "$path" "$pin")"
    if [[ -n "$want" && "$(git -C "$path" rev-parse -q --verify HEAD || true)" == "$want" ]]; then
        echo "$name: at $pin"
        return 0
    fi
    echo "$name: fetching $pin"
    if is_commit "$pin"; then
        git -C "$path" fetch -q --depth 1 origin "$pin"
        git -C "$path" checkout -q --detach FETCH_HEAD
    else
        git -C "$path" fetch -q --depth 1 origin "+refs/tags/$pin:refs/tags/$pin"
        git -C "$path" checkout -q --detach "refs/tags/$pin^{commit}"
    fi
}

check() { # name url pin
    local name="$1" pin="$3" path="$DIR/$1"
    if [[ ! -d "$path/.git" ]]; then
        echo "MISSING  $name ($path)" >&2
        return 1
    fi
    local head want
    head="$(git -C "$path" rev-parse -q --verify HEAD || true)"
    want="$(pin_commit "$path" "$pin")"
    if [[ -z "$want" || "$head" != "$want" ]]; then
        echo "MOVED    $name: at ${head:-nothing}, pinned $pin" >&2
        return 1
    fi
    if dirty "$path"; then
        echo "DIRTY    $name" >&2
        return 1
    fi
    if is_commit "$pin"; then
        echo "ok       $name $pin"
    else
        echo "ok       $name $pin (${head:0:12})"
    fi
}

build() {
    local exip="$DIR/exip"
    command -v cmake >/dev/null || { echo "missing required command: cmake" >&2; return 1; }
    echo "building exipd in $exip/build"
    # Older exip code treats warnings as errors; newer compilers surface more.
    cmake -S "$exip" -B "$exip/build" -DCMAKE_C_FLAGS="-Wno-error=type-limits" >/dev/null
    cmake --build "$exip/build" --target exipd
    echo "building the EXIficient oracle (exip utils/xsd2exip)"
    command -v mvn >/dev/null || { echo "missing required command: mvn" >&2; return 1; }
    (cd "$exip/utils/xsd2exip" && mvn -q -DskipTests package)
    echo "building the rexi CLI (release)"
    command -v cargo >/dev/null || { echo "missing required command: cargo" >&2; return 1; }
    cargo build -q --release --manifest-path "$DIR/rexi/Cargo.toml" -p rexi-xml --bin rexi
}

status=0
case "$MODE" in
    check)
        while read -r name url sha; do
            check "$name" "$url" "$sha" || status=1
        done < <(entries)
        exit $status
        ;;
    update)
        line="$(entries | awk -v n="$UPDATE" '$1 == n')"
        [[ -n "$line" ]] || { echo "no lock entry named $UPDATE" >&2; exit 2; }
        read -r name url old <<<"$line"
        new="$(git ls-remote "$(resolve "$url")" HEAD | awk '{ print $1 }')"
        [[ ${#new} -eq 40 ]] || { echo "could not resolve HEAD of $url" >&2; exit 1; }
        awk -v n="$name" -v u="$url" -v s="$new" \
            '$1 == n && !/^[[:space:]]*#/ { print n, u, s; next } { print }' \
            "$LOCK" >"$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
        echo "$name: $old -> $new"
        checkout "$name" "$url" "$new"
        ;;
    fetch)
        mkdir -p "$DIR"
        while read -r name url sha; do
            checkout "$name" "$url" "$sha" || status=1
        done < <(entries)
        ;;
esac

if [[ $BUILD -eq 1 && $status -eq 0 ]]; then
    build || status=1
fi
echo "third-party cache: $DIR"
exit $status
