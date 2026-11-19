#!/bin/sh
# Category 42 — the declared pre-commit provider's pre-push checks work on git
# older than 2.36, which has no `git ls-tree --format`.
#
# Why: Ubuntu 22.04 (WSL on Carbon and dtm-work) ships git 2.34.1. There every
# pre-push in a repo declaring .pre-commit-config.yaml was refused with
# "pre-commit pre-push submodule listing for . failed" because
# precommit-provider.sh listed the tree with `ls-tree --format`. A git wrapper
# on PATH rejects that option the way 2.34 does, so this runs on any git.
# shellcheck shell=sh

# t_og_check MSG TEST... — run a test command, record ok/FAIL under MSG.
t_og_check() {
  _msg="$1"; shift
  if "$@"; then t_ok "$_msg"; else t_fail "$_msg"; fi
}

# t_og_push REPO LOG PATH [ENV...] — run hooks/pre-push for HEAD -> main.
t_og_push() {
  _r="$1"; _l="$2"; _p="$3"; shift 3
  _head="$(git -C "$_r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_head" 0000000000000000000000000000000000000000 |
    (cd "$_r" && env PATH="$_p" "$@" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$_l" 2>&1
}

t_case_precommit_provider_old_git() {
  t_begin "42 pre-commit provider pre-push works without git ls-tree --format (git < 2.36)"
  og_dir="$(mktemp -d "$GG_T_TMPROOT/oldgit42.XXXXXX")" || { t_fail "mktemp"; return 1; }
  log="$og_dir/push.log"

  # A stub provider that records its calls, and a git that refuses
  # `ls-tree --format` exactly as git 2.34 does.
  og_bin="$og_dir/provider-bin"; og_old="$og_dir/old-git-bin"
  mkdir -p "$og_bin" "$og_old"
  cat > "$og_bin/pre-commit" <<EOF
#!/bin/sh
printf '%s\\n' framework >> '$og_dir/framework-calls'
cat >/dev/null
exit 0
EOF
  cat > "$og_old/git" <<'EOF'
#!/bin/sh
og_ls=0; og_fmt=0
for og_a in "$@"; do
  case "$og_a" in ls-tree) og_ls=1 ;; --format|--format=*) og_fmt=1 ;; esac
done
if [ "$og_ls" = 1 ] && [ "$og_fmt" = 1 ]; then
  echo "error: unknown option \`format=%(objectmode)'" >&2
  exit 129
fi
exec "$GG_T_REAL_GIT" "$@"
EOF
  chmod +x "$og_bin/pre-commit" "$og_old/git"
  GG_T_REAL_GIT="$(command -v git)"; export GG_T_REAL_GIT
  new_path="$og_bin:$PATH"
  old_path="$og_old:$og_bin:$PATH"

  # Control: the wrapper really refuses the option the old code used.
  r="$(gg_mktemp_repo)"
  ( cd "$r" && env PATH="$old_path" git ls-tree -r --format='%(objectmode)' HEAD >/dev/null 2>&1 )
  t_expect_rc 129 "$?" "the wrapper refuses ls-tree --format, as git 2.34 does"

  printf 'repos: []\n' > "$r/.pre-commit-config.yaml"
  printf 'fixture\n' > "$r/a.txt"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" && git checkout -q -b main &&
    git add .pre-commit-config.yaml a.txt &&
    env PATH="$new_path" git commit -q -m "declare pre-commit" ) >/dev/null 2>&1

  # --- no gitlinks -------------------------------------------------------------
  rm -f "$og_dir/framework-calls"
  t_og_push "$r" "$log" "$old_path"; rc=$?
  t_expect_rc 0 "$rc" "old git: pre-push in a repo declaring pre-commit passes"
  t_og_check "old git: the declared provider ran" grep -qx framework "$og_dir/framework-calls"
  t_og_check "old git: no 'listing failed' refusal" t_og_not grep -q "listing for" "$log"

  # --- an uninitialised submodule: path and recorded commit are parsed -------
  sub_sha="$(git -C "$r" rev-parse HEAD)"
  mkdir -p "$r/vendor/lib"
  ( cd "$r" && git update-index --add --cacheinfo "160000,$sub_sha,vendor/lib" &&
    env PATH="$new_path" git commit -q -m "add gitlink" ) >/dev/null 2>&1
  t_og_push "$r" "$log" "$old_path"; rc=$?
  t_expect_rc 0 "$rc" "old git: an uninitialised submodule is validated, not refused"
  t_og_check "old git: the gitlink's path and recorded commit are reported" \
    grep -q "submodule 'vendor/lib' is not checked out; QA sees only its recorded commit $sub_sha" "$log"
  cp "$log" "$og_dir/old.log"
  t_og_push "$r" "$log" "$new_path"; rc=$?
  t_expect_rc 0 "$rc" "current git: the same push passes"
  t_og_check "current git: the same gitlink report as old git" \
    grep -q "submodule 'vendor/lib' is not checked out; QA sees only its recorded commit $sub_sha" "$log"

  # --- refuse policy: the mode listing still finds the gitlink ---------------
  t_og_push "$r" "$log" "$old_path" GIT_GUARD_PRECOMMIT_SUBMODULES=refuse; rc=$?
  t_expect_rc 1 "$rc" "old git: submodule policy 'refuse' refuses submodule-backed source"
  t_og_check "old git: the refusal names the policy, not a listing failure" \
    grep -q "submodule policy is refuse" "$log"

  # --- a path that needs quoting is still refused ----------------------------
  tab="$(printf '\t')"
  # Built with mktree: Git for Windows refuses such a name in the index, and
  # the quoting refusal comes before the clean-workspace check.
  ( cd "$r" &&
    og_tree="$( { git ls-tree -z HEAD; printf '160000 commit %s\todd%sname\0' "$sub_sha" "$tab"; } | git mktree -z)" &&
    og_c="$(git commit-tree -p HEAD -m "quoted gitlink" "$og_tree")" &&
    git update-ref refs/heads/main "$og_c" ) >/dev/null 2>&1
  t_og_check "fixture: HEAD records the gitlink whose path needs quoting" \
    git -C "$r" cat-file -e "HEAD:odd${tab}name"
  t_og_push "$r" "$log" "$old_path"; rc=$?
  t_expect_rc 1 "$rc" "old git: a gitlink path that needs quoting is refused"
  t_og_check "old git: the refusal says the path needs quoting" grep -q 'needs quoting' "$log"

  gg_rmrepo "$r"; rm -rf "$og_dir"
}

# t_og_not CMD... — succeed iff CMD fails.
t_og_not() { ! "$@" >/dev/null 2>&1; }
