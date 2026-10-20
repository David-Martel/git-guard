#!/bin/sh
# Dispatch the declared pre-commit framework, preserving Git hook arguments.
# Only this new provider refuses unsupported pushed-source/workspace bindings.
set -u

stage="$1"; shift
root="$(git rev-parse --show-toplevel)" || exit 1
# Match the directory passed by generated pre-commit hooks, pinned to this
# dispatcher's release. Older frameworks require it for their legacy-hook path.
hook_dir="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
config="$root/.pre-commit-config.yaml"
if [ ! -e "$config" ] && [ ! -L "$config" ] &&
   { [ -e "$root/.pre-commit-config.yml" ] || [ -L "$root/.pre-commit-config.yml" ]; }; then
  config="$root/.pre-commit-config.yml"
fi
[ -f "$config" ] || {
  printf '%s\n' 'git-guard BLOCK: declared pre-commit configuration is missing or not a file.' >&2
  exit 1
}

refs=""
source_index=""
trap '[ -z "$refs" ] || rm -f "$refs"; [ -z "$source_index" ] || rm -f "$source_index" "$source_index.lock"' EXIT
if [ "$stage" = pre-push ]; then
  if [ -L "$config" ]; then
    printf '%s\n' 'git-guard BLOCK: pre-commit pre-push requires a regular non-symlink configuration bound to the pushed HEAD.' >&2
    exit 1
  fi
  refs="$(mktemp "${TMPDIR:-/tmp}/git-guard-precommit.XXXXXX")" || exit 1
  cat > "$refs" || exit 1
  head="$(git rev-parse --verify HEAD)" || exit 1
  updates=0
  admitted_record=""
  while read -r local_ref local_sha remote_ref remote_sha extra; do
    [ -n "${local_ref}${local_sha}${remote_ref}${remote_sha}${extra}" ] || continue
    if [ -n "$extra" ] || [ -z "$remote_sha" ]; then
      printf '%s\n' 'git-guard BLOCK: malformed pre-commit pre-push update record.' >&2
      exit 1
    fi
    if { [ "${#local_sha}" -ne 40 ] && [ "${#local_sha}" -ne 64 ]; } ||
       { [ "${#remote_sha}" -ne 40 ] && [ "${#remote_sha}" -ne 64 ]; }; then
      printf '%s\n' 'git-guard BLOCK: invalid pre-commit pre-push object identity.' >&2
      exit 1
    fi
    case "$local_sha$remote_sha" in
      *[!0-9a-f]*) printf '%s\n' 'git-guard BLOCK: invalid pre-commit pre-push object identity.' >&2; exit 1 ;;
    esac
    case "$local_sha" in *[!0]*) : ;; *) continue ;; esac
    # Tags identify their commit, not the annotated tag object itself.
    commit="$(git rev-parse --verify "$local_sha^{commit}" 2>/dev/null)" || {
      printf '%s\n' 'git-guard BLOCK: pre-commit provider requires a pushed commit.' >&2
      exit 1
    }
    remote_commit="$(git rev-parse --verify "$remote_sha^{commit}" 2>/dev/null)" || remote_commit=""
    [ "$commit" != "$remote_commit" ] || continue
    updates=$((updates + 1))
    if [ "$commit" != "$head" ] || [ "$updates" -gt 1 ]; then
      printf '%s\n' 'git-guard BLOCK: pre-commit provider supports one changed update at current HEAD; publish other heads separately from their own checkout.' >&2
      exit 1
    fi
    admitted_record="$local_ref $local_sha $remote_ref $remote_sha"
  done < "$refs"
  # Deletions and unchanged sources do not execute software QA.
  [ "$updates" -ne 0 ] || exit 0
  # Parent comparisons do not seal a submodule's own index and tracked bytes.
  tree_modes="$(git ls-tree -r --format='%(objectmode)' "$head")" || exit 1
  if printf '%s\n' "$tree_modes" | grep -qx 160000; then
    printf '%s\n' 'git-guard BLOCK: pre-commit pre-push needs a clean tracked HEAD workspace; submodule-backed source is unsupported until recursively validated; use an explicit repository gate that qualifies immutable snapshots.' >&2
    exit 1
  fi
  # The framework selects its first eligible input record. Replaying unchanged
  # annotated-tag rewrites would let an empty diff conceal the changed release.
  # Keep the admitted record's original object identities and remote ref names.
  printf '%s\n' "$admitted_record" > "$refs" || exit 1
  # A live index can hide actual modifications under assume-unchanged or
  # skip-worktree. Compare through a private HEAD index with neither flag: Git
  # retains its normal attributes/clean-filter, symlink, mode and gitlink
  # semantics, while the user's index and optimization flags remain untouched.
  source_index="$(mktemp "${TMPDIR:-/tmp}/git-guard-source-index.XXXXXX")" || exit 1
  # Keep the live staged-source gate as well: a restored HEAD worktree can
  # otherwise conceal a different staged blob that would be committed next.
  if ! git diff --cached --quiet --ignore-submodules=none "$head" -- ||
     ! GIT_INDEX_FILE="$source_index" git read-tree "$head" ||
     ! GIT_INDEX_FILE="$source_index" git diff --quiet --ignore-submodules=none "$head" --; then
    printf '%s\n' 'git-guard BLOCK: pre-commit pre-push needs a clean tracked HEAD workspace; staged or unstaged changes are not the pushed source.' >&2
    exit 1
  fi
  config_kind="$(git ls-tree "$head" -- "${config##*/}" | awk '{print $1 " " $2}')"
  case "$config_kind" in '100644 blob'|'100755 blob') : ;; *)
    printf '%s\n' 'git-guard BLOCK: pre-commit configuration must belong to the pushed HEAD.' >&2
    exit 1
  ;; esac
fi

provider="$(command -v pre-commit 2>/dev/null)" || provider=""
if [ ! -f "$provider" ] || [ ! -x "$provider" ]; then
  printf '%s\n' 'git-guard BLOCK: this repo declares pre-commit configuration but pre-commit is not runnable; install the declared provider before publishing.' >&2
  exit 1
fi
# hook-impl is the framework backend used by its generated Git hooks. It
# translates remote argv/admitted ref stdin and retains stage filtering.
if [ "$stage" = pre-push ]; then
  "$provider" hook-impl --config "$config" --hook-type "$stage" --hook-dir "$hook_dir" -- "$@" < "$refs"
else
  "$provider" hook-impl --config "$config" --hook-type "$stage" --hook-dir "$hook_dir" -- "$@"
fi
