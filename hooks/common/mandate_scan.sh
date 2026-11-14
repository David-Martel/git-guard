#!/bin/sh
#
# git-guard quality mandate — callable entrypoint (POSIX sh).
#
# Called by qa_gate.sh (pre-commit, `--staged`) and by hooks/pre-push
# (`--pre-push`, only when the pushed commit carries .git-guard/mandate-baseline.json).
# Repos with their own hooks call it directly, the way vigil-spark's .githooks
# already call secret_scan.sh:
#
#   sh <git-guard>/hooks/common/mandate_scan.sh --staged
#   sh <git-guard>/hooks/common/mandate_scan.sh --range origin/main..HEAD
#   sh <git-guard>/hooks/common/mandate_scan.sh --all [--rev REV]      # JSON counts
#   sh <git-guard>/hooks/common/mandate_scan.sh --write-baseline
#   sh <git-guard>/hooks/common/mandate_scan.sh --check-baseline [--rev REV]
#   sh <git-guard>/hooks/common/mandate_scan.sh --list-rules
#
# Exit: 0 PASSED, 1 BLOCKED, 2 TOOL ERROR (fail closed; never a clean scan).
# The rules, severities and baseline schema: docs/QA_TOOLING.md "Quality mandate".
#
# --pre-push first selects, in sh and git alone, the pushed commits that carry a debt
# register; with none it exits 0 before any interpreter is looked up or probed.
# The logic lives in mandate_scan.py beside this file (standard library only),
# run with `-I` so neither the repo being scanned nor PYTHONPATH can shadow a
# stdlib module. No Python interpreter at all is the one case reported as a
# WARN and exit 0: the same anti-brick rule qa_gate.sh applies to every
# missing tool, stated loudly so it cannot read as a pass.

set -u

mandate_dir="$(cd "$(dirname "$0")" && pwd -P)"

# mandate_pushed_baselines: read a pre-push ref list on stdin and print every pushed
# commit that carries the debt register; exit 2 when git cannot list them. The same
# selection as mandate_scan.py pushed_baseline_shas / new_register_commits: tags and
# deletions are skipped; a known remote tip bounds the walk, otherwise everything no
# remote has; the pushed tip itself is always checked.
mandate_pushed_baselines() {
  mandate_zero=0000000000000000000000000000000000000000
  while read -r mandate_lref mandate_lsha _mandate_rref mandate_rsha mandate_extra; do
    [ -n "${mandate_rsha:-}" ] && [ -z "${mandate_extra:-}" ] || continue
    [ "$mandate_lsha" = "$mandate_zero" ] && continue
    case "$mandate_lref" in refs/tags/*) continue ;; esac
    if [ "$mandate_rsha" != "$mandate_zero" ] &&
       git cat-file -e "$mandate_rsha^{commit}" 2>/dev/null; then
      set -- --not "$mandate_rsha"
    else
      set -- --not --remotes
    fi
    if ! mandate_list="$(git rev-list --full-history "$mandate_lsha" "$@" 2>/dev/null)"; then
      printf '%s\n' "git-guard mandate TOOL ERROR [git]: cannot enumerate introduced commits" \
        "    command: git rev-list --full-history $mandate_lsha $*" >&2
      return 2
    fi
    for mandate_sha in $mandate_lsha $mandate_list; do
      if git cat-file -e "$mandate_sha:.git-guard/mandate-baseline.json" 2>/dev/null; then
        printf '%s\n' "$mandate_sha"
      fi
    done
  done
  return 0
}

# Pre-push: decide natively whether any pushed commit carries a debt register. A repo
# without one must push without the scanner, and without probing for an interpreter
# (git-guard #118: clarius forbids executing Python, hooks included).
mandate_refs=""
if [ "${1:-}" = "--pre-push" ]; then
  # A ref list that cannot be read is a TOOL ERROR. A failed capture used to become an
  # empty list, so a push carrying a debt register passed unscanned (review of #119).
  if ! mandate_refs="$(cat)"; then
    printf '%s\n' "git-guard mandate TOOL ERROR [stdin]: cannot read the pushed ref list" \
      "git-guard mandate: TOOL ERROR — the quality mandate could not be evaluated, so the result is refused (fail closed); this is NOT a clean scan." >&2
    exit 2
  fi
  if ! mandate_found="$(printf '%s\n' "$mandate_refs" | mandate_pushed_baselines)"; then
    printf '%s\n' "git-guard mandate: TOOL ERROR — the quality mandate could not be evaluated, so the result is refused (fail closed); this is NOT a clean scan." >&2
    exit 2
  fi
  [ -n "$mandate_found" ] || exit 0
fi

# Probe, do not just look up: a version-manager shim (mise, pyenv) can be on
# PATH as `python3` and still fail to start ("No version is set"). Exec-ing it
# would turn that failure into this script's exit status, which callers read
# as BLOCKED (1) or TOOL ERROR (2) with nothing explaining why.
mandate_py=""
for mandate_cand in python3 python; do
  if command -v "$mandate_cand" >/dev/null 2>&1 &&
     "$mandate_cand" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
       >/dev/null 2>&1; then
    mandate_py="$mandate_cand"
    break
  fi
done

if [ -z "$mandate_py" ]; then
  # At pre-push this point is reached only when a pushed commit carries a debt
  # register (selected above), so the warning is never printed for other repos.
  printf '%s\n' \
    "git-guard mandate WARN: no Python 3.8+ interpreter (python3/python) on PATH, so the" \
    "quality mandate was NOT evaluated for this run. Install python3 to enforce it." >&2
  exit 0
fi

if [ "${1:-}" = "--pre-push" ]; then
  # The ref list was read above; hand the scanner the same lines.
  exec "$mandate_py" -I "$mandate_dir/mandate_scan.py" "$@" <<MANDATE_REFS
$mandate_refs
MANDATE_REFS
fi
exec "$mandate_py" -I "$mandate_dir/mandate_scan.py" "$@"
