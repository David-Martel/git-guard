#!/bin/sh
# Category 26 — the POSIX scan's batched nested-scope pre-pass must prune
# exactly what the per-directory check prunes and dispatch exactly the same
# candidates.
#
# Behaviour protected: one pre-pass `find` lists nested Git scopes (bare,
# half-bare, worktree containers, glob-named) and the candidate
# scan prunes them; output equals the per-directory scan on fixed and seeded
# random trees; an over-limit prune list, a probe write failure or a
# newline-bearing scope falls back with the same output; letter-case lookalikes
# follow the filesystem's case sensitivity.
#
# What a failure means: the pre-pass (#43) exists only for speed. Any difference
# from the per-directory scan means a reserved path inside another repository
# is touched, or a candidate in this repository is missed.
# shellcheck shell=sh

# Run a hook copy against a fixture root. MSYSTEM forces audit-only mode on
# every platform, so no fixture file is ever removed and runs are comparable.
gg_scope_run() {
  (cd "$2" && MSYSTEM=MINGW64 NUKENUL_MANDATORY=1 sh "$1" >"$3" 2>&1)
}

# Sorted diagnostics, minus the pre-pass notices (the only intended difference).
gg_scope_norm() {
  grep -v '^WARN_SCOPE_' "$1" | LC_ALL=C sort
}

# Seeded random tree: nested .git files/dirs, bare and half-bare lookalikes,
# worktree containers, glob/space/reserved names, at random depths. awk's
# generator is fixed per implementation, so a run is reproducible per host.
gg_scope_random_tree() {
  awk -v seed="$2" 'BEGIN {
    srand(seed)
    nd = split("a|b|sub dir|g[1]|g1|x*y|xay|q?z|nul.d|CON|aux|worktrees|.worktrees|objects|refs|lib|HEAD", d, "|")
    nf = split("nul|NUL.txt|con|aux.md|PRN |COM1|lpt9.log|Nul .txt|$null|ordinary|nulordinary", f, "|")
    for (i = 0; i < 90; i++) {
      depth = 1 + int(rand() * 4); p = ""
      for (j = 0; j < depth; j++) p = p (p == "" ? "" : "/") d[1 + int(rand() * nd)]
      print "d " p
      k = rand()
      if (k < 0.12) print "g " p
      else if (k < 0.20) print "G " p
      else if (k < 0.27) print "b " p
      else if (k < 0.32) print "h " p
      for (j = int(rand() * 3); j > 0; j--) print "f " p "/" f[1 + int(rand() * nf)]
    }
  }' | while IFS= read -r gg_scope_op; do
    gg_scope_path="$1/${gg_scope_op#? }"
    case "$gg_scope_op" in
      d\ *) mkdir -p "$gg_scope_path" ;;
      g\ *) printf 'gitdir: elsewhere\n' > "$gg_scope_path/.git" ;;
      G\ *) mkdir -p "$gg_scope_path/.git/objects" ;;
      b\ *) mkdir -p "$gg_scope_path/objects" "$gg_scope_path/refs" && printf 'ref: refs/heads/main\n' > "$gg_scope_path/HEAD" ;;
      h\ *) mkdir -p "$gg_scope_path/objects" && : > "$gg_scope_path/HEAD" ;;
      f\ *) : > "$gg_scope_path" ;;
    esac 2>/dev/null
  done
  return 0
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
  # Letter-case variants. NTFS/APFS resolve up/.git and low/HEAD
  # case-insensitively, so the per-directory test prunes these there; a
  # case-sensitive filesystem scans them. Either way both scans must agree.
  mkdir -p "$r/up/.GIT" "$r/low/objects" "$r/low/refs"
  : > "$r/low/head"
  : > "$r/up/nul"
  : > "$r/low/nul"

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
  if [ -e "$r/up/.git" ] && [ -f "$r/low/HEAD" ]; then
    if grep -qxF "PRESERVED_SCOPE: $r/up" "$gg_scope_new_log" && grep -qxF "PRESERVED_SCOPE: $r/low" "$gg_scope_new_log"; then
      t_ok "case-insensitive filesystem: .GIT and lowercase head scopes pruned"
    else t_fail "case-insensitive filesystem: .GIT or lowercase head scope missed"; fi
  else
    if grep -qxF "WOULD_REMOVE_ZERO_BYTE (audit-only on this platform): $r/up/nul" "$gg_scope_new_log" &&
      grep -qxF "WOULD_REMOVE_ZERO_BYTE (audit-only on this platform): $r/low/nul" "$gg_scope_new_log"; then
      t_ok "case-sensitive filesystem: .GIT and lowercase head are not scopes"
    else t_fail "case-sensitive filesystem: letter-case lookalike pruned"; fi
  fi
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

  # Over-limit prune list (bytes, then scope count): fall back, loudly.
  for gg_scope_seam in 's/^    nested_scope_limit=65536$/    nested_scope_limit=1/' \
    's/^    nested_scope_count_limit=512$/    nested_scope_count_limit=2/'; do
    sed "$gg_scope_seam" "$gg_scope_new" > "$gg_scope_tools/limit.sh"
    if cmp -s "$gg_scope_new" "$gg_scope_tools/limit.sh"; then
      t_fail "limit seam not found: $gg_scope_seam"
      continue
    fi
    gg_scope_run "$gg_scope_tools/limit.sh" "$r" "$gg_scope_tmp/limit.log"
    gg_scope_norm "$gg_scope_tmp/limit.log" > "$gg_scope_tmp/limit.sorted"
    if grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_tmp/limit.log" && cmp -s "$gg_scope_tmp/limit.sorted" "$gg_scope_tmp/old.sorted"; then
      t_ok "over-limit prune list falls back with a warning and the same output ($gg_scope_seam)"
    else t_fail "over-limit prune list did not fall back cleanly ($gg_scope_seam)"; fi
  done

  # A probe that cannot write its scope list must not leave a silently short
  # list behind it: the abort marker forces the per-directory test.
  if (printf x > /dev/full) 2>/dev/null; then
    t_skip "/dev/full accepts writes here; probe write-failure branch not exercised"
  else
    sed 's|"\$parent" \|\| { : > "\$abort"; exit 1; }|"$parent" >/dev/full \|\| { : > "$abort"; exit 1; }|' \
      "$gg_scope_new" > "$gg_scope_tools/full.sh"
    if cmp -s "$gg_scope_new" "$gg_scope_tools/full.sh"; then
      t_fail "probe write seam not found"
    else
      gg_scope_run "$gg_scope_tools/full.sh" "$r" "$gg_scope_tmp/full.log"
      if grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_tmp/full.log" &&
        [ "$(gg_scope_norm "$gg_scope_tmp/full.log")" = "$(cat "$gg_scope_tmp/old.sorted")" ]; then
        t_ok "probe write failure falls back to per-directory checks with the same output"
      else t_fail "probe write failure left a short prune list in use"; fi
    fi
  fi

  # Seeded random trees: batched and per-directory scans must agree exactly.
  for gg_scope_seed in 7 2026; do
    gg_scope_rand="$gg_scope_tmp/random $gg_scope_seed"
    mkdir -p "$gg_scope_rand"
    (cd "$gg_scope_rand" && git init -q) || { t_fail "cannot initialise random fixture"; continue; }
    gg_scope_random_tree "$gg_scope_rand" "$gg_scope_seed"
    gg_scope_run "$gg_scope_new" "$gg_scope_rand" "$gg_scope_new_log"; gg_scope_new_rc=$?
    gg_scope_run "$gg_scope_old" "$gg_scope_rand" "$gg_scope_old_log"; gg_scope_old_rc=$?
    gg_scope_scopes=$(grep -c '^PRESERVED_SCOPE:' "$gg_scope_new_log")
    gg_scope_cands=$(grep -c '^WOULD_REMOVE_ZERO_BYTE' "$gg_scope_new_log")
    if [ "$gg_scope_new_rc" = "$gg_scope_old_rc" ] && ! grep -q '^WARN_SCOPE_' "$gg_scope_new_log" &&
      [ "$(gg_scope_norm "$gg_scope_new_log")" = "$(gg_scope_norm "$gg_scope_old_log")" ] &&
      [ "$gg_scope_scopes" -gt 0 ] && [ "$gg_scope_cands" -gt 0 ]; then
      t_ok "seed $gg_scope_seed random tree: identical output ($gg_scope_scopes scopes, $gg_scope_cands candidates)"
    else
      t_fail "seed $gg_scope_seed random tree: batched scan differs ($gg_scope_scopes scopes, $gg_scope_cands candidates)"
      diff "$gg_scope_old_log" "$gg_scope_new_log" >&2
    fi
  done

  # The prune vector is built in one step. A per-scope `set -- "$@"` loop is
  # quadratic (tens of seconds for a few thousand scopes under Git Bash).
  awk 'BEGIN { for (i = 0; i < 4000; i++) printf "/r/dir %d/it'"'"'s \\[x\\] $HOME `id` \"q\"\n", i }' > "$gg_scope_tmp/patterns"
  gg_scope_start=$(date +%s)
  sh "$gg_scope_new" --prune-args "$gg_scope_tmp/patterns" > "$gg_scope_tmp/args"; gg_scope_rc=$?
  gg_scope_elapsed=$(( $(date +%s) - gg_scope_start ))
  if [ "$gg_scope_rc" = 0 ] && [ "$(wc -l < "$gg_scope_tmp/args")" -eq 12000 ] &&
    [ "$(sed -n '3p' "$gg_scope_tmp/args")" = "$(sed -n '1p' "$gg_scope_tmp/patterns")" ] &&
    [ "$(sed -n '12000p' "$gg_scope_tmp/args")" = "$(sed -n '4000p' "$gg_scope_tmp/patterns")" ]; then
    t_ok "4000 quoted patterns round-trip into one argument vector"
  else t_fail "prune argument vector lost or altered patterns"; fi
  if [ "$gg_scope_elapsed" -le 2 ]; then
    t_ok "4000-pattern prune vector built in ${gg_scope_elapsed}s (<= 2s)"
  else t_fail "4000-pattern prune vector took ${gg_scope_elapsed}s (quadratic build?)"; fi

  # NTFS has no newline names, and an unreadable directory needs a non-root
  # POSIX user, so these cases run on Linux/WSL only.
  if gg_is_windows; then
    t_skip "newline and unreadable-directory pre-pass cases need Linux/WSL"
  else
    # A newline-bearing nested scope cannot be listed line-wise: fall back.
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
      # Unreadable inside a nested repo: the pre-pass (which enters nested
      # repos) is partial, but the scope it found is still pruned, so the scan
      # never meets the locked directory and no slow fallback runs.
      mkdir -p "$r/nest/deep/locked/inner"
      printf 'gitdir: elsewhere\n' > "$r/nest/.git"
      chmod 000 "$r/nest/deep/locked"
      gg_scope_run "$gg_scope_new" "$r" "$gg_scope_new_log"
      gg_scope_run "$gg_scope_old" "$r" "$gg_scope_old_log"
      chmod 755 "$r/nest/deep/locked"
      if grep -q '^WARN_SCOPE_PREPASS_INCOMPLETE:' "$gg_scope_new_log" &&
        ! grep -q '^WARN_SCOPE_FALLBACK:' "$gg_scope_new_log" &&
        ! grep -q '^WARN_TRAVERSAL:' "$gg_scope_new_log" &&
        grep -qxF "PRESERVED_SCOPE: $r/nest" "$gg_scope_new_log" &&
        [ "$(gg_scope_norm "$gg_scope_new_log")" = "$(gg_scope_norm "$gg_scope_old_log")" ]; then
        t_ok "unreadable directory inside a nested repo keeps the listed scopes (no fallback)"
      else t_fail "unreadable directory inside a nested repo forced a fallback or changed output"; fi
      rm -rf "$r/nest"
      # Unreadable in the scanned tree itself: both scans warn identically.
      mkdir -p "$r/locked/inner"
      chmod 000 "$r/locked"
      gg_scope_run "$gg_scope_new" "$r" "$gg_scope_new_log"
      gg_scope_run "$gg_scope_old" "$r" "$gg_scope_old_log"
      chmod 755 "$r/locked"
      if grep -q '^WARN_SCOPE_PREPASS_INCOMPLETE:' "$gg_scope_new_log" &&
        grep -q '^WARN_TRAVERSAL:' "$gg_scope_new_log" &&
        [ "$(gg_scope_norm "$gg_scope_new_log")" = "$(gg_scope_norm "$gg_scope_old_log")" ]; then
        t_ok "unreadable directory in the work tree: partial pre-pass, same output and warnings"
      else t_fail "unreadable directory in the work tree changed the output"; fi
    else
      t_skip "unreadable-directory cases need a non-root user"
    fi
  fi
  rm -rf "$gg_scope_tmp"
}
