#!/bin/sh
#
# git-guard comprehensive validation suite — runner.
#
# Invoked by `git-guard test` (bin/git-guard) and by CI (.github/workflows/qa.yml,
# both the docker and native jobs). Runs every tests/*.t.sh category in a
# hermetic temp dir, each in its own throwaway git repo, with automatic cleanup.
#
# Design:
#   * Pure POSIX sh, shellcheck-clean (CI shellchecks tests/*.sh).
#   * The WHOLE suite pins GIT_GUARD_RULES_DIR to the bundled rules-examples so a
#     machine-local private overlay (gitignored qa-gate.conf.local) can never
#     leak into the assertions — the public default is what gets validated.
#   * Each category self-SKIPs (with a reason) when a required tool or platform
#     is absent (ast-grep / shellcheck / ruff / pyyaml / docker / Windows-vs-NUL),
#     so the suite stays green across native / WSL / Docker / CI.
#   * Exit 0 iff zero assertions FAILED (skips do not fail the suite).
#
# Usage:  sh tests/run.sh [CASE...]   (CASE = a t_case_* name without the prefix)

set -u

# --- locate the git-guard root (this file is at <root>/tests/run.sh) ---
GG_TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
GG_ROOT="$(cd "$GG_TESTS_DIR/.." && pwd)"
GG_BUNDLED="$GG_ROOT/rules-examples"
export GG_ROOT GG_BUNDLED

# Pin the rules dir to the bundled examples for the entire suite (overrides any
# machine-local overlay). Tests that want a private dir set their own.
export GIT_GUARD_RULES_DIR="$GG_BUNDLED"

# Defend against a stale inherited PYTHONHOME that breaks `python` (and would
# make the gate's JSON/YAML validation misfire). Harmless when already unset.
export PYTHONHOME=

# Per-suite temp root, cleaned on exit (covers any repo a case forgot to remove).
GG_T_TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-guard-tests.XXXXXX")"
export GG_T_TMPROOT
# shellcheck disable=SC2064  # expand GG_T_TMPROOT now (trap fires after vars may change)
trap "rm -rf \"$GG_T_TMPROOT\"" EXIT INT TERM

# --- load helpers + every case file ---
# shellcheck source=tests/lib.sh disable=SC1091
. "$GG_TESTS_DIR/lib.sh"
for cf in "$GG_TESTS_DIR"/*.t.sh; do
  [ -f "$cf" ] || continue
  # shellcheck disable=SC1090
  . "$cf"
done

printf 'git-guard validation suite\n' >&2
printf '  root:    %s\n' "$GG_ROOT" >&2
printf '  rules:   %s (bundled examples, overlay-proof)\n' "$GG_BUNDLED" >&2
printf '  caps:    ast-grep=%s shellcheck=%s ruff=%s python=%s pyyaml=%s docker=%s\n' \
  "$(gg_has_astgrep && echo y || echo n)" \
  "$(gg_has_shellcheck && echo y || echo n)" \
  "$(gg_has_ruff && echo y || echo n)" \
  "$(gg_has_python && echo y || echo n)" \
  "$(gg_has_pyyaml && echo y || echo n)" \
  "$(gg_has_docker && echo y || echo n)" >&2

# --- the ordered case list ---
GG_CASES="
t_case_blockers
t_case_warn
t_case_autofix
t_case_precommit
t_case_prepush
t_case_backends
t_case_rule_integrity
t_case_panic_set
t_case_silent_failures
t_case_attribution
"

# Optional filtering: `git-guard test blockers warn` runs only those.
run_one() {
  fn="$1"
  if command -v "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    printf '  [FAIL] missing test function: %s\n' "$fn" >&2
    GG_T_FAIL=$((GG_T_FAIL + 1))
  fi
}

if [ "$#" -gt 0 ]; then
  for sel in "$@"; do run_one "t_case_${sel}"; done
else
  # shellcheck disable=SC2086  # intentional word-split of the fixed case list
  for fn in $GG_CASES; do run_one "$fn"; done
fi

printf '\n========================================\n' >&2
printf 'git-guard tests: %d passed, %d failed, %d skipped\n' "$GG_T_PASS" "$GG_T_FAIL" "$GG_T_SKIP" >&2
printf '========================================\n' >&2

[ "$GG_T_FAIL" -eq 0 ] || exit 1
exit 0
