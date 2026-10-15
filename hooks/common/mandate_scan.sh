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
# The logic lives in mandate_scan.py beside this file (standard library only),
# run with `-I` so neither the repo being scanned nor PYTHONPATH can shadow a
# stdlib module. No Python interpreter at all is the one case reported as a
# WARN and exit 0: the same anti-brick rule qa_gate.sh applies to every
# missing tool, stated loudly so it cannot read as a pass.

set -u

mandate_dir="$(cd "$(dirname "$0")" && pwd -P)"

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
  # At pre-push the scanner only matters for a repo with a debt register; do
  # not print a warning on every push of every other repo.
  if [ "${1:-}" = "--pre-push" ]; then
    mandate_root="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
    [ -n "$mandate_root" ] && [ -f "$mandate_root/.git-guard/mandate-baseline.json" ] || exit 0
  fi
  printf '%s\n' \
    "git-guard mandate WARN: no Python 3.8+ interpreter (python3/python) on PATH, so the" \
    "quality mandate was NOT evaluated for this run. Install python3 to enforce it." >&2
  exit 0
fi

exec "$mandate_py" -I "$mandate_dir/mandate_scan.py" "$@"
