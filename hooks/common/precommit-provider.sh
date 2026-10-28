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

submodule_block() {
  printf 'git-guard BLOCK: pre-commit pre-push submodule %s\n' "$1" >&2
  exit 1
}

# Qualify every gitlink of commit $2 in worktree $1 against its checkout, then
# recurse into nested gitlinks. $3 prefixes displayed paths; $4 is the depth.
# The subshell body keeps each level's variables and traps private.
validate_gitlinks() (
  repo="$1"; commit="$2"; prefix="$3"; depth="$4"
  if [ "$depth" -ge 16 ]; then
    submodule_block "nesting under '${prefix%/}' exceeds 16 levels; use an explicit repository gate that qualifies immutable snapshots."
  fi
  cd "$repo" || submodule_block "worktree '${prefix%/}' is unreadable."
  links="$(git -c core.quotePath=false ls-tree -r --format='%(objectmode) %(objectname) %(path)' "$commit")" ||
    submodule_block "listing for '${prefix:-.}' failed at $commit."
  while IFS= read -r line; do
    [ "${line%% *}" = 160000 ] || continue
    rest="${line#* }"; sha="${rest%% *}"; path="${rest#* }"; shown="$prefix$path"
    case "$path" in \"*)
      submodule_block "path $path needs quoting; rename it or use an explicit repository gate."
    ;; esac
    sub="$repo/$path"
    if [ ! -e "$sub/.git" ] && [ ! -L "$sub/.git" ]; then
      if [ -L "$sub" ] || [ ! -d "$sub" ]; then
        submodule_block "'$shown' is missing or not a directory; restore it with: git submodule update --init --recursive"
      fi
      for entry in "$sub"/* "$sub"/.[!.]* "$sub"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
          submodule_block "'$shown' is not initialized but its directory has content; initialize it with git submodule update --init --recursive, or remove the stray files."
        fi
      done
      # QA tools see only the recorded commit id, never the dependency's bytes.
      printf "git-guard: submodule '%s' is not checked out; QA sees only its recorded commit %s, and its own repository's gates qualify its content.\n" "$shown" "$sha" >&2
      continue
    fi
    (
      # Git exports repository variables to hooks; they would bind every
      # command below to the parent instead of the submodule.
      # shellcheck disable=SC2046  # one variable name per word is intended
      unset $(git rev-parse --local-env-vars)
      cd "$sub" || submodule_block "'$shown' is unreadable."
      # An empty or foreign .git lets discovery climb into the parent.
      if ! cdup="$(git rev-parse --show-cdup 2>&1)"; then
        # Name Git's reason: dubious ownership needs a different fix than a broken gitdir.
        submodule_block "'$shown' has a .git entry that is not a readable repository at that path (git: $(printf '%s\n' "$cdup" | sed -n 1p)); repair it with: git submodule update --init --recursive, or fix the repository's ownership or safe.directory."
      fi
      [ -z "$cdup" ] ||
        submodule_block "'$shown' has a .git entry that is not a readable repository at that path; repair it with: git submodule update --init --recursive"
      actual="$(git rev-parse -q --verify HEAD 2>/dev/null)" || actual=""
      if [ "$actual" != "$sha" ]; then
        submodule_block "'$shown' is checked out at ${actual:-an unborn HEAD}, but the pushed HEAD records $sha; run: git submodule update --init --recursive (or commit the new gitlink)."
      fi
      for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        state_path="$(git rev-parse --git-path "$state")" || submodule_block "'$shown' state is unreadable."
        if [ -e "$state_path" ]; then
          submodule_block "'$shown' has an in-progress operation ($state); finish or abort it before publishing."
        fi
      done
      # Same private-index comparison as the parent: assume-unchanged and
      # skip-worktree flags in the submodule's own index cannot hide edits.
      # Nested gitlinks are qualified by the recursion below, not here.
      sub_index="$(mktemp "${TMPDIR:-/tmp}/git-guard-submodule-index.XXXXXX")" || submodule_block "'$shown' index copy failed."
      trap 'rm -f "$sub_index" "$sub_index.lock"' EXIT
      if ! git diff --cached --quiet --ignore-submodules=dirty "$sha" -- ||
         ! GIT_INDEX_FILE="$sub_index" git read-tree "$sha" ||
         ! GIT_INDEX_FILE="$sub_index" git diff --quiet --ignore-submodules=all "$sha" --; then
        submodule_block "'$shown' has staged or unstaged tracked changes against $sha (including any hidden by assume-unchanged or skip-worktree); commit them and record the gitlink, or restore them."
      fi
      validate_gitlinks "$sub" "$sha" "$shown/" $((depth + 1))
    ) || exit 1
  done <<EOF
$links
EOF
)

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
  # Parent comparisons do not seal a submodule's own index and tracked bytes,
  # so each gitlink is validated recursively in its own repository first.
  # `refuse` restores the former blanket refusal; an unknown value refuses.
  submodule_policy="${GIT_GUARD_PRECOMMIT_SUBMODULES:-}"
  [ -n "$submodule_policy" ] ||
    submodule_policy="$(git config --get gitGuard.precommitSubmodules 2>/dev/null)" || submodule_policy=validate
  if [ "$submodule_policy" != validate ]; then
    tree_modes="$(git ls-tree -r --format='%(objectmode)' "$head")" || exit 1
    if printf '%s\n' "$tree_modes" | grep -qx 160000; then
      printf 'git-guard BLOCK: pre-commit pre-push submodule policy is %s, so submodule-backed source is refused; use an explicit repository gate that qualifies immutable snapshots, or set gitGuard.precommitSubmodules=validate.\n' "$submodule_policy" >&2
      exit 1
    fi
  fi
  validate_gitlinks "$root" "$head" "" 0 || exit 1
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
  # Untracked files are not sealed in the parent; the same holds inside a
  # submodule, whose commit and tracked bytes validate_gitlinks has checked.
  if ! git diff --cached --quiet --ignore-submodules=none "$head" -- ||
     ! GIT_INDEX_FILE="$source_index" git read-tree "$head" ||
     ! GIT_INDEX_FILE="$source_index" git diff --quiet --ignore-submodules=untracked "$head" --; then
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
