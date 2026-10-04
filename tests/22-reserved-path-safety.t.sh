#!/bin/sh
# Reserved-path hygiene must never discard meaningful or foreign-workspace data.
# shellcheck shell=sh

t_case_reserved_path_safety() {
  t_begin "22 reserved paths: bounded zero-byte cleanup"
  if gg_is_windows; then
    t_skip "POSIX reserved-path fixtures require Linux/WSL; PowerShell requires Windows qualification"
    return
  fi
  gg_safe_repo="$(gg_mktemp_repo)"
  gg_safe_log="$(gg_tmp_log)"
  gg_safe_hook="$GG_ROOT/hooks/common/nul-cleanup.sh"
  printf 'retain meaningful data\n' > "$gg_safe_repo/nul"
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ -f "$gg_safe_repo/nul" ] && [ "$(cat "$gg_safe_repo/nul")" = 'retain meaningful data' ]; then
    t_ok "nonempty reserved file preserved byte-for-byte"
  else t_fail "nonempty reserved file was deleted or changed"; fi
  # Only the index can reach a commit: an UNTRACKED preserved path warns, a
  # STAGED one blocks.
  t_expect_rc 0 "$gg_safe_rc" "untracked nonempty reserved file warns without blocking"
  grep -q 'PRESERVED_NONEMPTY (untracked or ignored; warning only):' "$gg_safe_log"
  t_assert "$?" "untracked nonempty reserved file is reported"
  git -C "$gg_safe_repo" add -f nul
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  t_expect_rc 1 "$gg_safe_rc" "staged nonempty reserved file blocks with diagnostic"
  if [ "$(cat "$gg_safe_repo/nul")" = 'retain meaningful data' ] && grep -q '^PRESERVED_NONEMPTY: ' "$gg_safe_log"; then
    t_ok "staged nonempty reserved file preserved and named"
  else t_fail "staged nonempty reserved file changed or not named"; fi
  git -C "$gg_safe_repo" rm -q --cached nul
  rm -f "$gg_safe_repo/nul"

  # Reserved-name directories, symlinks and unreadable directories anywhere in
  # the work tree (often ignored build output) must not lock out every commit.
  mkdir -p "$gg_safe_repo/aux" "$gg_safe_repo/Con.d" "$gg_safe_repo/locked"
  printf 'data\n' > "$gg_safe_repo/aux/notes.txt"
  printf 'data\n' > "$gg_safe_repo/Con.d/notes.txt"
  ln -s notes.txt "$gg_safe_repo/nul.lnk"
  : > "$gg_safe_repo/locked/nul"
  chmod 000 "$gg_safe_repo/locked"
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  chmod 755 "$gg_safe_repo/locked"
  t_expect_rc 0 "$gg_safe_rc" "untracked reserved dirs, symlink and unreadable dir do not block"
  if [ -f "$gg_safe_repo/aux/notes.txt" ] && [ -f "$gg_safe_repo/Con.d/notes.txt" ] && [ -L "$gg_safe_repo/nul.lnk" ] && [ -f "$gg_safe_repo/locked/nul" ]; then
    t_ok "untracked reserved dirs, symlink and unreadable content preserved"
  else t_fail "untracked reserved dir, symlink or unreadable content changed"; fi
  grep -q 'PRESERVED_NONREGULAR (untracked or ignored; warning only):' "$gg_safe_log"
  t_assert "$?" "untracked reserved dir/symlink reported as a warning"
  git -C "$gg_safe_repo" add -f aux/notes.txt
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  t_expect_rc 1 "$gg_safe_rc" "a reserved directory with staged content blocks"
  git -C "$gg_safe_repo" rm -q --cached aux/notes.txt
  rm -rf "$gg_safe_repo/aux" "$gg_safe_repo/Con.d" "$gg_safe_repo/nul.lnk" "$gg_safe_repo/locked"

  mkdir -p "$gg_safe_repo/worktrees/other" "$gg_safe_repo/nested" "$gg_safe_repo/.git/private"
  : > "$gg_safe_repo/worktrees/other/CON.txt"
  : > "$gg_safe_repo/.git/private/aux"
  printf 'gitdir: elsewhere\n' > "$gg_safe_repo/nested/.git"
  : > "$gg_safe_repo/nested/nul"
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  if [ -f "$gg_safe_repo/worktrees/other/CON.txt" ] && [ -f "$gg_safe_repo/.git/private/aux" ] && [ -f "$gg_safe_repo/nested/nul" ]; then
    t_ok "foreign worktree, Git metadata and nested repository preserved"
  else t_fail "out-of-scope reserved file deleted"; fi

  mkdir -p "$gg_safe_repo/directory
with newline"
  : > "$gg_safe_repo/directory
with newline/COM1.txt"
  : > "$gg_safe_repo/\$null"
  : > "$gg_safe_repo/\$NULL"
  : > "$gg_safe_repo/PrN. "
  : > "$gg_safe_repo/LPT9.log"
  : > "$gg_safe_repo/CON .txt"
  : > "$gg_safe_repo/nulordinary"
  gg_safe_unicode_leaf=$(printf 'nul\303\251')
  : > "$gg_safe_repo/$gg_safe_unicode_leaf"
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  if [ ! -e "$gg_safe_repo/directory
with newline/COM1.txt" ] && [ ! -e "$gg_safe_repo/\$null" ] && [ ! -e "$gg_safe_repo/\$NULL" ] && [ ! -e "$gg_safe_repo/PrN. " ] && [ ! -e "$gg_safe_repo/LPT9.log" ] && [ ! -e "$gg_safe_repo/CON .txt" ]; then
    t_ok "empty matches include newline paths, literal null, extension and trailing suffix"
  else t_fail "empty reserved variant not cleaned"; fi
  if [ -f "$gg_safe_repo/nulordinary" ]; then t_ok "ordinary prefix name preserved"; else t_fail "ordinary prefix name deleted"; fi
  if [ -f "$gg_safe_repo/$gg_safe_unicode_leaf" ]; then t_ok "ordinary non-ASCII suffix preserved"; else t_fail "ordinary non-ASCII suffix deleted"; fi

  gg_safe_outside="$(mktemp -d "$GG_T_TMPROOT/outside.XXXXXX")"
  : > "$gg_safe_outside/nul"
  ln -s "$gg_safe_outside/nul" "$gg_safe_repo/aux"
  ln -s "$gg_safe_outside" "$gg_safe_repo/external"
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ -L "$gg_safe_repo/aux" ] && [ -f "$gg_safe_outside/nul" ]; then
    t_ok "symlink and external target preserved"
  else t_fail "symlink or external target changed"; fi
  t_expect_rc 0 "$gg_safe_rc" "untracked reserved symlink warns without blocking"
  git -C "$gg_safe_repo" add -f aux
  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ -L "$gg_safe_repo/aux" ] && [ -f "$gg_safe_outside/nul" ]; then
    t_ok "staged symlink and external target preserved"
  else t_fail "staged symlink or external target changed"; fi
  t_expect_rc 1 "$gg_safe_rc" "staged reserved symlink blocks safely"
  git -C "$gg_safe_repo" rm -q --cached aux
  rm -f "$gg_safe_repo/aux"

  (cd "$gg_safe_repo" && NUKENUL_MANDATORY=1 sh -x "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  gg_safe_walks="$(grep -cE '^\+ (/usr/bin/find|find) ' "$gg_safe_log" || true)"
  gg_safe_native="$(grep -c '^INVENTORY_OK:' "$gg_safe_log" || true)"
  gg_safe_total=$((gg_safe_walks + gg_safe_native))
  t_expect_rc 1 "$gg_safe_total" "exactly one native inventory or recursive find invocation"
  gg_safe_ambiguous="$(mktemp -d "$GG_T_TMPROOT/ambiguous.XXXXXX")"
  git init -q "$gg_safe_ambiguous/tree"
  git init -q "$gg_safe_ambiguous/tree
"
  : > "$gg_safe_ambiguous/tree/nul"
  : > "$gg_safe_ambiguous/tree
/nul"
  (cd "$gg_safe_ambiguous/tree
" && sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 1 ] && [ -e "$gg_safe_ambiguous/tree/nul" ] && [ -e "$gg_safe_ambiguous/tree
/nul" ]; then
    t_ok "trailing-newline Git root refused without touching its ordinary sibling"
  else t_fail "ambiguous Git root touched a sibling or was not refused"; fi
  git init -q "$gg_safe_ambiguous/space root[one]"
  : > "$gg_safe_ambiguous/space root[one]/NUL.txt"
  (cd "$gg_safe_ambiguous/space root[one]" && sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 0 ] && [ ! -e "$gg_safe_ambiguous/space root[one]/NUL.txt" ]; then
    t_ok "space and glob-containing active root handled literally"
  else t_fail "space/glob active root mishandled"; fi
  git init --bare -q "$gg_safe_repo/bare-mirror"
  : > "$gg_safe_repo/bare-mirror/refs/CON.lock"
  (cd "$gg_safe_repo" && sh "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  if [ -f "$gg_safe_repo/bare-mirror/refs/CON.lock" ] && grep -q 'PRESERVED_SCOPE:.*bare-mirror' "$gg_safe_log"; then
    t_ok "foreign bare Git transaction file preserved and scope reported"
  else t_fail "foreign bare repository traversed or not reported"; fi

  # A separate Git metadata directory at an ordinary, glob-containing path is
  # still out of scope. No commits or installed hooks are needed for this fixture.
  gg_safe_separate="$(mktemp -d "$GG_T_TMPROOT/separate.XXXXXX")"
  git init -q --separate-git-dir="$gg_safe_separate/metadata[one]" "$gg_safe_separate/tree"
  : > "$gg_safe_separate/metadata[one]/nul"
  (cd "$gg_safe_separate/tree" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  if [ -f "$gg_safe_separate/metadata[one]/nul" ]; then t_ok "separate Git metadata preserved"; else t_fail "separate Git metadata deleted"; fi

  # Direct .git metadata within a worktree at a nonstandard basename is also
  # protected (the first fixture above places it outside the scanned root).
  gg_safe_inside="$(mktemp -d "$GG_T_TMPROOT/inside.XXXXXX")"
  mkdir "$gg_safe_inside/tree"
  git init -q --separate-git-dir="$gg_safe_inside/tree/metadata[one]" "$gg_safe_inside/tree"
  : > "$gg_safe_inside/tree/metadata[one]/nul"
  (cd "$gg_safe_inside/tree" && NUKENUL_MANDATORY=1 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  if [ -f "$gg_safe_inside/tree/metadata[one]/nul" ]; then t_ok "in-worktree glob-containing metadata boundary protected"; else t_fail "in-worktree metadata deleted"; fi

  # Synthetic tool seams force mutation AFTER observed metadata, or an unlink
  # failure. Only disposable fixture files are changed; no deployed hook runs.
  gg_safe_tools="$gg_safe_repo/tools"
  mkdir "$gg_safe_tools"
  gg_safe_real_stat="$(command -v stat)"
  gg_safe_real_rm="$(command -v rm)"
  cat > "$gg_safe_tools/stat" <<'GG_STAT'
#!/bin/sh
for last do :; done
if [ "$last" = "$GG_SAFE_RACE_FILE" ] && [ "$GG_SAFE_RACE_KIND" = statfail ]; then exit 1; fi
if [ "$last" = "${GG_SAFE_RACE_FILE%/*}" ] && [ "$GG_SAFE_RACE_KIND" = parentstat ]; then exit 1; fi
"$GG_SAFE_REAL_STAT" "$@" || exit 1
if [ "$last" = "$GG_SAFE_RACE_FILE" ] && [ ! -e "$GG_SAFE_RACE_MARKER" ]; then
  : > "$GG_SAFE_RACE_MARKER"
  case "$GG_SAFE_RACE_KIND" in
    grow) printf 'concurrent data\n' >> "$last" ;;
    replace) mv "$last" "$last.original"; : > "$last" ;;
    symlink) "$GG_SAFE_REAL_RM" "$last"; ln -s "$GG_SAFE_OUTSIDE/nul" "$last" ;;
    parent) mv "${last%/*}" "${last%/*}.original"; mkdir "${last%/*}"; mv "${last%/*}.original/nul" "$last" ;;
  esac
fi
GG_STAT
  chmod +x "$gg_safe_tools/stat"
  for gg_safe_kind in grow replace symlink parent statfail parentstat; do
    mkdir -p "$gg_safe_repo/race"
    : > "$gg_safe_repo/race/nul"
    git -C "$gg_safe_repo" add -f race/nul
    rm -f "$gg_safe_repo/race-marker"
    (cd "$gg_safe_repo" && PATH="$gg_safe_tools:$PATH" GG_SAFE_REAL_STAT="$gg_safe_real_stat" \
      GG_SAFE_REAL_RM="$gg_safe_real_rm" GG_SAFE_RACE_FILE="$gg_safe_repo/race/nul" \
      GG_SAFE_RACE_MARKER="$gg_safe_repo/race-marker" GG_SAFE_RACE_KIND="$gg_safe_kind" \
      GG_SAFE_OUTSIDE="$gg_safe_outside" sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
    if [ "$gg_safe_rc" = 1 ] && { [ -e "$gg_safe_repo/race/nul" ] || [ -L "$gg_safe_repo/race/nul" ]; }; then
      t_ok "observed $gg_safe_kind mutation preserved and blocks"
    else t_fail "observed $gg_safe_kind mutation was not preserved/blocking"; fi
    git -C "$gg_safe_repo" rm -rq --cached --ignore-unmatch race
    rm -rf "$gg_safe_repo/race" "$gg_safe_repo/race.original"
  done
  rm -f "$gg_safe_tools/stat"
  cat > "$gg_safe_tools/rm" <<'GG_RM'
#!/bin/sh
for arg do
  if [ "$arg" = "$GG_SAFE_DELETE_FILE" ]; then exit 1; fi
done
exec "$GG_SAFE_REAL_RM" "$@"
GG_RM
  chmod +x "$gg_safe_tools/rm"
  : > "$gg_safe_repo/nul"
  git -C "$gg_safe_repo" add -f nul
  (cd "$gg_safe_repo" && PATH="$gg_safe_tools:$PATH" GG_SAFE_REAL_RM="$gg_safe_real_rm" \
    GG_SAFE_DELETE_FILE="$gg_safe_repo/nul" NUKENUL_MANDATORY=0 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 1 ] && [ -f "$gg_safe_repo/nul" ] && grep -q ERROR_DELETE "$gg_safe_log"; then
    t_ok "failed unlink preserved/reported even when legacy mandatory flag is off"
  else t_fail "unlink failure swallowed or file lost"; fi
  git -C "$gg_safe_repo" rm -q --cached nul
  rm -f "$gg_safe_tools/rm" "$gg_safe_repo/nul"
  if [ "$(uname -s):$(uname -m)" = Linux:x86_64 ] && command -v rustc >/dev/null 2>&1; then
    : > "$gg_safe_repo/nul"
    cat > "$gg_safe_tools/rustc" <<'GG_BUILD_FAIL'
#!/bin/sh
exit 7
GG_BUILD_FAIL
    chmod +x "$gg_safe_tools/rustc"
    (cd "$gg_safe_repo" && PATH="$gg_safe_tools:$PATH" sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
    # Toolchain trouble never blocks: warn, then the POSIX scan does the work.
    if [ "$gg_safe_rc" = 0 ] && [ ! -e "$gg_safe_repo/nul" ] && grep -q WARN_INVENTORY_BUILD "$gg_safe_log"; then
      t_ok "native compilation failure warns and falls back to the POSIX scan"
    else t_fail "native compilation failure blocked or skipped the POSIX fallback"; fi
    : > "$gg_safe_repo/nul"
    cat > "$gg_safe_tools/rustc" <<'GG_PARTIAL_INVENTORY'
#!/bin/sh
for arg do output=$arg; done
cat > "$output" <<'GG_PARTIAL_PROGRAM'
#!/bin/sh
printf '%s\000' "$GG_SAFE_NATIVE_CANDIDATE"
exit 1
GG_PARTIAL_PROGRAM
chmod +x "$output"
GG_PARTIAL_INVENTORY
    (cd "$gg_safe_repo" && PATH="$gg_safe_tools:$PATH" GG_SAFE_NATIVE_CANDIDATE="$gg_safe_repo/nul" \
      sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
    if [ "$gg_safe_rc" = 0 ] && [ ! -e "$gg_safe_repo/nul" ] && grep -q WARN_INVENTORY_RUN "$gg_safe_log" &&
      ! grep -q INVENTORY_OK "$gg_safe_log"; then
      t_ok "failed native inventory is discarded and the POSIX scan takes over"
    else t_fail "failed native inventory blocked or skipped the POSIX fallback"; fi
    rm -f "$gg_safe_tools/rustc" "$gg_safe_repo/nul"
  else
    t_skip "native inventory failure fixtures require qualified Linux x64 Rust compiler"
  fi
  # A private copy changes only find dispatch, injecting a traversal error into
  # the actual caller/status path without a public production override.
  cat > "$gg_safe_tools/failing-find" <<'GG_FIND'
#!/bin/sh
exit 1
GG_FIND
  chmod +x "$gg_safe_tools/failing-find"
  sed 's|if ! /usr/bin/find "$root"|if ! "$GG_SAFE_FIND_FAILURE" "$root"|' "$gg_safe_hook" > "$gg_safe_tools/find-failure-hook.sh"
  : > "$gg_safe_repo/nul"
  (cd "$gg_safe_repo" && GG_SAFE_FIND_FAILURE="$gg_safe_tools/failing-find" \
    sh "$gg_safe_tools/find-failure-hook.sh" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 0 ] && [ -e "$gg_safe_repo/nul" ] && grep -q WARN_TRAVERSAL "$gg_safe_log"; then
    t_ok "traversal failure reported as a warning without removing candidate"
  else t_fail "traversal failure blocked, was swallowed, or lost a candidate"; fi
  rm -f "$gg_safe_repo/nul"
  : > "$gg_safe_repo/aux"
  ln "$gg_safe_repo/aux" "$gg_safe_repo/shared-link"
  git -C "$gg_safe_repo" add -f aux
  (cd "$gg_safe_repo" && sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 1 ] && [ -e "$gg_safe_repo/aux" ] && [ -e "$gg_safe_repo/shared-link" ]; then
    t_ok "shared hardlink identity preserved and blocks"
  else t_fail "shared identity deleted"; fi
  git -C "$gg_safe_repo" rm -q --cached aux
  rm -f "$gg_safe_repo/aux" "$gg_safe_repo/shared-link"

  # A repository rooted at HOME (a dotfiles work tree) is never walked or
  # cleaned, but it is not locked out either.
  : > "$gg_safe_repo/nul"
  gg_safe_physical="$(cd "$gg_safe_repo" && pwd -P)"
  ln -s "$gg_safe_physical" "$GG_T_TMPROOT/home-link"
  for gg_safe_home in "$gg_safe_physical" "$GG_T_TMPROOT/home-link"; do
    (cd "$gg_safe_repo" && HOME="$gg_safe_home" sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
    if [ "$gg_safe_rc" = 0 ] && [ -e "$gg_safe_repo/nul" ] && grep -q '^SKIPPED_CLEANUP:' "$gg_safe_log"; then
      t_ok "HOME-rooted repository skips cleanup without blocking ($gg_safe_home)"
    else t_fail "HOME-rooted repository blocked or was cleaned ($gg_safe_home)"; fi
  done
  rm -f "$GG_T_TMPROOT/home-link"

  # Git Bash / MSYS2 / Cygwin run this same shell script. Deletion is not
  # qualified there, so it must be audit-only: report, never remove.
  cat > "$gg_safe_tools/uname" <<'GG_UNAME'
#!/bin/sh
case "${1:-}" in
  -m) echo x86_64 ;;
  *) echo MINGW64_NT-10.0-19045 ;;
esac
GG_UNAME
  chmod +x "$gg_safe_tools/uname"
  (cd "$gg_safe_repo" && unset MSYSTEM && PATH="$gg_safe_tools:$PATH" sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 0 ] && [ -e "$gg_safe_repo/nul" ] && grep -q '^WOULD_REMOVE_ZERO_BYTE' "$gg_safe_log" &&
    ! grep -q '^INVENTORY_OK:' "$gg_safe_log"; then
    t_ok "MINGW uname: POSIX path is audit-only (reported, not removed)"
  else t_fail "MINGW uname: shell hook deleted or did not report"; fi
  rm -f "$gg_safe_tools/uname"
  (cd "$gg_safe_repo" && MSYSTEM=MINGW64 sh "$gg_safe_hook" >"$gg_safe_log" 2>&1); gg_safe_rc=$?
  if [ "$gg_safe_rc" = 0 ] && [ -e "$gg_safe_repo/nul" ] && grep -q '^WOULD_REMOVE_ZERO_BYTE' "$gg_safe_log"; then
    t_ok "MSYSTEM set: shell hook is audit-only (reported, not removed)"
  else t_fail "MSYSTEM set: shell hook deleted or did not report"; fi
  rm -f "$gg_safe_repo/nul"
  cat > "$gg_safe_tools/NukeNul.exe" <<'GG_ACCEL'
#!/bin/sh
touch "$GG_SAFE_ACCEL_MARKER"
exit 0
GG_ACCEL
  chmod +x "$gg_safe_tools/NukeNul.exe"
  (cd "$gg_safe_repo" && NUKENUL_BIN="$gg_safe_tools/NukeNul.exe" \
    GG_SAFE_ACCEL_MARKER="$gg_safe_repo/accelerator-ran" sh "$gg_safe_hook" >"$gg_safe_log" 2>&1)
  if [ ! -e "$gg_safe_repo/accelerator-ran" ]; then t_ok "unqualified accelerator never executed"; else t_fail "unqualified accelerator ran"; fi
  gg_rmrepo "$gg_safe_repo"
  rm -rf "$gg_safe_separate" "$gg_safe_inside"
  rm -rf "$gg_safe_ambiguous"
  rm -rf "$gg_safe_outside"
  rm -f "$gg_safe_log"
}
