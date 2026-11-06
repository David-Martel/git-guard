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
  # The caller's downstream-hook settings never leak in; cases pass their own.
  ( HOME="$_h" GIT_CONFIG_GLOBAL="$_h/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      GIT_GUARD_DOWNSTREAM_HOOK="${GG_T_DR_HOOK:-}" GIT_GUARD_DOWNSTREAM_PRE_PUSH="${GG_T_DR_PRE_PUSH:-}" \
      GIT_GUARD_ALLOW_MISSING_LEFTHOOK='' \
      sh "$GG_ROOT/bin/git-guard" doctor "$@" ) > "$_l" 2>&1
}

# t_dr_has LOG PATTERN MSG — assert the doctor output matches an ERE.
t_dr_has() {
  if grep -Eq -- "$2" "$1"; then t_ok "$3"; else t_fail "$3"; sed 's/^/      | /' "$1" >&2; fi
}
t_dr_lacks() {
  if grep -Eq -- "$2" "$1"; then t_fail "$3"; sed 's/^/      | /' "$1" >&2; else t_ok "$3"; fi
}

# t_dr_engines HOOKSDIR [SKIP] — stub the blocking engines a release ships
# (hooks/common/*), except SKIP. Doctor requires them executable, as the
# hooks run them only then.
t_dr_engines() {
  mkdir -p "$1/common"
  for _de in secret_scan.sh nul-cleanup.sh qa_gate.sh; do
    [ "$_de" = "${2:-}" ] && continue
    printf '#!/bin/sh\nexit 0\n' > "$1/common/$_de"; chmod +x "$1/common/$_de"
  done
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
  for dr_h in pre-commit pre-push; do
    printf '#!/bin/sh\nexit 0\n' > "$dr_home/.git-hooks/$dr_h"; chmod +x "$dr_home/.git-hooks/$dr_h"
  done
  t_dr_engines "$dr_home/.git-hooks"
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
  t_dr_engines "$dr_rel/hooks"
  git config --file "$dr_home/.gitconfig" core.hooksPath "$dr_rel/hooks"
  t_dr_run "$dr_home" "$dr_log" --require-installed; rc=$?
  t_expect_rc 0 "$rc" "--require-installed passes an installed release"
  t_dr_has "$dr_log" '^git-guard doctor: COVERED$' "covered host prints the COVERED verdict"
  for dr_var in GIT_GUARD LEFTHOOK; do
    ( eval "$dr_var=0; export $dr_var"; t_dr_run "$dr_home" "$dr_log" --require-installed ); rc=$?
    t_expect_rc 1 "$rc" "$dr_var=0 in the environment (every hook exits at once) is NOT COVERED"
    t_dr_has "$dr_log" "^  \\[FAIL\\] hooks-bypass +$dr_var=0 is set" "doctor names the $dr_var=0 bypass"
  done

  # A release missing pre-push (which carries the pushed-range secret scan) is
  # not covered, and a repo on that hooks dir is not certified either.
  dr_home_np="$dr_root/home-no-pre-push"
  dr_rel_np="$dr_home_np/.local/share/git-guard/v9.9.9"
  mkdir -p "$dr_rel_np/hooks"
  printf '9.9.9\n' > "$dr_rel_np/VERSION"
  printf '#!/bin/sh\nexit 0\n' > "$dr_rel_np/hooks/pre-commit"; chmod +x "$dr_rel_np/hooks/pre-commit"
  t_dr_engines "$dr_rel_np/hooks"
  git config --file "$dr_home_np/.gitconfig" core.hooksPath "$dr_rel_np/hooks"
  dr_np_repo="$(gg_mktemp_repo)"
  t_dr_run "$dr_home_np" "$dr_log" --require-installed --repo "$dr_np_repo"; rc=$?
  t_expect_rc 1 "$rc" "a release without pre-push is NOT COVERED"
  t_dr_has "$dr_log" '^  \[FAIL\] hooks-path .*but pre-push MISSING or not executable' "the failure names the missing pre-push"
  t_dr_lacks "$dr_log" '^  \[ok\]   repo-hooks' "a repo on that hooks dir is not certified [ok]"
  t_dr_has "$dr_log" '^git-guard doctor: NOT COVERED' "the verdict is NOT COVERED"
  gg_rmrepo "$dr_np_repo"

  # The hooks run common/secret_scan.sh only when it is executable, so a
  # release without it scans nothing: not covered either.
  dr_home_ns="$dr_root/home-no-scan"
  dr_rel_ns="$dr_home_ns/.local/share/git-guard/v9.9.9"
  mkdir -p "$dr_rel_ns/hooks"
  printf '9.9.9\n' > "$dr_rel_ns/VERSION"
  for dr_h in pre-commit pre-push; do
    printf '#!/bin/sh\nexit 0\n' > "$dr_rel_ns/hooks/$dr_h"; chmod +x "$dr_rel_ns/hooks/$dr_h"
  done
  t_dr_engines "$dr_rel_ns/hooks" secret_scan.sh
  git config --file "$dr_home_ns/.gitconfig" core.hooksPath "$dr_rel_ns/hooks"
  t_dr_run "$dr_home_ns" "$dr_log" --require-installed; rc=$?
  t_expect_rc 1 "$rc" "a release without common/secret_scan.sh is NOT COVERED"
  t_dr_has "$dr_log" '^  \[FAIL\] hooks-path .*but common/secret_scan\.sh MISSING or not executable' \
    "the failure names the missing engine"

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

  # Git runs only executable hooks, so a delegating wrapper that is not
  # executable delegates nothing. Git Bash reports -x from a #! line, not the
  # mode bits, so there the wrapper loses its #! line instead of its mode.
  for dr_h in pre-commit pre-push; do
    if gg_is_windows; then
      printf 'exec "$HOME/.git-hooks/%s" "$@"\n' "$dr_h" > "$dr_local/.githooks/$dr_h"
    else
      chmod 644 "$dr_local/.githooks/$dr_h"
    fi
  done
  t_dr_run "$dr_home" "$dr_log" --require-installed --repo "$dr_local"; rc=$?
  t_expect_rc 1 "$rc" "--repo: non-executable delegating wrappers are NOT COVERED"
  t_dr_has "$dr_log" '^  \[FAIL\] repo-hooks .*not an executable hook that calls git-guard: pre-commit pre-push' \
    "--repo says the wrappers are not executable"

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
    t_dr_has "$dr_log" '^  \[FAIL\] provider +pre-push: \.pre-commit-config declared but pre-commit is not on PATH' \
      "--repo names the missing declared provider"
  fi
  dr_stub="$dr_root/stub-bin"; mkdir -p "$dr_stub"
  printf '#!/bin/sh\nexit 0\n' > "$dr_stub/pre-commit"; chmod +x "$dr_stub/pre-commit"
  ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_prov" ); rc=$?
  t_dr_has "$dr_log" '^  \[ok\]   provider +pre-push: \.pre-commit-config; pre-commit ' "--repo reports a runnable declared provider"

  # Only the provider the hooks would SELECT must be runnable. Order:
  # downstream env hook, .git-guard/<hook>.local, lefthook, .pre-commit-config.
  dr_both="$(gg_mktemp_repo)"
  printf 'repos: []\n' > "$dr_both/.pre-commit-config.yaml"
  printf 'pre-push: {}\n' > "$dr_both/lefthook.yml"
  dr_lh_bin="$dr_root/lefthook-bin"; mkdir -p "$dr_lh_bin"
  printf '#!/bin/sh\nexit 0\n' > "$dr_lh_bin/lefthook"; chmod +x "$dr_lh_bin/lefthook"
  ( PATH="$dr_lh_bin:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --require-installed --repo "$dr_both" ); rc=$?
  t_expect_rc 0 "$rc" "lefthook + pre-commit configs, only lefthook installed: covered (lefthook is selected)"
  t_dr_has "$dr_log" '^  \[ok\]   provider +pre-push: lefthook\.yml; lefthook ' "doctor reports lefthook as the pre-push provider"
  t_dr_lacks "$dr_log" 'pre-commit is not on PATH' "doctor does not require the pre-commit provider lefthook overrides"
  t_dr_has "$dr_log" '^git-guard doctor: COVERED$' "the verdict is COVERED"
  ( PATH="$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_both" ); rc=$?
  t_expect_rc 1 "$rc" "lefthook selected but not installed fails"

  dr_local_prov="$(gg_mktemp_repo)"
  printf 'repos: []\n' > "$dr_local_prov/.pre-commit-config.yaml"
  mkdir -p "$dr_local_prov/.git-guard"
  for dr_h in pre-commit pre-push; do
    printf '#!/bin/sh\nexit 0\n' > "$dr_local_prov/.git-guard/$dr_h.local"; chmod +x "$dr_local_prov/.git-guard/$dr_h.local"
  done
  ( PATH="$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_local_prov" ); rc=$?
  t_expect_rc 0 "$rc" "executable .git-guard/<hook>.local hooks take precedence over .pre-commit-config"
  t_dr_has "$dr_log" '^  \[ok\]   provider +pre-push: \.git-guard/pre-push\.local' "doctor reports the .local hook as the provider"

  ( PATH="$dr_min"; GG_T_DR_PRE_PUSH="$dr_root/no-such-hook"; export PATH GG_T_DR_PRE_PUSH
    t_dr_run "$dr_home" "$dr_log" --repo "$dr_local_prov" ); rc=$?
  t_expect_rc 1 "$rc" "GIT_GUARD_DOWNSTREAM_PRE_PUSH naming no runnable file fails (it is selected first)"
  t_dr_has "$dr_log" '^  \[FAIL\] provider +pre-push: GIT_GUARD_DOWNSTREAM_PRE_PUSH=.*not a runnable file' \
    "doctor names the unrunnable downstream hook"
  # precommit-provider.sh refuses a symlinked config at pre-push, so a repo
  # whose selected provider reads one is not covered for pushes.
  dr_sym="$(gg_mktemp_repo)"
  printf 'repos: []\n' > "$dr_sym/real-config.yaml"
  if ln -s real-config.yaml "$dr_sym/.pre-commit-config.yaml" 2>/dev/null && [ -L "$dr_sym/.pre-commit-config.yaml" ]; then
    ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_sym" ); rc=$?
    t_expect_rc 1 "$rc" "a symlinked .pre-commit-config (refused at pre-push) is NOT COVERED"
    t_dr_has "$dr_log" '^  \[FAIL\] provider +pre-push: \.pre-commit-config\.yaml is a symlink' \
      "doctor names the symlinked config"
  else
    t_skip "symlinked .pre-commit-config NOT_TESTED: no native symlink here"
  fi
  gg_rmrepo "$dr_both"; gg_rmrepo "$dr_local_prov"; gg_rmrepo "$dr_sym"

  # PyYAML probe: only the interpreter the gate selects counts (qa_python.sh:
  # `python` first). A python3 WITH yaml behind a python WITHOUT it does not help.
  printf '#!/bin/sh\nexit 1\n' > "$dr_stub/python"; chmod +x "$dr_stub/python"
  printf '#!/bin/sh\nexit 0\n' > "$dr_stub/python3"; chmod +x "$dr_stub/python3"
  ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_inherit" ); rc=$?
  t_expect_rc 0 "$rc" "missing PyYAML is a warning by default"
  t_dr_has "$dr_log" "^  \\[warn\\] pyyaml .*the gate's interpreter. cannot import yaml" \
    "--repo reports the gate's Python without PyYAML, not a python3 behind it"
  ( PATH="$dr_stub:$dr_min"; export PATH; t_dr_run "$dr_home" "$dr_log" --repo "$dr_inherit" --strict ); rc=$?
  t_expect_rc 1 "$rc" "--strict fails on missing PyYAML"

  # --- E. --wsl with stubs: never the real wsl.exe ----------------------------
  # The stub runs doctor's REAL in-distro probe with a per-distro fake HOME, so
  # the same hook rules as the host are exercised, not canned answers.
  dr_wsl="$dr_root/wsl-bin"; mkdir -p "$dr_wsl"
  dr_started="$dr_root/wsl-started"
  dr_distro_root="$dr_root/distros"
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
if [ -n "${GG_T_WSL_NONE:-}" ]; then
  utf16 'Windows Subsystem for Linux has no installed distributions.'
  exit 255
fi
case "$*" in
  "-l -q") utf16 ${GG_T_WSL_ONLY:-Alpha Beta Gamma Delta Epsilon Zeta} ;;
  "-l -q --running") utf16 ${GG_T_WSL_ONLY:-Alpha Beta Delta Epsilon Zeta} ;;
  "-d "*" -e sh -c "*)
    printf '%s\n' "$2" >> "$GG_T_WSL_STARTED"
    h="$GG_T_WSL_ROOT/$2"; mkdir -p "$h"
    p="$PATH"; [ -d "$h/bin" ] && p="$h/bin:$PATH"
    HOME="$h" GIT_CONFIG_GLOBAL="$h/.gitconfig" GIT_CONFIG_NOSYSTEM=1 PATH="$p" sh -c "$6" | sed 's/$/\r/' ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$dr_wsl/uname" "$dr_wsl/wsl.exe"
  # dr_distro NAME HOOKS VERSION — a fake distro home with a release whose
  # hooks dir holds HOOKS (space-separated) and, if VERSION=yes, a VERSION.
  dr_distro() {
    _dh="$dr_distro_root/$1"; _drel="$_dh/.local/share/git-guard/v1"
    mkdir -p "$_drel/hooks"
    [ "$3" = yes ] && printf '1\n' > "$_drel/VERSION"
    for _dk in $2; do printf '#!/bin/sh\nexit 0\n' > "$_drel/hooks/$_dk"; chmod +x "$_drel/hooks/$_dk"; done
    t_dr_engines "$_drel/hooks"
    # shellcheck disable=SC2088  # a literal ~/ value, expanded by the probe
    git config --file "$_dh/.gitconfig" core.hooksPath '~/.local/share/git-guard/v1/hooks'
  }
  dr_distro Alpha "pre-commit pre-push" yes
  mkdir -p "$dr_distro_root/Beta" "$dr_distro_root/Gamma"
  dr_distro Delta "pre-commit pre-push" yes
  mkdir -p "$dr_distro_root/Delta/bin"
  printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.34.1"; exit 0; fi\nexec "$GG_T_REAL_GIT" "$@"\n' \
    > "$dr_distro_root/Delta/bin/git"
  chmod +x "$dr_distro_root/Delta/bin/git"
  dr_distro Epsilon "pre-commit" yes
  dr_distro Zeta "pre-commit pre-push" no
  dr_wsl_run() {
    ( PATH="$dr_wsl:$PATH"; GG_T_WSL_STARTED="$dr_started"; GG_T_WSL_ROOT="$dr_distro_root"
      GG_T_REAL_GIT="$(command -v git)"
      export PATH GG_T_WSL_STARTED GG_T_WSL_ROOT GG_T_REAL_GIT
      t_dr_run "$dr_home" "$dr_log" "$@" )
  }
  dr_wsl_run --wsl; rc=$?
  t_expect_rc 1 "$rc" "--wsl fails when a running distro is not covered"
  t_dr_has "$dr_log" '^  \[ok\]   wsl +Alpha \(git [0-9.]+[^)]*\): core\.hooksPath=~/\.local/share/git-guard/v1/hooks' "--wsl reports a covered distro"
  t_dr_has "$dr_log" '^  \[FAIL\] wsl +Beta .*core\.hooksPath unset' "--wsl fails a distro with no hooks path"
  t_dr_has "$dr_log" '^  \[warn\] wsl +Gamma: stopped, not checked' "--wsl reports a stopped distro as not checked"
  t_dr_has "$dr_log" 'Delta \(git 2\.34\.1, older than 2\.36' "--wsl flags git older than 2.36"
  t_dr_has "$dr_log" '^  \[FAIL\] wsl +Epsilon .*but pre-push MISSING or not executable' \
    "--wsl fails a distro whose hooks dir lacks pre-push (same rule as the host)"
  t_dr_has "$dr_log" '^  \[warn\] wsl +Zeta .*no git-guard VERSION' "--wsl warns on a distro's stale hooks copy"
  if grep -qx Gamma "$dr_started" 2>/dev/null; then t_fail "--wsl started a stopped distro"
  else t_ok "--wsl did not start the stopped distro"; fi
  dr_wsl_run --wsl --require-installed; rc=$?
  t_dr_has "$dr_log" '^  \[FAIL\] wsl +Zeta .*no git-guard VERSION' "--require-installed fails a distro's stale hooks copy"
  ( GG_T_WSL_ONLY="Alpha"; export GG_T_WSL_ONLY; dr_wsl_run --wsl --require-installed --strict ); rc=$?
  t_expect_rc 0 "$rc" "--wsl --require-installed --strict passes a fully covered distro"
  t_dr_has "$dr_log" '^git-guard doctor: COVERED$' "a fully covered distro gives COVERED"
  ( GG_T_WSL_ONLY="Epsilon"; export GG_T_WSL_ONLY; dr_wsl_run --wsl ); rc=$?
  t_expect_rc 1 "$rc" "a distro missing pre-push alone makes the host NOT COVERED"
  t_dr_has "$dr_log" '^git-guard doctor: NOT COVERED' "the verdict is NOT COVERED"
  dr_wsl_run --wsl-start; rc=$?
  grep -qx Gamma "$dr_started" 2>/dev/null
  t_assert $? "--wsl-start queries (and so starts) the stopped distro"
  t_dr_has "$dr_log" '^  \[FAIL\] wsl +Gamma .*core\.hooksPath unset' "--wsl-start checks the started distro"
  ( GG_T_WSL_NONE=1; export GG_T_WSL_NONE; dr_wsl_run --wsl ); rc=$?
  t_expect_rc 0 "$rc" "--wsl with no distros installed is not a failure"
  t_dr_has "$dr_log" '^  \[--\]   wsl +no distros installed' "--wsl reads wsl.exe's no-distro message as no distros"
  t_dr_lacks "$dr_log" 'wsl +(Windows|Subsystem|installed\.)' "--wsl never treats that message as distro names"

  printf '#!/bin/sh\necho Linux\n' > "$dr_wsl/uname"
  dr_wsl_run --wsl; rc=$?
  t_expect_rc 0 "$rc" "--wsl is a no-op off Windows"
  t_dr_has "$dr_log" '^  \[--\]   wsl +not a Windows host' "--wsl says why it checked nothing"
  t_dr_lacks "$dr_log" 'Alpha' "--wsl off Windows never calls wsl.exe"

  gg_rmrepo "$dr_inherit"; gg_rmrepo "$dr_local"; gg_rmrepo "$dr_prov"
  rm -rf "$dr_root"
}
