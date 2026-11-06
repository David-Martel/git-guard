#!/bin/sh
# Category 40 — pre-push re-scans the content it publishes, refuses bare
# repositories, and prints a one-line receipt.
#
# Why: pre-commit scans added lines, but a commit made on a host without
# git-guard (vigil-utils #1403 came from a WSL distro with no hooks path), by
# plumbing, or in a web editor reaches the remote through a covered host
# without that scan. Pushes from a bare scratch repo failed with a misleading
# provider message; the decision is to refuse them and name the supported
# routes. The receipt makes "the hooks ran" visible in push output.
#
# Commits that never met a commit hook are built with plumbing (mktree /
# commit-tree / fast-import), exactly as such commits arise in practice. The
# fake secret is assembled at run time by gg_fixture_fake_secret.
# shellcheck shell=sh

# t_pc_repo — repo with git-guard hooks, one clean commit on main, and a bare
# remote named origin. Echoes the repo path; the remote is "$repo.remote".
t_pc_repo() {
  _r="$(gg_mktemp_repo)" || return 1
  git init -q --bare "$_r.remote" || return 1
  (
    cd "$_r" || exit 1
    git config core.hooksPath "$GG_ROOT/hooks"
    git checkout -q -b main
    printf '# fixture\n' > README.md
    git add README.md
    GIT_GUARD_RULES_DIR="$GG_BUNDLED" git commit -q -m "initial" >/dev/null 2>&1 || exit 1
    git remote add origin "$_r.remote"
  ) || return 1
  printf '%s' "$_r"
}

# t_pc_plumb REPO PARENT FILE CONTENT-FILE MSG — commit FILE (bytes of
# CONTENT-FILE) on top of PARENT's tree without running any hook. Echoes the sha.
t_pc_plumb() {
  ( cd "$1" || exit 1
    _blob="$(git hash-object -w "$4")" || exit 1
    _tree="$( { git ls-tree "$2" | grep -v "	$3\$"; printf '100644 blob %s\t%s\n' "$_blob" "$3"; } | git mktree)" || exit 1
    printf '%s\n' "$5" | git commit-tree -p "$2" "$_tree" )
}

# t_pc_check MSG TEST... — run a test command, record ok/FAIL under MSG.
t_pc_check() {
  _msg="$1"; shift
  if "$@"; then t_ok "$_msg"; else t_fail "$_msg"; fi
}
# t_pc_not CMD... — succeed iff CMD fails (output discarded).
t_pc_not() { ! "$@" >/dev/null 2>&1; }

t_pc_receipt_re='^git-guard pre-push [^ :]+: [0-9]+ ref\(s\) checked$'

t_case_prepush_content_and_bare() {
  t_begin "40 pre-push: pushed-range secret scan, bare-repository refusal, receipt"
  pc_dir="$(mktemp -d "$GG_T_TMPROOT/prepush40.XXXXXX")" || { t_fail "mktemp"; return 1; }
  log="$pc_dir/push.log"
  r="$(t_pc_repo)" || { t_fail "fixture repo could not be created"; return 1; }

  # --- receipt on a clean push -------------------------------------------------
  ( cd "$r" && git push origin main >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "clean push of a new branch passes"
  grep -Eq "$t_pc_receipt_re" "$log"; t_assert $? "a passing push prints the one-line receipt"
  grep -Eq '^git-guard pre-push [^ :]+: 1 ref\(s\) checked$' "$log"; t_assert $? "the receipt counts the pushed refs"
  t_pc_check "the receipt is exactly one line" [ "$(grep -c '^git-guard pre-push ' "$log")" = 1 ]

  # --- a never-scanned commit carrying a secret is refused ---------------------
  mkdir -p "$pc_dir/leak"; gg_fixture_fake_secret "$pc_dir/leak"
  leak="$(t_pc_plumb "$r" main leak.js "$pc_dir/leak/leak.js" "made where no hook ran")"
  ( cd "$r" && git update-ref refs/heads/leaky "$leak" && git push origin leaky >"$log" 2>&1 ); rc=$?
  t_pc_check "push of an unscanned commit with a secret is BLOCKED (rc=$rc)" [ "$rc" -ne 0 ]
  grep -q "possible secret in leak.js:1" "$log"; t_assert $? "the block names the file and line"
  grep -q "$leak" "$log"; t_assert $? "the block names the offending commit"
  grep -q "pragma: allowlist secret" "$log"; t_assert $? "the block gives the line-pragma hint"
  t_pc_check "nothing reached the remote" t_pc_not git -C "$r.remote" rev-parse -q --verify refs/heads/leaky
  t_pc_check "a refused push prints no receipt" t_pc_not grep -Eq "$t_pc_receipt_re" "$log"

  # The secret is in an older commit; the pushed tip is clean.
  printf 'clean\n' > "$pc_dir/clean.txt"
  tip="$(t_pc_plumb "$r" "$leak" clean.txt "$pc_dir/clean.txt" "clean on top")"
  ( cd "$r" && git update-ref refs/heads/buried "$tip" && git push origin buried >"$log" 2>&1 ); rc=$?
  t_pc_check "a secret below a clean tip is BLOCKED (rc=$rc)" [ "$rc" -ne 0 ]
  grep -q "$leak" "$log"; t_assert $? "the buried block names the older offending commit"

  # Published history is not re-scanned: commits already on the remote (here
  # planted by a fetch on the remote side, which runs no hook) are excluded.
  git -C "$r.remote" fetch -q "$r" refs/heads/leaky:refs/heads/leaky 2>/dev/null
  ( cd "$r" && git fetch -q origin )
  ( cd "$r" && git push origin buried >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "commits already on the remote are not scanned again"

  # ...but only on THAT remote. origin/leaky now tracks the secret commit; a
  # push of it to another, empty destination must still be scanned, whether
  # the destination is named by URL or by a remote of its own.
  git init -q --bare "$pc_dir/elsewhere.git"
  ( cd "$r" && git push "$pc_dir/elsewhere.git" "$leak:refs/heads/leaky" >"$log" 2>&1 ); rc=$?
  t_pc_check "URL push: history tracked for ANOTHER remote is still scanned (rc=$rc)" [ "$rc" -ne 0 ]
  t_pc_check "URL push: the block names the commit" grep -q "$leak" "$log"
  t_pc_check "URL push: nothing reached the new destination" \
    t_pc_not git -C "$pc_dir/elsewhere.git" rev-parse -q --verify refs/heads/leaky
  ( cd "$r" && git remote add elsewhere "$pc_dir/elsewhere.git" &&
    git push elsewhere "$leak:refs/heads/leaky" >"$log" 2>&1 ); rc=$?
  t_pc_check "named push: another remote's tracking refs are not the destination's (rc=$rc)" [ "$rc" -ne 0 ]

  # Deletions publish nothing and still get the receipt.
  ( cd "$r" && git push origin :refs/heads/buried >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "a delete-only push passes"
  grep -Eq "$t_pc_receipt_re" "$log"; t_assert $? "a delete-only push prints the receipt"

  # Over the cap: scan the newest 500 and say so.
  i=1
  while [ "$i" -le 502 ]; do
    body="line $i"
    printf 'commit refs/heads/many\nmark :%s\ncommitter t <t@example.invalid> %s +0000\ndata 1\nc\n' \
      "$i" "$((1700000000 + i))"
    if [ "$i" = 1 ]; then printf 'from refs/heads/main^0\n'; else printf 'from :%s\n' "$((i - 1))"; fi
    printf 'M 100644 inline many.txt\ndata %s\n%s\n' "$((${#body} + 1))" "$body"
    i=$((i + 1))
  done | git -C "$r" fast-import --quiet
  ( cd "$r" && git push origin many >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "a clean push over the scan cap passes"
  grep -q "502 new commits; scanning the newest 500" "$log"; t_assert $? "over the cap the hook says it scanned the newest 500"

  # --- bare repositories -------------------------------------------------------
  bare="$pc_dir/scratch.git"
  git clone -q --bare "$r" "$bare"
  git -C "$bare" config core.hooksPath "$GG_ROOT/hooks"
  # A clone does not copy the fixture identity, and CI has no global one.
  git -C "$bare" config user.email tester@git-guard.local
  git -C "$bare" config user.name git-guard-tester
  # A pushed commit that declares pre-commit: the provider path used to fail
  # here with a misleading "configuration is missing" message.
  printf 'repos: []\n' > "$pc_dir/pcc.yaml"
  declared="$(t_pc_plumb "$bare" main .pre-commit-config.yaml "$pc_dir/pcc.yaml" "declare pre-commit")"
  git -C "$bare" update-ref refs/heads/declared "$declared"
  git -C "$bare" push "$r.remote" declared >"$log" 2>&1; rc=$?
  t_pc_check "push from a bare repository is refused (rc=$rc)" [ "$rc" -ne 0 ]
  grep -q "this push comes from a bare repository" "$log"; t_assert $? "the refusal says the source is bare"
  grep -q "git worktree add" "$log"; t_assert $? "the refusal names the worktree route"
  grep -q "preserve/<name>" "$log"; t_assert $? "the refusal names the preserve custody route"
  t_pc_check "the misleading provider message is gone" t_pc_not grep -q "configuration is missing or not a file" "$log"

  plain="$(t_pc_plumb "$bare" main note.txt "$pc_dir/clean.txt" "plain change")"
  git -C "$bare" update-ref refs/heads/plain "$plain"
  git -C "$bare" push "$r.remote" plain >"$log" 2>&1; rc=$?
  t_pc_check "bare refusal does not depend on a declared provider (rc=$rc)" [ "$rc" -ne 0 ]

  # The supported route: a worktree of the bare repository pushes normally.
  wt="$pc_dir/wt"
  git -C "$bare" worktree add -q "$wt" plain 2>/dev/null
  ( cd "$wt" && git push "$r.remote" plain >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "push from a worktree of the bare repository passes"
  grep -Eq "$t_pc_receipt_re" "$log"; t_assert $? "the worktree push prints the receipt"

  # preserve/* custody pushes are exempt before the bare check. The exemption
  # needs every NEW commit to carry the trailer, so the bare repo tracks the
  # remote (main is already there).
  git -C "$bare" remote add dest "$r.remote"
  git -C "$bare" fetch -q dest
  pres="$(cd "$bare" && printf 'snapshot\n\nPreserve-Of: main\n' | git commit-tree -p main "main^{tree}")"
  git -C "$bare" update-ref refs/heads/preserve/scratch "$pres"
  git -C "$bare" push dest preserve/scratch >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "preserve/* push with a valid trailer passes from a bare repository"
  grep -Eq "$t_pc_receipt_re" "$log"; t_assert $? "the exempt preserve push prints the receipt"

  git -C "$bare" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "$r.remote" "$pc_dir"; gg_rmrepo "$r"
}
