#!/bin/sh
#
# git-guard test harness — shared helpers (POSIX sh, shellcheck-clean).
#
# Sourced by tests/run.sh and every tests/*.t.sh case. Provides:
#   * result accounting (pass/fail/skip counters + an ASSERT/SKIP API),
#   * hermetic temp-repo creation with automatic cleanup,
#   * tool/platform capability probes (so a case self-SKIPs with a reason
#     instead of failing when ast-grep/shellcheck/ruff/pyyaml/docker is absent),
#   * runtime fixture generators (NEVER commit a planted secret / invalid file
#     into this repo — git-guard's own gate would block the test commit; we
#     synthesize fixtures inside the throwaway temp repos at run time).
#
# Resolution: GG_ROOT is exported by run.sh (the git-guard checkout root). The
# whole suite runs with GIT_GUARD_RULES_DIR pinned to the bundled rules-examples
# so the machine-local private overlay (qa-gate.conf.local) cannot leak in.

# --- result accounting -------------------------------------------------------
GG_T_PASS=0
GG_T_FAIL=0
GG_T_SKIP=0
GG_T_CURRENT="?"

t_begin() { GG_T_CURRENT="$1"; printf '\n=== %s ===\n' "$1" >&2; }

# t_ok   MSG     — record a passed assertion.
t_ok()   { GG_T_PASS=$((GG_T_PASS + 1)); printf '  [ok]   %s\n' "$1" >&2; }
# t_fail MSG     — record a failed assertion (does not abort the suite).
t_fail() { GG_T_FAIL=$((GG_T_FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }
# t_skip MSG     — record a skip-with-reason.
t_skip() { GG_T_SKIP=$((GG_T_SKIP + 1)); printf '  [skip] %s\n' "$1" >&2; }

# t_expect_rc EXPECTED ACTUAL MSG — assert two exit codes match.
t_expect_rc() {
  if [ "$1" = "$2" ]; then t_ok "$3 (rc=$2)"; else t_fail "$3 (expected rc=$1, got rc=$2)"; fi
}

# t_assert COND_RC MSG — COND_RC is the exit status of a prior test command.
t_assert() { if [ "$1" = "0" ]; then t_ok "$2"; else t_fail "$2"; fi }

# --- capability probes -------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# True only when `sg`/`ast-grep` on PATH is GENUINELY ast-grep (not util-linux
# set-group, which shadows it on Linux/WSL and makes the structural scan no-op).
gg_has_astgrep() {
  if have sg && sg --version 2>/dev/null | grep -qi 'ast-grep'; then return 0; fi
  have ast-grep
}
gg_has_shellcheck() { have shellcheck; }
gg_has_ruff()       { have ruff; }
gg_has_python()     { have python || have python3; }
gg_python() { if have python; then echo python; else echo python3; fi; }
gg_has_pyyaml()     { "$(gg_python)" -c "import yaml" >/dev/null 2>&1; }
gg_has_docker()     { have docker && docker info >/dev/null 2>&1; }

# Are we on native Windows (Git-Bash/MSYS/Cygwin)? Reserved-name (NUL) files
# cannot be created there, so the NUL-cleanup case skips on Windows.
gg_is_windows() {
  case "$(uname -s 2>/dev/null || echo)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

# --- hermetic temp repo ------------------------------------------------------
# gg_mktemp_repo — create an isolated git repo in a fresh temp dir, echo its
# path. The caller is responsible for `gg_rmrepo` (or relies on the suite-level
# trap that cleans GG_T_TMPROOT). A clean git identity + gpgsign off so the
# gate's internal scratch commits never prompt or fail.
gg_mktemp_repo() {
  d="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg.XXXXXX")" || return 1
  (
    cd "$d" || exit 1
    git init -q
    git config user.email tester@git-guard.local
    git config user.name  git-guard-tester
    git config commit.gpgsign false
    git config core.autocrlf false
  ) || return 1
  printf '%s' "$d"
}

gg_rmrepo() { [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null; return 0; }

# Run the QA gate directly inside a prepared repo (staged files already added).
# Echoes nothing; returns the gate's exit code (0 = pass/all-warn, 1 = blocked).
gg_run_gate() {
  ( cd "$1" && GIT_GUARD_RULES_DIR="$GG_BUNDLED" sh "$GG_ROOT/hooks/common/qa_gate.sh" >/dev/null 2>&1 )
}

# Same, but capture stderr to a file ($2) for message assertions.
gg_run_gate_log() {
  ( cd "$1" && GIT_GUARD_RULES_DIR="$GG_BUNDLED" sh "$GG_ROOT/hooks/common/qa_gate.sh" >/dev/null 2>"$2" )
}

# --- runtime fixture generators (assembled, never committed to THIS repo) ----
# A static-mut Rust file that trips the BLOCK trio rule avoid-static-mut.
gg_fixture_static_mut() {
  mkdir -p "$1/src"
  printf 'static mut COUNTER: u32 = 0;\nfn main() { unsafe { COUNTER += 1; } }\n' > "$1/src/bad.rs"
}
# A glob-reexport Rust file (no-glob-reexport trio rule).
gg_fixture_glob_reexport() {
  mkdir -p "$1/src"
  printf 'mod inner { pub fn a() {} }\npub use inner::*;\n' > "$1/src/lib.rs"
}
# An unsafe block containing a panic-family call (unsafe-with-panic trio rule).
gg_fixture_unsafe_panic() {
  mkdir -p "$1/src"
  printf 'fn main() {\n    unsafe {\n        let p: *const i32 = std::ptr::null();\n        if p.is_null() { panic!("boom"); }\n    }\n}\n' > "$1/src/up.rs"
}
# A plausible-but-FAKE secret line. Assembled from fragments so this very script
# does not trip secret_scan when it is itself committed into git-guard.
gg_fixture_fake_secret() {
  pfx="AKIA"; body="EXAMPLEFAKEKEY42"   # pragma: allowlist secret
  printf 'const KEY = "%s%s";\n' "$pfx" "$body" > "$1/leak.js"   # pragma: allowlist secret
}
# Invalid JSON.
gg_fixture_bad_json()  { printf '{ "a": 1, }\n' > "$1/broken.json"; }
# Valid JSON.
gg_fixture_good_json() { printf '{ "a": 1 }\n' > "$1/ok.json"; }
# Invalid YAML (a tab-indented mapping under a key — a YAML syntax error).
gg_fixture_bad_yaml()  { printf 'a:\n  b: 1\n   c: 2\n' > "$1/broken.yml"; }
