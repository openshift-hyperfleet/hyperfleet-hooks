#!/usr/bin/env bash
#
# Offline tests for scripts/freeze-pins.sh. `git` is stubbed from a fixture
# table, so nothing here touches the network.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")/.." && pwd)
subject="$script_dir/freeze-pins.sh"
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
# Stub for `git ls-remote --tags <repo> <ref> [<ref> ...]`.
# Fixture lines are "<repo>\t<ref>\t<sha>"; repos marked "invalid" fail.
repo=""
refs=()
for arg in "$@"; do
    case "$arg" in
        ls-remote|--tags) ;;
        *)
            if [ -z "$repo" ]; then
                repo="$arg"
            else
                refs[${#refs[@]}]="$arg"
            fi
            ;;
    esac
done
case "$repo" in
    *invalid*)
        echo "fatal: unable to access '$repo'" >&2
        exit 128
        ;;
esac
for ref in ${refs[@]+"${refs[@]}"}; do
    while IFS=$'\t' read -r frepo fref fsha; do
        [ "$frepo" = "$repo" ] || continue
        [ "$fref" = "$ref" ] || continue
        printf '%s\t%s\n' "$fsha" "$fref"
    done <"${GIT_FIXTURE:?GIT_FIXTURE is not set}"
done
exit 0
STUB
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"

repeat() {
    local count="$1" char="$2" out="" i=0
    while [ "$i" -lt "$count" ]; do
        out="${out}${char}"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# Fake SHAs carry a letter: a purely numeric 40-character rev is parsed as an
# integer by YAML, which pre-commit rejects as "Expected string got int".
TAG_OBJECT="a$(repeat 39 1)"
COMMIT="b$(repeat 39 2)"
LIGHT_TAG="c$(repeat 39 3)"
for sha in "$TAG_OBJECT" "$COMMIT" "$LIGHT_TAG"; do
    [ "${#sha}" -eq 40 ] || { echo "bad test fixture SHA: ${sha}" >&2; exit 2; }
done

export GIT_FIXTURE="$tmp/fixture"
{
    printf 'https://example.test/annotated\trefs/tags/v1.0.0\t%s\n' "$TAG_OBJECT"
    printf 'https://example.test/annotated\trefs/tags/v1.0.0^{}\t%s\n' "$COMMIT"
    printf 'https://example.test/light\trefs/tags/v2.0.0\t%s\n' "$LIGHT_TAG"
} >"$GIT_FIXTURE"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() {
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
}

# config <path> <repo> <rev> <frozen tag>
config() {
    cat >"$1" <<EOF
repos:
  - repo: $2
    rev: $3  # frozen: $4
    hooks:
      - id: example
EOF
}

run() { "$subject" "$@" >"$tmp/out" 2>"$tmp/err"; }

# assert_status <expected exit> <description> <script args...>
assert_status() {
    local expected="$1" desc="$2" rc
    shift 2
    run "$@"
    rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (exit ${rc}, want ${expected})"
        sed 's/^/    /' "$tmp/err" >&2
    fi
}

# assert_grep <pattern> <file> <description>
assert_grep() {
    if grep -q -- "$1" "$2"; then
        pass "$3"
    else
        fail "$3"
    fi
}

# assert_same <file a> <file b> <description>
assert_same() {
    if cmp -s "$1" "$2"; then
        pass "$3"
    else
        fail "$3"
    fi
}

echo "== an annotated tag object is repinned to its commit =="
config "$tmp/annotated.yaml" https://example.test/annotated "$TAG_OBJECT" v1.0.0
assert_status 1 "check exits 1 on drift" --check --file "$tmp/annotated.yaml"
assert_grep "${TAG_OBJECT}.*tag object" "$tmp/out" "check names the tag object"
assert_status 0 "write exits 0" --file "$tmp/annotated.yaml"
assert_grep "rev: ${COMMIT}" "$tmp/annotated.yaml" "pin holds the commit"
assert_grep "# frozen: v1.0.0" "$tmp/annotated.yaml" "release comment survives"

echo "== a second run is a no-op =="
cp "$tmp/annotated.yaml" "$tmp/annotated.before"
assert_status 0 "write exits 0" --file "$tmp/annotated.yaml"
assert_same "$tmp/annotated.yaml" "$tmp/annotated.before" "file unchanged"

echo "== a lightweight tag resolves to the same commit =="
config "$tmp/light.yaml" https://example.test/light "$LIGHT_TAG" v2.0.0
assert_status 0 "write exits 0" --file "$tmp/light.yaml"
assert_grep "rev: ${LIGHT_TAG}" "$tmp/light.yaml" "pin untouched"

echo "== quoted revisions are parsed and keep their quotes =="
config "$tmp/quoted.yaml" https://example.test/annotated "'${TAG_OBJECT}'" v1.0.0
assert_status 0 "write exits 0" --file "$tmp/quoted.yaml"
assert_grep "rev: '${COMMIT}'" "$tmp/quoted.yaml" "quoted pin rewritten"

echo "== an unparsable frozen revision is an error, not a silent skip =="
config "$tmp/broken.yaml" https://example.test/annotated "a1111" v1.0.0
cp "$tmp/broken.yaml" "$tmp/broken.before"
assert_status 2 "exits 2" --file "$tmp/broken.yaml"
assert_grep "cannot parse the frozen revision" "$tmp/err" "reports the bad revision"
assert_same "$tmp/broken.yaml" "$tmp/broken.before" "file unchanged"

echo "== a failed lookup is not read as a lightweight tag =="
config "$tmp/unreachable.yaml" https://example.test/invalid "$TAG_OBJECT" v1.0.0
cp "$tmp/unreachable.yaml" "$tmp/unreachable.before"
assert_status 2 "exits 2" --file "$tmp/unreachable.yaml"
assert_grep "git ls-remote failed" "$tmp/err" "reports the failed lookup"
assert_same "$tmp/unreachable.yaml" "$tmp/unreachable.before" "file unchanged"

echo "== local entries and tag-style revisions are ignored =="
cat >"$tmp/mixed.yaml" <<EOF
repos:
  - repo: https://example.test/annotated
    rev: $TAG_OBJECT  # frozen: v1.0.0
    hooks:
      - id: example
  - repo: local
    hooks:
      - id: local-hook
        name: local hook
        entry: "true"
        language: system
  - repo: https://example.test/light
    rev: v2.0.0
    hooks:
      - id: example
EOF
assert_status 0 "write exits 0" --file "$tmp/mixed.yaml"
assert_grep "repo: local" "$tmp/mixed.yaml" "local entry kept"
assert_grep "rev: v2.0.0" "$tmp/mixed.yaml" "tag-style revision kept"

echo
if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
