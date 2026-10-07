#!/bin/sh
# The POSIX scan's batched nested-scope pre-pass must prune exactly what the
# per-directory check prunes and dispatch exactly the same candidates.
# shellcheck shell=sh

# Run a hook copy against a fixture root. MSYSTEM forces audit-only mode on
# every platform, so no fixture file is ever removed and runs are comparable.
gg_scope_run() {
  (cd "$2" && MSYSTEM=MINGW64 NUKENUL_MANDATORY=1 sh "$1" >"$3" 2>&1)
}

# Sorted diagnostics, minus the fallback notice (the only intended difference).
gg_scope_norm() {
  grep -v '^WARN_SCOPE_FALLBACK:' "$1" | LC_ALL=C sort
}

t_case_reserved_path_nested_scope() {
  t_begin "26 reserved paths: batched nested-scope pruning equals per-directory checks"
  gg_scope_tmp="$(mktemp -d "$GG_T_TMPROOT/nested-scope.XXXXXX")" || { t_fail "cannot allocate scratch"; return; }
  # Hook copies live beside no Rust source, so both always take the POSIX
  # path. The legacy copy forces the per-directory test with a negative limit.
  gg_scope_tools="$gg_scope_tmp/tools"
  mkdir -p "$gg_scope_tools"
  gg_scope_new="$gg_scope_tools/nul-cleanup.sh"
  gg_scope_old="$gg_scope_tools/nul-cleanup-per-directory.sh"
  cp "$GG_ROOT/hooks/common/nul-cleanup.sh" "$gg_scope_new"
  sed 's/^    nested_scope_limit=65536$/    nested_scope_limit=-1/' "$gg_scope_new" > "$gg_scope_old"
  if cmp -s "$gg_scope_new" "$gg_scope_old"; then
    t_fail "per-directory seam not found (nested_scope_limit line changed?)"
    rm -rf "$gg_scope_tmp"
    return
  fi

  # Root with a space and brackets. Native Git for Windows cannot create * or ?
  # names, so those appear only in directories made by the shell below (MSYS
  # maps them to private-use Unicode on NTFS).
  gg_scope_root="$gg_scope_tmp/root [a] b"
  mkdir -p "$gg_scope_root"
  # Git runs from inside the directory: Git for Windows reads an unconverted
  # absolute MSYS path with brackets as C:/tmp/..., not the fixture.
  (cd "$gg_scope_root" && git init -q && git config core.excludesFile "$gg_scope_tmp/no-excludes") ||
    { t_fail "cannot initialise the fixture root"; rm -rf "$gg_scope_tmp"; return; }
  printf 'build/\n' > "$gg_scope_root/.gitignore"
  r=$gg_scope_root
  # Candidates at several depths, one inside an ignored directory, and names
  # with spaces and trailing suffixes. Zero-byte, so audit mode reports them.
  mkdir -p "$r/a/b/c/d" "$r/build/out/x" "$r/dir with space" "$r/ga" "$r/starfish" "$r/notbare/objects" "$r/headdir/HEAD" "$r/headdir/objects" "$r/headdir/refs"
  : > "$r/nul"
  : > "$r/a/CON.txt"
  : > "$r/a/b/c/d/LPT1.log"
  : > "$r/build/out/x/PRN"
  : > "$r/dir with space/Nul .txt"
  printf 'keep\n' > "$r/a/b/aux.md"
  # A glob-unsafe nested repo name would, unescaped, also prune its sibling
  # (g[ab] matches ga; star* matches starfish). Both siblings stay in scope.
  mkdir -p "$r/g[ab]" "$r/star*"
  printf 'gitdir: elsewhere\n' > "$r/g[ab]/.git"
  : > "$r/g[ab]/nul"
  printf 'gitdir: elsewhere\n' > "$r/star*/.git"
  : > "$r/star*/CON"
  : > "$r/ga/nul"
  : > "$r/starfish/aux"
  # Nested non-bare repositories (a .git file and a .git directory), deep, one
  # with a space and a reserved name of its own: pruned, never dispatched.
  mkdir -p "$r/sub/nested repo [1]"
  printf 'gitdir: elsewhere\n' > "$r/sub/nested repo [1]/.git"
  : > "$r/sub/nested repo [1]/nul"
  mkdir -p "$r/deep/a/b/inner?/.git/refs" "$r/deep/a/b/inner?/x"
  : > "$r/deep/a/b/inner?/x/COM1.txt"
  mkdir -p "$r/aux/.git/objects"
  # Bare repositories: one real, one HEAD/objects/refs lookalike at depth.
  (cd "$r" && git init -q --bare "bare [x].git")
  : > "$r/bare [x].git/refs/CON.lock"
  mkdir -p "$r/lib/mirror*/objects" "$r/lib/mirror*/refs"
  printf 'ref: refs/heads/main\n' > "$r/lib/mirror*/HEAD"
  : > "$r/lib/mirror*/nul"
  # Not bare: HEAD without refs/, and HEAD that is a directory.
  : > "$r/notbare/HEAD"
  : > "$r/notbare/objects/aux"
  : > "$r/headdir/HEAD/nul"
  # Worktree containers, each holding a linked-worktree-looking child.
  mkdir -p "$r/worktrees/one" "$r/x/.worktrees/two"
  printf 'gitdir: elsewhere\n' > "$r/worktrees/one/.git"
  : > "$r/worktrees/one/nul"
  : > "$r/x/.worktrees/two/CON"

  gg_scope_new_log="$gg_scope_tmp/new.log"
  gg_scope_old_log="$gg_scope_tmp/old.log"
  gg_scope_run "$gg_scope_new" "$r" "$gg_scope_new_log"; gg_scope_new_rc=$?
  gg_scope_run "$gg_scope_old" "$r" "$gg_scope_old_log"; gg_scope_old_rc=$?
  t_expect_rc 0 "$gg_scope_new_rc" "batched scan of the fixture tree does not block"
  t_expect_rc "$gg_scope_old_rc" "$gg_scope_new_rc" "batched and per-directory scans exit alike"
  if ! grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_new_log" && grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_old_log"; then
    t_ok "default run uses the pre-pass; the forced copy uses per-directory checks"
  else t_fail "pre-pass/per-directory selection is not what the fixture forced"; fi
  gg_scope_norm "$gg_scope_new_log" > "$gg_scope_tmp/new.sorted"
  gg_scope_norm "$gg_scope_old_log" > "$gg_scope_tmp/old.sorted"
  if cmp -s "$gg_scope_tmp/new.sorted" "$gg_scope_tmp/old.sorted"; then
    t_ok "candidate and PRESERVED_SCOPE output identical to the per-directory scan"
  else
    t_fail "batched scan output differs from the per-directory scan"
    diff "$gg_scope_tmp/old.sorted" "$gg_scope_tmp/new.sorted" >&2
  fi

  gg_scope_missing=
  for gg_scope_path in "g[ab]" "star*" "sub/nested repo [1]" "deep/a/b/inner?" aux "bare [x].git" "lib/mirror*" worktrees x/.worktrees; do
    grep -qxF "PRESERVED_SCOPE: $r/$gg_scope_path" "$gg_scope_new_log" ||
      gg_scope_missing="$gg_scope_missing [$gg_scope_path]"
  done
  if [ -z "$gg_scope_missing" ]; then
    t_ok "nested, bare, glob-named and worktree-container scopes reported as PRESERVED_SCOPE"
  else t_fail "scopes not reported:$gg_scope_missing"; fi
  gg_scope_missing=
  for gg_scope_path in nul a/CON.txt a/b/c/d/LPT1.log build/out/x/PRN "dir with space/Nul .txt" ga/nul starfish/aux notbare/objects/aux headdir/HEAD/nul; do
    grep -qxF "WOULD_REMOVE_ZERO_BYTE (audit-only on this platform): $r/$gg_scope_path" "$gg_scope_new_log" ||
      gg_scope_missing="$gg_scope_missing [$gg_scope_path]"
  done
  if [ -z "$gg_scope_missing" ]; then
    t_ok "candidates found at every depth, in ignored output and beside glob-named scopes"
  else t_fail "candidates missed:$gg_scope_missing"; fi
  if grep -q 'PRESERVED_NONEMPTY (untracked or ignored; warning only): .*/a/b/aux.md$' "$gg_scope_new_log"; then
    t_ok "nonempty candidate still reaches the worker"
  else t_fail "nonempty candidate not evaluated"; fi
  if grep -E '^WOULD_REMOVE|^PRESERVED_[A-Z_]+ \(' "$gg_scope_new_log" |
    grep -qE '/(g\[ab\]|star\*|sub/nested repo \[1\]|deep/a/b/inner\?|aux|bare \[x\]\.git|lib/mirror\*|worktrees|x/\.worktrees)/'; then
    t_fail "a path inside a preserved scope was dispatched as a candidate"
  else t_ok "nothing inside a preserved scope was dispatched"; fi
  if [ -f "$r/nul" ] && [ -f "$r/ga/nul" ] && [ -f "$r/g[ab]/nul" ] && [ -f "$r/build/out/x/PRN" ]; then
    t_ok "audit-only fixture runs removed nothing"
  else t_fail "an audit-only run removed a fixture file"; fi

  # Two physical walks (pre-pass + candidate scan) and no per-directory shell.
  (cd "$r" && MSYSTEM=MINGW64 sh -x "$gg_scope_new" >"$gg_scope_tmp/trace.log" 2>&1)
  gg_scope_walks="$(grep -cE '^\+ (/usr/bin/find|find) ' "$gg_scope_tmp/trace.log" || true)"
  t_expect_rc 2 "$gg_scope_walks" "exactly two find walks (scope pre-pass + candidate scan)"
  if grep -q '^+ nested_scope_mode=listed' "$gg_scope_tmp/trace.log" && ! grep -q WARN_SCOPE_FALLBACK "$gg_scope_tmp/trace.log"; then
    t_ok "default path selects the listed prune set, not per-directory checks"
  else t_fail "default path fell back to per-directory checks"; fi

  # Over-limit prune list: fall back (loudly) to the per-directory test.
  sed 's/^    nested_scope_limit=65536$/    nested_scope_limit=1/' "$gg_scope_new" > "$gg_scope_tools/limit.sh"
  gg_scope_run "$gg_scope_tools/limit.sh" "$r" "$gg_scope_tmp/limit.log"
  gg_scope_norm "$gg_scope_tmp/limit.log" > "$gg_scope_tmp/limit.sorted"
  if grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_tmp/limit.log" && cmp -s "$gg_scope_tmp/limit.sorted" "$gg_scope_tmp/old.sorted"; then
    t_ok "over-limit prune list falls back with a warning and the same output"
  else t_fail "over-limit prune list did not fall back cleanly"; fi

  # A newline-bearing nested scope cannot be listed line-wise: fall back.
  # NTFS has no newline names, and an unreadable directory needs a non-root
  # POSIX user, so these two fallbacks run on Linux/WSL only.
  if gg_is_windows; then
    t_skip "newline and unreadable-directory pre-pass fallbacks need Linux/WSL"
  else
    mkdir -p "$r/line
break"
    printf 'gitdir: elsewhere\n' > "$r/line
break/.git"
    : > "$r/line
break/nul"
    gg_scope_run "$gg_scope_new" "$r" "$gg_scope_new_log"
    gg_scope_run "$gg_scope_old" "$r" "$gg_scope_old_log"
    if grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_new_log" &&
      [ "$(gg_scope_norm "$gg_scope_new_log")" = "$(gg_scope_norm "$gg_scope_old_log")" ] &&
      grep -q '^PRESERVED_SCOPE: .*/line$' "$gg_scope_new_log"; then
      t_ok "newline-bearing nested scope falls back and is still pruned"
    else t_fail "newline-bearing nested scope mishandled"; fi
    rm -rf "$r/line
break"
    if [ "$(id -u)" != 0 ]; then
      mkdir -p "$r/locked/inner"
      chmod 000 "$r/locked"
      gg_scope_run "$gg_scope_new" "$r" "$gg_scope_new_log"
      gg_scope_run "$gg_scope_old" "$r" "$gg_scope_old_log"
      chmod 755 "$r/locked"
      if grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_new_log" &&
        [ "$(gg_scope_norm "$gg_scope_new_log")" = "$(gg_scope_norm "$gg_scope_old_log")" ]; then
        t_ok "incomplete pre-pass (unreadable directory) falls back, never a partial list"
      else t_fail "incomplete pre-pass was trusted"; fi
    else
      t_skip "unreadable-directory fallback needs a non-root user"
    fi
  fi
  rm -rf "$gg_scope_tmp"
}
