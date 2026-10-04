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
# NUKENUL_MANDATORY cannot weaken preservation rules. A preserved path blocks
# the commit only when it is TRACKED or STAGED (it is in the index); untracked
# and ignored content, scan trouble and toolchain trouble only warn. A crashed
# candidate worker blocks only if a reserved path is tracked or staged. Git Bash,
# MSYS and Cygwin are audit-only, and a work tree rooted at / or HOME is skipped.
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

# A preserved path can only reach a commit through the index, so only a path
# that is TRACKED or STAGED blocks (git ls-files reads the index, including the
# GIT_INDEX_FILE of a partial commit). Untracked and ignored content is out of
# scope: it is reported as a warning and never blocks. If git cannot answer,
# treat the path as tracked (fail closed on the one question that matters).
tracked_or_staged() {
    rel=${1#"$root"/}
    [ "$rel" != "$1" ] || return 0
    tracked_list=${failure_marker%/*}/tracked.$$
    git ls-files -z -- ":(top,literal)$rel" > "$tracked_list" 2>/dev/null || return 0
    [ -s "$tracked_list" ]
}

# A worker that cannot finish never evaluated its candidates. Record that in a
# marker distinct from a per-path failure, so the parent can fail closed.
worker_failed() {
    : > "${failure_marker%/*}/worker-failed" 2>/dev/null
    exit 1
}

failure() {
    if tracked_or_staged "$file"; then
        printf '%s: %s\n' "$1" "$file" >&2
        : > "$failure_marker" || worker_failed
    else
        printf '%s (untracked or ignored; warning only): %s\n' "$1" "$file" >&2
    fi
}

# Internal: print every index path that has a reserved-name component and
# touch the marker ($2) when one exists. Used only after a worker crash.
if [ "${1:-}" = --index-reserved ]; then
    [ "$#" -ge 2 ] || exit 2
    reserved_found=$2
    shift 2
    for indexed do
        rest=$indexed
        while [ -n "$rest" ]; do
            component=${rest%%/*}
            if reserved_leaf "$component"; then
                printf 'STAGED_RESERVED: %s\n' "$indexed" >&2
                : > "$reserved_found" || exit 1
                break
            fi
            case "$rest" in */*) rest=${rest#*/} ;; *) rest= ;; esac
        done
    done
    exit 0
fi

# Internal batch worker. Only the parent launches it with its private marker.
if [ "${1:-}" = --check-candidates ]; then
    [ "$#" -ge 5 ] || exit 2
    root=$2; stat_style=$3; failure_marker=$4
    shift 4
    current_uid=$(id -u) || worker_failed
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
        # Git Bash / MSYS / Cygwin run this shell hook too: report only there.
        if [ "${GG_NUL_AUDIT_ONLY:-1}" != 0 ]; then
            printf 'WOULD_REMOVE_ZERO_BYTE (audit-only on this platform): %s\n' "$file" >&2
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
# Refuse newline-ambiguous roots rather than guessing after Git output.
case "$root" in ''|*'
'*) printf '%s\n' 'ERROR_ROOT: unsafe or ambiguous workspace root' >&2; exit 1 ;; esac
if ! capture_path sh -c 'cd "$1" && pwd -P' sh "$root"; then printf '%s\n' 'ERROR_ROOT: cannot resolve workspace' >&2; exit 1; fi
root=$captured
# A repository rooted at / or at HOME (a dotfiles work tree) is too broad to
# walk or clean, but refusing it would lock the repo out of every commit. Skip
# the cleanup there, loudly, and let the commit proceed.
home_root=
if [ -n "${HOME:-}" ] && capture_path sh -c 'cd "$1" && pwd -P' sh "$HOME" 2>/dev/null; then
    home_root=$captured
fi
if [ "$root" = / ] || [ "$root" = "${HOME:-}" ] || { [ -n "$home_root" ] && [ "$root" = "$home_root" ]; }; then
    printf 'SKIPPED_CLEANUP: workspace root %s is / or HOME; reserved-path scan skipped (non-blocking)\n' "$root" >&2
    exit 0
fi
# Windows shells (Git Bash, MSYS2, Cygwin) run this script as well. Deletion is
# qualified only on Linux/macOS, so there it is audit-only: report, never rm.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) GG_NUL_AUDIT_ONLY=1 ;;
    *) GG_NUL_AUDIT_ONLY=0 ;;
esac
[ -z "${MSYSTEM:-}" ] || GG_NUL_AUDIT_ONLY=1
export GG_NUL_AUDIT_ONLY
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
if ! capture_path sh -c 'cd "$1" && pwd -P' sh "$scratch"; then
    printf '%s\n' 'ERROR_TEMP: cannot resolve private result directory' >&2; exit 1
fi
scratch=$captured
failure_marker=$scratch/failed
self=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
# GNU/BSD/Git-Bash find default to physical traversal; never add -L. Reserved
# prefixes are a superset; the worker performs exact, suffix-normalized matching.
# Metadata and conventional agent worktree containers are pruned before descent.
inventory_source=${self%/*}/reserved_path_inventory.rs
inventory_native=false
case "$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)" in
    Linux:x86_64|Linux:aarch64)
        if [ -f "$inventory_source" ] && [ -d /proc/self/fd ] && command -v rustc >/dev/null 2>&1; then
            inventory_native=true
        fi
        ;;
esac
if [ "$inventory_native" = true ]; then
    # Compile the bundled, reviewed read-only helper. Never execute an arbitrary
    # external cleanup binary. Complete inventory must succeed before any worker
    # sees candidates; each worker still enforces all ownership/identity gates.
    # Linux's physical root avoids repository-local rust-toolchain/override
    # ancestry even when TMPDIR is nested in that repository. Keep explicit
    # caller Rustup authority, but never auto-install an unavailable toolchain.
    # Source and output paths are absolute; cd is the shell builtin.
    # Toolchain trouble must never block a commit: the hook's runtime build caps
    # lints at warn (CI compiles the same source with -D warnings), and a failed
    # build or run falls back to the POSIX scan below, with a visible warning.
    # A failed run's partial output is discarded, never dispatched.
    if ! (cd / && RUSTUP_AUTO_INSTALL=0 rustc --edition=2021 --cap-lints warn -O "$inventory_source" -o "$scratch/inventory") 2>"$scratch/build.log"; then
        cat "$scratch/build.log" >&2
        printf '%s\n' 'WARN_INVENTORY_BUILD: native scan build failed; falling back to the POSIX scan (non-blocking)' >&2
        inventory_native=false
    elif ! "$scratch/inventory" "$root" "$GG_NUL_GIT_DIR" "$GG_NUL_GIT_COMMON" > "$scratch/candidates"; then
        rm -f -- "$scratch/candidates"
        printf '%s\n' 'WARN_INVENTORY_RUN: native reserved-path inventory failed; falling back to the POSIX scan (non-blocking)' >&2
        inventory_native=false
    fi
fi
if [ "$inventory_native" = true ]; then
    if [ -s "$scratch/candidates" ] && ! xargs -0 sh "$self" --check-candidates \
        "$root" "$stat_style" "$failure_marker" < "$scratch/candidates"; then
        : > "$scratch/worker-failed"
    fi
elif ! /usr/bin/find "$root" \
    \( \( -path "$git_dir_pattern" -o -path "$git_common_pattern" -o -name .git \) -prune \) -o \
    \( -type d \( -name worktrees -o -name .worktrees \) -prune \
       -exec printf 'PRESERVED_SCOPE: %s\n' {} \; \) -o \
    \( -type d -exec sh -c '[ "$1" != "$2" ] && { [ -e "$1/.git" ] || [ -L "$1/.git" ] || { [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]; }; }' sh {} "$root" \; \
       -prune -exec printf 'PRESERVED_SCOPE: %s\n' {} \; \) -o \
    \( \( -iname '\$null*' -o -iname 'nul*' -o -iname 'con*' -o -iname 'prn*' -o -iname 'aux*' -o -iname 'com[1-9]*' -o -iname 'lpt[1-9]*' \) \
       -exec sh "$self" --check-candidates "$root" "$stat_style" "$failure_marker" {} + \); then
    # An unreadable or vanished entry anywhere in the work tree (often ignored
    # build output) makes find exit nonzero. That is not a reason to block a
    # commit: every candidate it did reach was still fully checked.
    [ -e "$scratch/worker-failed" ] ||
        printf '%s\n' 'WARN_TRAVERSAL: reserved-path scan incomplete (unreadable or vanished entries); non-blocking' >&2
fi
# A crashed worker left candidates unevaluated. Fail CLOSED if any reserved
# path is tracked or staged (it could reach this commit); otherwise only warn.
if [ -e "$scratch/worker-failed" ]; then
    if ! git ls-files -z > "$scratch/index" ||
        ! xargs -0 sh "$self" --index-reserved "$scratch/index-reserved" < "$scratch/index" ||
        [ -e "$scratch/index-reserved" ]; then
        printf '%s\n' 'ERROR_WORKER: reserved-path candidate worker failed and a reserved path is tracked or staged (or the index could not be read)' >&2
        exit 1
    fi
    printf '%s\n' 'WARN_WORKER: reserved-path candidate worker failed; no reserved path is tracked or staged (non-blocking)' >&2
fi
[ ! -e "$failure_marker" ] || exit 1
exit 0
