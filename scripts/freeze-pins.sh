#!/usr/bin/env bash
#
# Rewrite `rev: <sha>  # frozen: <tag>` pins in a pre-commit config to the
# commit the tag peels to.
#
# `pre-commit autoupdate --freeze` pins whatever `git ls-remote <repo> <tag>`
# returns. For an annotated tag that SHA is the tag object, not the commit.
# Renovate reads the `# frozen: <tag>` comment, resolves the tag to the commit,
# and compares it with the pin; the mismatch makes it open a no-op
# "Update ... digest" PR on every scheduled run. Pinning the commit keeps both
# sides in agreement and keeps the release tag in the comment.
#
# Exit codes: 0 ok, 1 drift found (--check), 2 usage or resolution error.

set -uo pipefail

CONFIG=".pre-commit-config.yaml"
MODE="write"

usage() {
    cat <<'EOF'
Rewrite `rev: <sha>  # frozen: <tag>` pins to the commit the tag peels to.

Usage:
  scripts/freeze-pins.sh                    # rewrite .pre-commit-config.yaml
  scripts/freeze-pins.sh --check            # report drift, exit 1 if any
  scripts/freeze-pins.sh --file <path>      # operate on another config
  scripts/freeze-pins.sh --check --file <p>

Exit codes: 0 ok, 1 drift found (--check), 2 usage or resolution error.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --file)
            [ $# -ge 2 ] || { echo "ERROR: --file needs a path" >&2; exit 2; }
            CONFIG="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -f "$CONFIG" ] || { echo "ERROR: no such file: $CONFIG" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 2; }

workdir=$(mktemp -d) || exit 2
trap 'rm -rf "$workdir"' EXIT
pins="$workdir/pins"
resolved="$workdir/resolved"
changes="$workdir/changes"
: >"$resolved"
: >"$changes"

# Emit "repo<TAB>tag<TAB>sha" once per frozen SHA pin.
awk '
    {
        line = $0
        if (match(line, /^[[:space:]]*-[[:space:]]*repo:[[:space:]]*[^[:space:]#]+/)) {
            repo = substr(line, RSTART, RLENGTH)
            sub(/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/, "", repo)
        }
        if (repo != "" && match(line, /^[[:space:]]*rev:[[:space:]]*[0-9a-fA-F]+[[:space:]]*#[[:space:]]*frozen:[[:space:]]*[^[:space:]]+/)) {
            pin = substr(line, RSTART, RLENGTH)
            sha = pin
            sub(/^[[:space:]]*rev:[[:space:]]*/, "", sha)
            sub(/[[:space:]]*#.*/, "", sha)
            tag = pin
            sub(/.*frozen:[[:space:]]*/, "", tag)
            if (length(sha) == 40) {
                printf "%s\t%s\t%s\n", repo, tag, sha
            }
        }
    }
' "$CONFIG" >"$pins"

# Print the commit the tag peels to; empty when the tag cannot be resolved.
resolve_commit() {
    local repo="$1" tag="$2" sha
    sha=$(git ls-remote --tags "$repo" "refs/tags/${tag}^{}" 2>/dev/null | awk 'NR==1 {print $1}')
    if [ -n "$sha" ]; then
        printf '%s\n' "$sha"
        return 0
    fi
    git ls-remote --tags "$repo" "refs/tags/${tag}" 2>/dev/null | awk 'NR==1 {print $1}'
}

drift=0
unresolved=0

while IFS=$'\t' read -r repo tag sha; do
    [ -n "${repo:-}" ] || continue
    commit=$(resolve_commit "$repo" "$tag")
    if [ -z "$commit" ]; then
        echo "WARN: cannot resolve ${tag} in ${repo}; leaving ${sha} untouched" >&2
        unresolved=1
        continue
    fi
    [ "$commit" = "$sha" ] || drift=1
    printf '%s\t%s\t%s\t%s\n' "$repo" "$tag" "$sha" "$commit" >>"$resolved"
done <"$pins"

if [ "$drift" -eq 0 ]; then
    [ "$MODE" = "check" ] && echo "${CONFIG}: all pins point at commits"
    [ "$MODE" = "write" ] && echo "${CONFIG}: all pins point at commits, nothing to do"
    [ "$unresolved" -eq 0 ] || exit 2
    exit 0
fi

while IFS=$'\t' read -r repo tag sha commit; do
    [ "$sha" = "$commit" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$repo" "$tag" "$sha" "$commit" >>"$changes"
done <"$resolved"

if [ "$MODE" = "check" ]; then
    while IFS=$'\t' read -r repo tag sha commit; do
        echo "${CONFIG}: ${repo} ${tag} is pinned to ${sha} (tag object), commit is ${commit}"
    done <"$changes"
    echo "ERROR: repin with 'pre-commit autoupdate --freeze && scripts/freeze-pins.sh'" >&2
    [ "$unresolved" -eq 0 ] || exit 2
    exit 1
fi

# Rewrite only the rev lines whose repo, tag and current SHA match a change.
awk -v changes="$changes" '
    BEGIN {
        FS = "\t"
        while ((getline line < changes) > 0) {
            split(line, field, "\t")
            map[field[1] "|" field[2] "|" field[3]] = field[4]
        }
    }
    {
        line = $0
        if (match(line, /^[[:space:]]*-[[:space:]]*repo:[[:space:]]*[^[:space:]#]+/)) {
            repo = substr(line, RSTART, RLENGTH)
            sub(/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/, "", repo)
        }
        if (repo != "" && match(line, /^[[:space:]]*rev:[[:space:]]*[0-9a-fA-F]+[[:space:]]*#[[:space:]]*frozen:[[:space:]]*[^[:space:]]+/)) {
            pin = substr(line, RSTART, RLENGTH)
            sha = pin
            sub(/^[[:space:]]*rev:[[:space:]]*/, "", sha)
            sub(/[[:space:]]*#.*/, "", sha)
            tag = pin
            sub(/.*frozen:[[:space:]]*/, "", tag)
            key = repo "|" tag "|" sha
            if (key in map) {
                sub(sha, map[key], line)
                print line
                next
            }
        }
        print line
    }
' "$CONFIG" >"$workdir/config.new" || { echo "ERROR: rewrite failed" >&2; exit 2; }

while IFS=$'\t' read -r repo tag sha commit; do
    echo "normalized ${tag} (${repo}): ${sha:0:12} -> ${commit:0:12}"
done <"$changes"

mv "$workdir/config.new" "$CONFIG"

"$0" --check --file "$CONFIG" >/dev/null 2>&1
verify=$?
case "$verify" in
    0) ;;
    1)
        echo "ERROR: ${CONFIG} still has non-commit pins after the rewrite" >&2
        exit 2
        ;;
    2) echo "WARN: some pins could not be verified, review the warnings above" >&2 ;;
    *)
        echo "ERROR: verification of ${CONFIG} failed (exit ${verify})" >&2
        exit 2
        ;;
esac

if command -v pre-commit >/dev/null 2>&1; then
    pre-commit validate-config "$CONFIG" || {
        echo "ERROR: ${CONFIG} is not a valid pre-commit config" >&2
        exit 2
    }
fi

[ "$unresolved" -eq 0 ] || exit 2
exit 0
