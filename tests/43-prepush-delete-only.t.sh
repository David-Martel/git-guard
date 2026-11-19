#!/bin/sh
# Category 43 — a push whose every ref update is a deletion publishes nothing,
# so pre-push lets it through from a bare repository and from a clone without
# a checkout, and prints the receipt.
#
# Why: on 2026-11-19 the sentinel-assess cleanup deleted 21 merged GitHub
# branches from scratch clones. From a bare clone the push was refused (the
# bare-repository block; 0.2.19 failed earlier with a mandate TOOL ERROR), and
# from a `--no-checkout` clone it was refused with "declared pre-commit
# configuration is missing or not a file", because HEAD declares
# .pre-commit-config.yaml but the empty worktree has no copy. Neither refusal
# protects anything: a deletion publishes no commit and no content to scan or
# test. The workaround, a full checkout just to delete a ref, costs time and
# disk on large repos. The guards that DO protect content must stay: a bare
# push that also publishes a commit, and a content push from a clone without a
# checkout, are still refused.
# shellcheck shell=sh

# t_do_seed — a remote with main (declaring pre-commit) and a branch `gone`.
# Echoes the work dir; the remote is "$dir/remote.git".
t_do_seed() {
  _w="$(mktemp -d "$GG_T_TMPROOT/prepush43.XXXXXX")" || return 1
  git init -q --bare "$_w/remote.git" || return 1
  _s="$(gg_mktemp_repo)" || return 1
  (
    cd "$_s" || exit 1
    git checkout -q -b main
    printf 'repos: []\n' > .pre-commit-config.yaml
    printf 'x\n' > a.txt
    git add . && git -c core.hooksPath=/dev/null commit -q -m "initial" || exit 1
    git branch gone && git branch gone2 || exit 1
    git -c core.hooksPath=/dev/null push -q "$_w/remote.git" main gone gone2
  ) || return 1
  gg_rmrepo "$_s"
  printf '%s' "$_w"
}

# t_do_has REMOTE REF — succeed iff REMOTE still has refs/heads/REF.
t_do_has() { git -C "$1" rev-parse -q --verify "refs/heads/$2" >/dev/null 2>&1; }

t_do_receipt_re='^git-guard pre-push [^ :]+: [0-9]+ ref\(s\) checked$'

t_case_prepush_delete_only() {
  t_begin "43 pre-push: delete-only pushes pass from bare and no-checkout clones"
  w="$(t_do_seed)" || { t_fail "fixture could not be created"; return 1; }
  log="$w/push.log"

  # --- bare clone ------------------------------------------------------------
  git clone -q --bare "$w/remote.git" "$w/bare.git"
  git -C "$w/bare.git" config core.hooksPath "$GG_ROOT/hooks"
  git -C "$w/bare.git" push origin --delete gone >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "bare: a delete-only push passes"
  if t_do_has "$w/remote.git" gone; then t_fail "bare: the branch was deleted on the remote"
  else t_ok "bare: the branch was deleted on the remote"; fi
  grep -Eq "$t_do_receipt_re" "$log"; t_assert $? "bare: the delete-only push prints the receipt"
  if grep -q "this push comes from a bare repository" "$log"; then t_fail "bare: no bare-repository refusal for a deletion"
  else t_ok "bare: no bare-repository refusal for a deletion"; fi

  # A push that deletes one ref and publishes another is not delete-only.
  printf 'y\n' > "$w/b.txt"
  blob="$(git -C "$w/bare.git" hash-object -w "$w/b.txt")"
  tree="$( { git -C "$w/bare.git" ls-tree main; printf '100644 blob %s\tb.txt\n' "$blob"; } | git -C "$w/bare.git" mktree)"
  new="$(printf 'more\n' | git -C "$w/bare.git" -c user.email=t@git-guard.local -c user.name=t commit-tree -p main "$tree")"
  git -C "$w/bare.git" update-ref refs/heads/more "$new"
  git -C "$w/bare.git" push origin more :gone2 >"$log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "bare: a mixed delete+publish push is still refused (rc=$rc)"
  else t_fail "bare: a mixed delete+publish push is still refused (rc=$rc)"; fi
  grep -q "this push comes from a bare repository" "$log"; t_assert $? "bare: the mixed push gets the bare-repository refusal"
  if t_do_has "$w/remote.git" gone2; then t_ok "bare: the refused mixed push deleted nothing"
  else t_fail "bare: the refused mixed push deleted nothing"; fi

  # --- clone without a checkout (HEAD declares pre-commit, worktree is empty) --
  git clone -q --no-checkout "$w/remote.git" "$w/nock"
  git -C "$w/nock" config core.hooksPath "$GG_ROOT/hooks"
  ( cd "$w/nock" && git push origin --delete gone2 >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "no-checkout: a delete-only push passes"
  if t_do_has "$w/remote.git" gone2; then t_fail "no-checkout: the branch was deleted on the remote"
  else t_ok "no-checkout: the branch was deleted on the remote"; fi
  grep -Eq "$t_do_receipt_re" "$log"; t_assert $? "no-checkout: the delete-only push prints the receipt"
  if grep -q "configuration is missing or not a file" "$log"; then t_fail "no-checkout: no missing-provider refusal for a deletion"
  else t_ok "no-checkout: no missing-provider refusal for a deletion"; fi

  # Publishing content from the same clone still meets the provider check.
  ( cd "$w/nock" && git push origin main:refs/heads/copy >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "no-checkout: a content push is still refused (rc=$rc)"
  else t_fail "no-checkout: a content push is still refused (rc=$rc)"; fi

  rm -rf "$w"
}
