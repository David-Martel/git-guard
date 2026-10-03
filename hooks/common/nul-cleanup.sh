#!/bin/sh
# Reserved-path hygiene: one physical walk of the active Git worktree.
# Only owned, regular, single-link, zero-byte files may be removed. Foreign Git
# trees, metadata, symlinks, nonempty files and ambiguous changes are preserved.
# Paths travel as find -exec arguments, never newline-delimited shell text.
#
# POSIX has no unlink operation conditional on an unchanged inode/size. Repeated
# no-follow metadata/parent checks detect observed changes but leave a residual
# stat-to-unlink race with an uncooperative concurrent writer. This is NOT
# race-proof. Never run this hook in a concurrently adversarial workspace.
# NUKENUL_BIN is deliberately not executed: its destructive contract is unknown.
# Failures always propagate; NUKENUL_MANDATORY cannot weaken preservation rules.
set -u

# Preserve command-output trailing newlines with a sentinel. Strip exactly the
# command's record delimiter, then refuse newline-bearing roots instead of
# silently resolving a different sibling directory after shell substitution.
capture_path() {
    captured=$("$@" && printf '.') || return 1
    captured=${captured%.}
    case "$captured" in *'
') captured=${captured%?} ;; *) return 1 ;; esac
    case "$captured" in ''|*'
'*) return 1 ;; esac
}

reserved_leaf() {
    leaf=$1
    while :; do
        case "$leaf" in *' '|*.) leaf=${leaf%?} ;; *) break ;; esac
    done
    stem=${leaf%%.*}
    while :; do
        case "$stem" in *' '|*.) stem=${stem%?} ;; *) break ;; esac
    done
    case "$stem" in
        '$'[nN][uU][lL][lL]|[nN][uU][lL]|[cC][oO][nN]|[pP][rR][nN]|[aA][uU][xX]|[cC][oO][mM][1-9]|[lL][pP][tT][1-9]) return 0 ;;
        *) return 1 ;;
    esac
}

signature() {
    if [ "$stat_style" = gnu ]; then stat -c '%d:%i:%f:%s:%h:%u' "$1"
    else stat -f '%d:%i:%p:%z:%l:%u' "$1"
    fi
}

# Recheck EVERY ancestor, not merely the final leaf. A parent symlink or nested
# Git marker makes lexical containment insufficient. Root itself is physical.
owned_parent() {
    parent_identity=
    parent_failure=PRESERVED_SCOPE
    case "$file" in "$root"/*) : ;; *) return 1 ;; esac
    parent=${file%/*}
    while [ "$parent" != "$root" ]; do
        [ -n "$parent" ] && [ "$parent" != / ] || return 1
        if [ -L "$parent" ] || [ ! -d "$parent" ]; then parent_failure=PRESERVED_PARENT_CHANGED; return 1; fi
        case "${parent##*/}" in .git|worktrees|.worktrees) return 1 ;; esac
        [ "$parent" != "$GG_NUL_GIT_DIR" ] && [ "$parent" != "$GG_NUL_GIT_COMMON" ] || return 1
        [ ! -e "$parent/.git" ] && [ ! -L "$parent/.git" ] || return 1
        if [ -f "$parent/HEAD" ] && [ -d "$parent/objects" ] && [ -d "$parent/refs" ]; then return 1; fi
        if ! ancestor=$(signature "$parent"); then parent_failure=ERROR_PARENT_STAT; return 1; fi
        parent_identity="${parent_identity}${ancestor};"
        parent=${parent%/*}
    done
    if [ -L "$root" ] || [ ! -d "$root" ]; then parent_failure=PRESERVED_PARENT_CHANGED; return 1; fi
    if ! ancestor=$(signature "$root"); then parent_failure=ERROR_PARENT_STAT; return 1; fi
    root_identity=${ancestor%:*:*:*:*}
    if [ "$root_identity" != "$GG_NUL_ROOT_IDENTITY" ]; then parent_failure=PRESERVED_ROOT_CHANGED; return 1; fi
    parent_identity="${parent_identity}${ancestor};"
}

failure() {
    printf '%s: %s\n' "$1" "$file" >&2
    : > "$failure_marker" || exit 1
}

# Internal batch worker. Only the parent launches it with its private marker.
if [ "${1:-}" = --check-candidates ]; then
    [ "$#" -ge 5 ] || exit 2
    root=$2; stat_style=$3; failure_marker=$4
    shift 4
    current_uid=$(id -u) || exit 1
    for file do
        reserved_leaf "${file##*/}" || continue
        if ! owned_parent; then
            if [ "$parent_failure" = PRESERVED_SCOPE ]; then printf 'PRESERVED_SCOPE: %s\n' "$file" >&2
            else failure "$parent_failure"
            fi
            continue
        fi
        before_parent_identity=$parent_identity
        if [ -L "$file" ] || [ ! -f "$file" ]; then
            failure PRESERVED_NONREGULAR
            continue
        fi
        if ! before=$(signature "$file"); then
            failure ERROR_STAT
            continue
        fi
        bytes=${before#*:*:*:}; bytes=${bytes%%:*}
        links=${before#*:*:*:*:}; links=${links%%:*}
        owner_uid=${before##*:}
        if [ "$bytes" != 0 ]; then failure PRESERVED_NONEMPTY; continue; fi
        if [ "$links" != 1 ]; then failure PRESERVED_SHARED_IDENTITY; continue; fi
        if [ "$owner_uid" != "$current_uid" ]; then failure PRESERVED_FOREIGN_OWNER; continue; fi
        if ! owned_parent || [ "$parent_identity" != "$before_parent_identity" ] ||
            [ -L "$file" ] || [ ! -f "$file" ] || [ -s "$file" ]; then
            failure PRESERVED_CHANGED
            continue
        fi
        if ! after=$(signature "$file") || [ "$before" != "$after" ]; then
            failure PRESERVED_CHANGED
            continue
        fi
        if ! rm -- "$file"; then failure ERROR_DELETE
        else printf 'REMOVED_ZERO_BYTE: %s\n' "$file" >&2
        fi
    done
    exit 0
fi

if [ "$#" -ne 0 ]; then printf '%s\n' 'ERROR_USAGE: no public arguments accepted' >&2; exit 2; fi
if ! capture_path git rev-parse --show-toplevel 2>/dev/null; then
    printf '%s\n' 'ERROR_ROOT: not in a Git worktree' >&2; exit 1
fi
root=$captured
# Refuse broad or newline-ambiguous roots rather than guessing after Git output.
case "$root" in ''|/|"${HOME:-}"|*'
'*) printf '%s\n' 'ERROR_ROOT: unsafe or ambiguous workspace root' >&2; exit 1 ;; esac
if ! capture_path sh -c 'cd "$1" && pwd -P' sh "$root"; then printf '%s\n' 'ERROR_ROOT: cannot resolve workspace' >&2; exit 1; fi
root=$captured
if ! capture_path git rev-parse --absolute-git-dir; then printf '%s\n' 'ERROR_ROOT: cannot determine Git directory' >&2; exit 1; fi
git_directory=$captured
if ! capture_path git rev-parse --path-format=absolute --git-common-dir; then printf '%s\n' 'ERROR_ROOT: cannot determine common Git directory' >&2; exit 1; fi
git_common_directory=$captured
if ! capture_path sh -c 'cd "$1" && pwd -P' sh "$git_directory"; then printf '%s\n' 'ERROR_ROOT: cannot resolve Git directory' >&2; exit 1; fi
GG_NUL_GIT_DIR=$captured
if ! capture_path sh -c 'cd "$1" && pwd -P' sh "$git_common_directory"; then printf '%s\n' 'ERROR_ROOT: cannot resolve common Git directory' >&2; exit 1; fi
GG_NUL_GIT_COMMON=$captured
export GG_NUL_GIT_DIR GG_NUL_GIT_COMMON
# Escape find's glob interpretation so brackets/star/question marks in real
# metadata paths cannot accidentally broaden or invalidate the pruning boundary.
git_dir_pattern=$(printf '%s' "$GG_NUL_GIT_DIR" | sed 's/[][\\*?]/\\&/g')
git_common_pattern=$(printf '%s' "$GG_NUL_GIT_COMMON" | sed 's/[][\\*?]/\\&/g')
if stat -c '%d:%i:%f:%s:%h' "$root" >/dev/null 2>&1; then stat_style=gnu
elif stat -f '%d:%i:%p:%z:%l' "$root" >/dev/null 2>&1; then stat_style=bsd
else printf '%s\n' 'ERROR_TOOL: compatible no-follow stat unavailable' >&2; exit 1
fi
if ! initial_root=$(signature "$root"); then printf '%s\n' 'ERROR_ROOT: cannot identify workspace' >&2; exit 1; fi
GG_NUL_ROOT_IDENTITY=${initial_root%:*:*:*:*}
export GG_NUL_ROOT_IDENTITY
if ! scratch=$(mktemp -d "${TMPDIR:-/tmp}/git-guard-nul.XXXXXX"); then
    printf '%s\n' 'ERROR_TEMP: cannot create private result directory' >&2; exit 1
fi
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
failure_marker=$scratch/failed
self=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
# GNU/BSD/Git-Bash find default to physical traversal; never add -L. Reserved
# prefixes are a superset; the worker performs exact, suffix-normalized matching.
# Metadata and conventional agent worktree containers are pruned before descent.
inventory_source=${self%/*}/reserved_path_inventory.rs
inventory_native=false
case "$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)" in
    Linux:x86_64|Linux:aarch64)
        if [ -f "$inventory_source" ] && command -v rustc >/dev/null 2>&1; then
            inventory_native=true
        fi
        ;;
esac
if [ "$inventory_native" = true ]; then
    # Compile the bundled, reviewed read-only helper. Never execute an arbitrary
    # external cleanup binary. Complete inventory must succeed before any worker
    # sees candidates; each worker still enforces all ownership/identity gates.
    if ! rustc --edition=2021 -D warnings -O "$inventory_source" -o "$scratch/inventory"; then
        printf '%s\n' 'ERROR_INVENTORY_BUILD: native scan build failed' >&2
        exit 1
    fi
    if ! "$scratch/inventory" "$root" "$GG_NUL_GIT_DIR" "$GG_NUL_GIT_COMMON" > "$scratch/candidates"; then
        printf '%s\n' 'ERROR_TRAVERSAL: native reserved-path inventory failed' >&2
        exit 1
    fi
    if [ -s "$scratch/candidates" ] && ! xargs -0 sh "$self" --check-candidates \
        "$root" "$stat_style" "$failure_marker" < "$scratch/candidates"; then
        printf '%s\n' 'ERROR_WORKER: native inventory candidate worker failed' >&2
        exit 1
    fi
elif ! /usr/bin/find "$root" \
    \( \( -path "$git_dir_pattern" -o -path "$git_common_pattern" -o -name .git \) -prune \) -o \
    \( -type d \( -name worktrees -o -name .worktrees \) -prune \
       -exec printf 'PRESERVED_SCOPE: %s\n' {} \; \) -o \
    \( -type d -exec sh -c '[ "$1" != "$2" ] && { [ -e "$1/.git" ] || [ -L "$1/.git" ] || { [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]; }; }' sh {} "$root" \; \
       -prune -exec printf 'PRESERVED_SCOPE: %s\n' {} \; \) -o \
    \( \( -iname '\$null*' -o -iname 'nul*' -o -iname 'con*' -o -iname 'prn*' -o -iname 'aux*' -o -iname 'com[1-9]*' -o -iname 'lpt[1-9]*' \) \
       -exec sh "$self" --check-candidates "$root" "$stat_style" "$failure_marker" {} + \); then
    printf '%s\n' 'ERROR_TRAVERSAL: reserved-path scan or worker failed' >&2
    exit 1
fi
[ ! -e "$failure_marker" ] || exit 1
exit 0
