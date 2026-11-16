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
# Exit codes: 0 ok, 1 drift found (--check), 2 usage, resolution or
# verification error.

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

Exit codes: 0 ok, 1 drift found (--check), 2 usage, resolution or
verification error.
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

# awks share the same view of a pinned revision: `rev: <sha>  # frozen: <tag>`,
# where the SHA may be quoted. REV matches a parsable 40-hex pin, LOOSE catches
# any rev carrying a frozen comment so an unparsable one is reported, not
# skipped.
AWK_QUOTES='
    BEGIN {
        quote = "[\"" sq "]"
        optional = quote "?"
        rev = "^[[:space:]]*rev:[[:space:]]*" optional "[0-9a-fA-F]+" optional \
              "[[:space:]]*#[[:space:]]*frozen:[[:space:]]*[^[:space:]]+"
        loose = "^[[:space:]]*rev:.*#[[:space:]]*frozen:"
    }
'

# Emit "OK<TAB>repo<TAB>tag<TAB>sha" per parsable pin and
# "BAD<TAB>repo<TAB>raw line" per frozen revision that cannot be parsed.
awk -v sq="'" "$AWK_QUOTES"'
    {
        if (match($0, /^[[:space:]]*-[[:space:]]*repo:[[:space:]]*[^[:space:]#]+/)) {
            repo = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/, "", repo)
        }
        if (match($0, rev)) {
            pin = substr($0, RSTART, RLENGTH)
            sha = pin
            sub(/^[[:space:]]*rev:[[:space:]]*/, "", sha)
            sub(/[[:space:]]*#.*/, "", sha)
            gsub(quote, "", sha)
            tag = pin
            sub(/.*frozen:[[:space:]]*/, "", tag)
            if (repo != "" && length(sha) == 40) {
                printf "OK\t%s\t%s\t%s\n", repo, tag, sha
            } else {
                printf "BAD\t%s\t%s\n", repo, $0
            }
            next
        }
        if (match($0, loose)) {
            printf "BAD\t%s\t%s\n", repo, $0
        }
    }
' "$CONFIG" >"$pins"

# Print the commit the tag peels to. Fetches the tag ref and its peeled ref in
# one request, and only falls back to the unpeeled ref when that successful
# response carries no peeled entry: a failed request is an error, not a
# lightweight tag.
resolve_commit() {
    local repo="$1" tag="$2" out
    out=$(git ls-remote --tags -- "$repo" "refs/tags/${tag}" "refs/tags/${tag}^{}") || return 1
    printf '%s\n' "$out" | awk -v base="refs/tags/${tag}" '
        $2 == base "^{}" { peeled = $1 }
        $2 == base { unpeeled = $1 }
        END {
            if (peeled != "") print peeled
            else if (unpeeled != "") print unpeeled
        }'
}

drift=0
unresolved=0
unparsable=0

while IFS=$'\t' read -r kind repo rest; do
    case "$kind" in
        BAD)
            echo "ERROR: cannot parse the frozen revision at ${CONFIG}: ${rest}" >&2
            unparsable=1
            ;;
        OK)
            tag="${rest%%$'\t'*}"
            sha="${rest#*$'\t'}"
            case "$repo" in
                -*)
                    echo "ERROR: refusing an option-like repository at ${CONFIG}: ${repo}" >&2
                    unparsable=1
                    continue
                    ;;
            esac
            if ! commit=$(resolve_commit "$repo" "$tag"); then
                echo "WARN: git ls-remote failed for ${repo}; leaving ${sha} untouched" >&2
                unresolved=1
                continue
            fi
            if [ -z "$commit" ]; then
                echo "WARN: cannot resolve ${tag} in ${repo}; leaving ${sha} untouched" >&2
                unresolved=1
                continue
            fi
            [ "$commit" = "$sha" ] || drift=1
            printf '%s\t%s\t%s\t%s\n' "$repo" "$tag" "$sha" "$commit" >>"$resolved"
            ;;
    esac
done <"$pins"

if [ "$unparsable" -ne 0 ]; then
    echo "ERROR: fix the revisions above before repinning; nothing was changed" >&2
    exit 2
fi

if [ "$drift" -eq 0 ]; then
    if [ "$unresolved" -ne 0 ]; then
        echo "WARN: ${CONFIG}: no drift among the pins that could be read, but some could not be verified" >&2
        exit 2
    fi
    [ "$MODE" = "check" ] && echo "${CONFIG}: all pins point at commits"
    [ "$MODE" = "write" ] && echo "${CONFIG}: all pins point at commits, nothing to do"
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
awk -v sq="'" -v changes="$changes" "$AWK_QUOTES"'
    BEGIN {
        FS = "\t"
        while ((getline line < changes) > 0) {
            split(line, field, "\t")
            map[field[1] "|" field[2] "|" field[3]] = field[4]
        }
    }
    {
        if (match($0, /^[[:space:]]*-[[:space:]]*repo:[[:space:]]*[^[:space:]#]+/)) {
            repo = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/, "", repo)
        }
        if (match($0, rev)) {
            pin = substr($0, RSTART, RLENGTH)
            sha = pin
            sub(/^[[:space:]]*rev:[[:space:]]*/, "", sha)
            sub(/[[:space:]]*#.*/, "", sha)
            gsub(quote, "", sha)
            tag = pin
            sub(/.*frozen:[[:space:]]*/, "", tag)
            key = repo "|" tag "|" sha
            if (repo != "" && (key in map)) {
                line = $0
                sub(sha, map[key], line)
                print line
                next
            }
        }
        print
    }
' "$CONFIG" >"$workdir/config.yaml" || { echo "ERROR: rewrite failed" >&2; exit 2; }

# Verify the rewritten file before it replaces the original.
"$0" --check --file "$workdir/config.yaml" >/dev/null 2>&1
verify=$?
case "$verify" in
    0) ;;
    1)
        echo "ERROR: the rewrite left non-commit pins in ${CONFIG}; nothing changed" >&2
        exit 2
        ;;
    2)
        echo "WARN: some pins could not be verified, review the warnings above" >&2
        unresolved=1
        ;;
    *)
        echo "ERROR: verification of the rewrite failed (exit ${verify})" >&2
        exit 2
        ;;
esac

if command -v pre-commit >/dev/null 2>&1; then
    pre-commit validate-config "$workdir/config.yaml" || {
        echo "ERROR: the rewrite does not produce a valid pre-commit config; nothing changed" >&2
        exit 2
    }
fi

if ! mv "$workdir/config.yaml" "$CONFIG"; then
    echo "ERROR: could not replace ${CONFIG}; it was left unchanged" >&2
    exit 2
fi

while IFS=$'\t' read -r repo tag sha commit; do
    echo "normalized ${tag} (${repo}): ${sha:0:12} -> ${commit:0:12}"
done <"$changes"

[ "$unresolved" -eq 0 ] || exit 2
exit 0
