#!/bin/sh
# Category 28 — failing AND passing inputs for the default-on checks that had
# only one of the two (or neither).
#
# Behaviour protected:
#   * qa_gate.sh: shell.shellcheck=block and python.ruff_check=block refuse a
#     staged finding and pass clean code; validate.json / validate.yaml pass
#     well-formed files (category 1 only proves they block broken ones); a clean
#     Rust file passes the BLOCK trio; qa.enabled=off is an escape hatch; the
#     large-file guard warns above largefile_kb and stays quiet below it.
#   * hooks/pre-commit: the protected-branch WARN (step 4) and the
#     partial-staging WARN (step 5) appear when their condition holds and not
#     otherwise, and neither blocks.
#   * hooks/post-commit: prints the SHA that actually landed.
#   * branch-protection.sh: refuses to run without a repository and, in
#     --dry-run, emits a parseable ruleset with the four protections it claims.
#
# What a failure means: a check that blocks clean code bricks every repo that
# uses git-guard (the anti-brick policy in README.md); a check that passes the
# failing input is a gate that cannot fail; a missing WARN means an operator
# loses the cue to use a branch or to stage the right version before a stash.
#
# Requirement: dtm-claude docs/reference/DOCUMENTATION_AND_TEST_STANDARD.md §1
# ("every rule and gate ships with at least one input that must fail and one
# that must pass"); the defaults are listed in hooks/common/qa-gate.conf.
#
# Every case self-SKIPs when its tool (shellcheck, ruff, ast-grep, pyyaml) is
# absent, as qa_gate.sh itself does. Fixtures are generated at run time.
# shellcheck shell=sh

# _gc_gate REPO LOG — run the QA gate in REPO with stderr captured in LOG.
_gc_gate() { gg_run_gate_log "$1" "$2"; }

# _gc_stage REPO PATH CONTENT — write CONTENT (printf %b) to PATH and stage it.
_gc_stage() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%b' "$3" > "$1/$2"
  ( cd "$1" && git add -- "$2" )
}

# _gc_precommit REPO LOG — run hooks/pre-commit directly. The downstream chain
# is pinned to a no-op script so an installed lefthook cannot change the result.
_gc_precommit() {
  printf '#!/bin/sh\nexit 0\n' > "$GG_T_TMPROOT/gc-noop-downstream"
  chmod +x "$GG_T_TMPROOT/gc-noop-downstream"
  ( cd "$1" && GIT_GUARD_DOWNSTREAM_HOOK="$GG_T_TMPROOT/gc-noop-downstream" \
      sh "$GG_ROOT/hooks/pre-commit" ) >"$2" 2>&1 </dev/null
}

t_case_gate_controls() {
  t_begin "28 gate controls: failing and passing inputs for default-on checks"
  log="$(gg_tmp_log)"

  # ---- shell.shellcheck=block ----------------------------------------------
  if gg_has_shellcheck; then
    r="$(gg_mktemp_repo)"
    _gc_stage "$r" bad.sh '#!/bin/sh\nunused_value=1\n'
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 1 "$rc" "shellcheck: a warning-level finding (SC2034) blocks"
    grep -q 'shellcheck errors' "$log"; t_assert $? "shellcheck: the block names shellcheck"
    gg_rmrepo "$r"
    r="$(gg_mktemp_repo)"
    _gc_stage "$r" ok.sh '#!/bin/sh\nvalue=1\necho "$value"\n'
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 0 "$rc" "shellcheck: a clean script passes"
    gg_rmrepo "$r"
  else
    t_skip "shellcheck: CLI absent (the gate self-skips the same way)"
  fi

  # ---- python.ruff_check=block ---------------------------------------------
  if gg_has_ruff; then
    r="$(gg_mktemp_repo)"
    _gc_stage "$r" bad.py 'import os\n'
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 1 "$rc" "ruff check: an unused import (F401) blocks under the minimal E,F set"
    grep -q 'ruff lint errors' "$log"; t_assert $? "ruff check: the block names ruff"
    gg_rmrepo "$r"
    r="$(gg_mktemp_repo)"
    _gc_stage "$r" ok.py 'value = 1\n'
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 0 "$rc" "ruff check: a clean module passes"
    gg_rmrepo "$r"
  else
    t_skip "ruff check: CLI absent (the gate self-skips the same way)"
  fi

  # ---- validate.json / validate.yaml: passing inputs ------------------------
  # Category 1 holds the failing inputs (broken.json, broken.yml).
  if gg_has_python; then
    r="$(gg_mktemp_repo)"
    gg_fixture_good_json "$r"; ( cd "$r" && git add ok.json )
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 0 "$rc" "validate.json: well-formed JSON passes"
    gg_rmrepo "$r"
  else
    t_skip "validate.json: no python interpreter"
  fi
  if gg_has_pyyaml; then
    r="$(gg_mktemp_repo)"
    printf 'validate.yaml=block\n' > "$r/.qa-gate.conf"
    _gc_stage "$r" ok.yml 'a:\n  b: 1\n  c: 2\n'
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 0 "$rc" "validate.yaml=block: well-formed YAML passes"
    gg_rmrepo "$r"
  else
    t_skip "validate.yaml: pyyaml absent (YAML validation self-skips)"
  fi

  # ---- BLOCK trio: passing input --------------------------------------------
  # Category 1 holds the failing inputs; this proves clean Rust is not refused.
  if gg_has_astgrep; then
    r="$(gg_mktemp_repo)"
    _gc_stage "$r" src/ok.rs 'pub fn add(a: u32, b: u32) -> u32 {\n    a.wrapping_add(b)\n}\n'
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 0 "$rc" "BLOCK trio: clean Rust in src/ passes"
    gg_rmrepo "$r"
  else
    t_skip "BLOCK trio passing input: ast-grep CLI absent"
  fi

  # ---- qa.enabled=off: the whole-gate escape hatch --------------------------
  if gg_has_python; then
    r="$(gg_mktemp_repo)"
    gg_fixture_bad_json "$r"; ( cd "$r" && git add broken.json )
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 1 "$rc" "qa.enabled control: invalid JSON blocks with the gate on"
    printf 'qa.enabled=off\n' > "$r/.qa-gate.conf"
    _gc_gate "$r" "$log"; rc=$?
    t_expect_rc 0 "$rc" "qa.enabled=off: the same invalid JSON no longer blocks"
    gg_rmrepo "$r"
  else
    t_skip "qa.enabled: no python interpreter for the JSON control"
  fi

  # ---- largefile (warn) ------------------------------------------------------
  r="$(gg_mktemp_repo)"
  printf 'largefile_kb=1\n' > "$r/.qa-gate.conf"
  _gc_stage "$r" small.txt 'small\n'
  _gc_gate "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "largefile: a file under largefile_kb passes"
  if grep -q 'large staged file' "$log"; then t_fail "largefile: a small file was reported as large"
  else t_ok "largefile: no warning for a file under largefile_kb"; fi
  head -c 2048 /dev/zero | tr '\0' 'x' > "$r/big.txt"; ( cd "$r" && git add big.txt )
  _gc_gate "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "largefile: an oversized file warns but does not block"
  grep -q 'large staged file big.txt' "$log"; t_assert $? "largefile: the warning names the oversized file"
  gg_rmrepo "$r"

  # ---- pre-commit step 4: protected-branch WARN -----------------------------
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git symbolic-ref HEAD refs/heads/main )
  _gc_stage "$r" README.md '# x\n'
  _gc_precommit "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "protected-branch: a commit on main is not blocked"
  grep -q "committing directly on 'main'" "$log"; t_assert $? "protected-branch: a commit on main is warned"
  ( cd "$r" && git symbolic-ref HEAD refs/heads/feature/x )
  _gc_precommit "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "protected-branch: a commit on a feature branch passes"
  if grep -q 'committing directly on' "$log"; then t_fail "protected-branch: a feature branch was warned"
  else t_ok "protected-branch: no warning on a feature branch"; fi
  gg_rmrepo "$r"

  # ---- pre-commit step 5: partial-staging WARN ------------------------------
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git symbolic-ref HEAD refs/heads/feature/x )
  _gc_stage "$r" notes.txt 'one\n'
  _gc_precommit "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "partial-staging: a fully staged file passes"
  if grep -q 'ALSO have unstaged edits' "$log"; then t_fail "partial-staging: a fully staged file was warned"
  else t_ok "partial-staging: no warning when the staged file has no unstaged edits"; fi
  printf 'two\n' >> "$r/notes.txt"
  _gc_precommit "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "partial-staging: a partially staged file warns but does not block"
  grep -q 'ALSO have unstaged edits' "$log"; t_assert $? "partial-staging: the warning is printed"
  grep -q '  notes.txt' "$log"; t_assert $? "partial-staging: the warning names the file"
  gg_rmrepo "$r"

  # ---- post-commit: the landed SHA ------------------------------------------
  r="$(gg_mktemp_repo)"
  ( cd "$r" && printf 'a\n' > a.txt && git add a.txt && git commit -q -m one \
      && printf 'b\n' > b.txt && git add b.txt && git commit -q -m two ) >/dev/null 2>&1
  ( cd "$r" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      sh "$GG_ROOT/hooks/post-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "post-commit: never fails the commit"
  head_sha="$(git -C "$r" rev-parse --short HEAD)"
  first_sha="$(git -C "$r" rev-parse --short HEAD~1)"
  grep -q "commit $head_sha landed" "$log"; t_assert $? "post-commit: names the SHA that just landed ($head_sha)"
  if grep -q "commit $first_sha landed" "$log"; then t_fail "post-commit: named the parent SHA, not HEAD"
  else t_ok "post-commit: does not name the parent SHA"; fi
  gg_rmrepo "$r"

  # ---- branch-protection.sh --------------------------------------------------
  # A stub gh on PATH: --dry-run never calls it, but the script requires one.
  bp_bin="$(mktemp -d "$GG_T_TMPROOT/bp.XXXXXX")"
  printf '#!/bin/sh\necho "stub gh must not be called in --dry-run" >&2\nexit 9\n' > "$bp_bin/gh"
  chmod +x "$bp_bin/gh"
  PATH="$bp_bin:$PATH" sh "$GG_ROOT/branch-protection.sh" --dry-run >"$log" 2>&1; rc=$?
  t_expect_rc 2 "$rc" "branch-protection: refuses to run without <owner>/<repo>"
  if gg_has_python; then
    for bp_check in default none; do
      if [ "$bp_check" = none ]; then set -- --require-check ""; else set --; fi
      PATH="$bp_bin:$PATH" sh "$GG_ROOT/branch-protection.sh" example/repo --dry-run "$@" \
        > "$log.raw" 2>&1; rc=$?
      sed '1d;$d' "$log.raw" > "$log"; rm -f "$log.raw"
      t_expect_rc 0 "$rc" "branch-protection --dry-run ($bp_check check): exits 0 without calling gh"
      "$(gg_python)" - "$log" <<'PY' >/dev/null 2>&1
import json, sys
rules = {r["type"] for r in json.load(open(sys.argv[1]))["rules"]}
need = {"deletion", "non_fast_forward", "required_signatures", "pull_request"}
sys.exit(0 if need <= rules else 1)
PY
      t_assert $? "branch-protection --dry-run ($bp_check check): valid JSON with deletion, non_fast_forward, required_signatures, pull_request"
    done
  else
    t_skip "branch-protection --dry-run: no python interpreter to parse the JSON"
  fi
  rm -rf "$bp_bin"
  rm -f "$log"
  return 0
}
