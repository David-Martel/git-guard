#!/bin/sh
# Category 39 — `git-guard doctor` answers "is this host covered?" with an
# exit code: --require-installed, --repo, --strict and --wsl.
#
# Why: a push left a WSL distro with no hooks path and merged without hooks
# (vigil-utils #1403, 2026-11-05). A hook cannot report its own absence, so the
# check has to be a command. Carbon also ran a stale real ~/.git-hooks copy, and
# repo-local core.hooksPath overrides silently skip git-guard.
#
# Every case runs with an isolated HOME and GIT_CONFIG_GLOBAL, no system
# config, and stubs for wsl.exe/uname: no real distro is queried or started.
# shellcheck shell=sh

# t_dr_run HOME LOG [ARGS...] — run doctor in the isolated HOME; returns its rc.
t_dr_run() {
  _h="$1"; _l="$2"; shift 2
  ( HOME="$_h" GIT_CONFIG_GLOBAL="$_h/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      sh "$GG_ROOT/bin/git-guard" doctor "$@" ) > "$_l" 2>&1
}

# t_dr_has LOG PATTERN MSG — assert the doctor output matches an ERE.
t_dr_has() {
  if grep -Eq -- "$2" "$1"; then t_ok "$3"; else t_fail "$3"; sed 's/^/      | /' "$1" >&2; fi
}
t_dr_lacks() {
  if grep -Eq -- "$2" "$1"; then t_fail "$3"; sed 's/^/      | /' "$1" >&2; else t_ok "$3"; fi
}

t_case_doctor_coverage() {
  t_begin "39 doctor: host coverage is checkable (--require-installed/--repo/--strict/--wsl)"
  dr_root="$(mktemp -d "$GG_T_TMPROOT/doctor39.XXXXXX")" || { t_fail "mktemp"; return 1; }
  dr_log="$dr_root/doctor.log"

  # --- A. nothing installed ---------------------------------------------------
  dr_home="$dr_root/home-unset"; mkdir -p "$dr_home"
  t_dr_run "$dr_home" "$dr_log"; rc=$?
  t_expect_rc 0 "$rc" "unset hooksPath without flags is not a failure (CI smoke-test usage)"
  t_dr_has "$dr_log" '^git-guard doctor: NOT COVERED \(git-guard is not installed' \
    "unset hooksPath is never reported as COVERED"
  t_dr_run "$dr_home" "$dr_log" --require-installed; rc=$?
  t_expect_rc 1 "$rc" "--require-installed fails when core.hooksPath is unset"
  t_dr_has "$dr_log" '^  \[FAIL\] hooks-path +core.hooksPath is unset' "--require-installed names the unset hooks path"
  t_dr_has "$dr_log" '^git-guard doctor: NOT COVERED \(1 failures\)' "verdict line counts the failure"
  t_dr_run "$dr_home" "$dr_log" --bogus; rc=$?
  t_expect_rc 2 "$rc" "an unknown doctor option is a usage error"

  # --- B. stale legacy copy: a real hooks dir with no VERSION beside it --------
  dr_home="$dr_root/home-stale"; mkdir -p "$dr_home/.git-hooks"
  printf '#!/bin/sh\nexit 0\n' > "$dr_home/.git-hooks/pre-commit"
  chmod +x "$dr_home/.git-hooks/pre-commit"
  git config --file "$dr_home/.gitconfig" core.hooksPath "$dr_home/.git-hooks"
  t_dr_run "$dr_home" "$dr_log"; rc=$?
  t_expect_rc 0 "$rc" "stale copy without --require-installed stays a warning"
  t_dr_has "$dr_log" '^  \[warn\] hooks-version .*stale legacy copy' "stale real hooks dir is reported"
  t_dr_run "$dr_home" "$dr_log" --require-installed; rc=$?
  t_expect_rc 1 "$rc" "--require-installed fails on a stale legacy hooks copy"
  t_dr_has "$dr_log" '^  \[FAIL\] hooks-version .*stale legacy copy.*git-guard install' "the failure names the fix"
  t_dr_run "$dr_home" "$dr_log" --strict; rc=$?
  t_expect_rc 1 "$rc" "--strict turns the stale-copy warning into a failure"

  # --- C. an installed release (hooks/ with VERSION beside it) ----------------
  dr_home="$dr_root/home-good"
  dr_rel="$dr_home/.local/share/git-guard/v9.9.9"
  mkdir -p "$dr_rel/hooks"
  printf '9.9.9\n' > "$dr_rel/VERSION"
  for dr_h in pre-commit pre-push; do
    printf '#!/bin/sh\nexit 0\n' > "$dr_rel/hooks/$dr_h"; chmod +x "$dr_rel/hooks/$dr_h"
  done
  git config --file "$dr_home/.gitconfig" core.hooksPath "$dr_rel/hooks"
  t_dr_run "$dr_home" "$dr_log" --require-installed; rc=$?
  t_expect_rc 0 "$rc" "--require-installed passes an installed release"
  t_dr_has "$dr_log" '^git-guard doctor: COVERED$' "covered host prints the COVERED verdict"

  # --- D. --repo --------------------------------------------------------------
  dr_inherit="$(gg_mktemp_repo)"
  t_dr_run "$dr_home" "$dr_log" --repo "$dr_inherit"; rc=$?
  t_expect_rc 0 "$rc" "--repo: a repo inheriting the global hooks path passes"
  t_dr_has "$dr_log" '^  \[ok\]   repo-hooks .*\(global: .*-> git-guard hooks' "--repo reports the effective global hooks path"

  dr_local="$(gg_mktemp_repo)"
  mkdir -p "$dr_local/.githooks"
  for dr_h in pre-commit pre-push; do
    printf '#!/bin/sh\necho repo-own %s\n' "$dr_h" > "$dr_local/.githooks/$dr_h"; chmod +x "$dr_local/.githooks/$dr_h"
  done
  git -C "$dr_local" config core.hooksPath .githooks
  t_dr_run "$dr_home" "$dr_log" --repo "$dr_local"; rc=$?
  t_expect_rc 1 "$rc" "--repo: a repo-local hooks path that never calls git-guard fails"
  t_dr_has "$dr_log" '^  \[FAIL\] repo-hooks +core.hooksPath=.githooks \(local: .*git-guard hooks never run here' \
    "--repo names the local override and its scope"

  for dr_h in pre-commit pre-push; do
    printf '#!/bin/sh\nexec "$HOME/.git-hooks/%s" "$@"\n' "$dr_h" > "$dr_local/.githooks/$dr_h"
  done
  t_dr_run "$dr_home" "$dr_log" --repo "$dr_local"; rc=$?
  t_expect_rc 0 "$rc" "--repo: a local override that delegates to git-guard is a warning"
  t_dr_has "$dr_log" '^  \[warn\] repo-hooks .*name git-guard' "--repo reports the delegating override"
  t_dr_run "$dr_home" "$dr_log" --repo "$dr_local" --strict; rc=$?
  t_expect_rc 1 "$rc" "--strict fails a delegating override (not verified by running it)"

  dr_bare="$dr_root/bare.git"; git init -q --bare "$dr_bare"
  t_dr_run "$dr_home" "$dr_log" --repo "$dr_bare"; rc=$?
  t_dr_has "$dr_log" '^  \[--\]   repo +bare repository: .*git worktree add' "--repo explains the bare-repository route"
  t_dr_run "$dr_home" "$dr_log" --repo "$dr_root/not-a-repo"; rc=$?
  t_expect_rc 1 "$rc" "--repo on a non-repository fails"

  # Declared providers: a PATH holding only the tools doctor needs, so the
  # provider is certainly absent, then a stub provider makes it present.
  dr_min=""
  for dr_t in git sh grep sed dirname cat uname tr; do
    dr_d="$(dirname "$(command -v "$dr_t")")"
    case ":$dr_min:" in *":$dr_d:"*) : ;; *) dr_min="${dr_min:+$dr_min:}$dr_d" ;; esac
  done
  dr_prov="$(gg_mktemp_repo)"
  printf 'repos: []\n' > "$dr_prov/.pre-commit-config.yaml"
  if PATH="$dr_min" command -v pre-commit >/dev/null 2>&1; then
    t_skip "pre-commit is installed beside git/sh on this host; cannot make it absent"
  else
    ( PATH="$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_prov" ); rc=$?
    t_expect_rc 1 "$rc" "--repo: declared pre-commit config with no pre-commit on PATH fails"
    t_dr_has "$dr_log" '^  \[FAIL\] provider +\.pre-commit-config declared but pre-commit is not on PATH' \
      "--repo names the missing declared provider"
  fi
  dr_stub="$dr_root/stub-bin"; mkdir -p "$dr_stub"
  printf '#!/bin/sh\nexit 0\n' > "$dr_stub/pre-commit"; chmod +x "$dr_stub/pre-commit"
  ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_prov" ); rc=$?
  t_dr_has "$dr_log" '^  \[ok\]   provider +\.pre-commit-config declared; pre-commit ' "--repo reports a runnable declared provider"

  # PyYAML probe: an interpreter that cannot import yaml is a coverage warning.
  printf '#!/bin/sh\nexit 1\n' > "$dr_stub/python"; chmod +x "$dr_stub/python"
  cp "$dr_stub/python" "$dr_stub/python3"
  ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_inherit" ); rc=$?
  t_expect_rc 0 "$rc" "missing PyYAML is a warning by default"
  t_dr_has "$dr_log" '^  \[warn\] pyyaml ' "--repo reports a Python without PyYAML"
  ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_inherit" --strict ); rc=$?
  t_expect_rc 1 "$rc" "--strict fails on missing PyYAML"

  # --- E. --wsl with stubs: never the real wsl.exe ----------------------------
  dr_wsl="$dr_root/wsl-bin"; mkdir -p "$dr_wsl"
  dr_started="$dr_root/wsl-started"
  printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' > "$dr_wsl/uname"
  # Distro lists come back as UTF-16LE with CRLF, as the real tool prints them.
  cat > "$dr_wsl/wsl.exe" <<'STUB'
#!/bin/sh
utf16() {
  for n in "$@"; do
    while [ -n "$n" ]; do c="${n%"${n#?}"}"; n="${n#?}"; printf '%s\000' "$c"; done
    printf '\r\000\n\000'
  done
}
case "$*" in
  "-l -q") utf16 Alpha Beta Gamma Delta ;;
  "-l -q --running") utf16 Alpha Beta Delta ;;
  "-d "*)
    printf '%s\n' "$2" >> "$GG_T_WSL_STARTED"
    case "$2" in
      Alpha) printf '2.43.0|~/.git-hooks|ok\r\n' ;;
      Beta)  printf '2.43.0||missing\r\n' ;;
      Gamma) printf '2.39.2||missing\r\n' ;;
      Delta) printf '2.34.1|/home/d/.git-hooks|ok\r\n' ;;
    esac ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$dr_wsl/uname" "$dr_wsl/wsl.exe"
  ( PATH="$dr_wsl:$PATH"; GG_T_WSL_STARTED="$dr_started"; export PATH GG_T_WSL_STARTED
    t_dr_run "$dr_home" "$dr_log" --wsl ); rc=$?
  t_expect_rc 1 "$rc" "--wsl fails when a running distro has no hooks path"
  t_dr_has "$dr_log" '^  \[ok\]   wsl +Alpha \(git 2\.43\.0\): core\.hooksPath=~/\.git-hooks' "--wsl reports a covered distro"
  t_dr_has "$dr_log" '^  \[FAIL\] wsl +Beta .*core\.hooksPath unset' "--wsl fails the uncovered distro"
  t_dr_has "$dr_log" '^  \[warn\] wsl +Gamma: stopped, not checked' "--wsl reports a stopped distro as not checked"
  t_dr_has "$dr_log" 'Delta \(git 2\.34\.1, older than 2\.36' "--wsl flags git older than 2.36"
  if grep -qx Gamma "$dr_started" 2>/dev/null; then t_fail "--wsl started a stopped distro"
  else t_ok "--wsl did not start the stopped distro"; fi
  ( PATH="$dr_wsl:$PATH"; GG_T_WSL_STARTED="$dr_started"; export PATH GG_T_WSL_STARTED
    t_dr_run "$dr_home" "$dr_log" --wsl-start ); rc=$?
  grep -qx Gamma "$dr_started" 2>/dev/null
  t_assert $? "--wsl-start queries (and so starts) the stopped distro"
  t_dr_has "$dr_log" '^  \[FAIL\] wsl +Gamma .*core\.hooksPath unset' "--wsl-start checks the started distro"

  printf '#!/bin/sh\necho Linux\n' > "$dr_wsl/uname"
  ( PATH="$dr_wsl:$PATH"; GG_T_WSL_STARTED="$dr_started"; export PATH GG_T_WSL_STARTED
    t_dr_run "$dr_home" "$dr_log" --wsl ); rc=$?
  t_expect_rc 0 "$rc" "--wsl is a no-op off Windows"
  t_dr_has "$dr_log" '^  \[--\]   wsl +not a Windows host' "--wsl says why it checked nothing"
  t_dr_lacks "$dr_log" 'Alpha' "--wsl off Windows never calls wsl.exe"

  gg_rmrepo "$dr_inherit"; gg_rmrepo "$dr_local"; gg_rmrepo "$dr_prov"
  rm -rf "$dr_root"
}
