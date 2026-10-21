#!/bin/sh
# Protects: bounded signature attestation and owned child cleanup.
# Detects: verifier hangs, surviving descendants or accepted partial output.
# Needs: uv, existing offline Python, Git and supported Windows/POSIX containment.
# Breadcrumb: hooks/common/identity_worker.py
t_case_identity_worker() {
  if ! command -v uv >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then t_fail "identity worker requires uv in CI";
    else t_skip "identity worker: uv unavailable"; fi
    return
  fi
  test_file="$GG_ROOT/tests/test_identity_worker.py"
  if command -v cygpath >/dev/null 2>&1; then test_file="$(cygpath -aw "$test_file")"; fi
  uv run --offline --no-project --no-python-downloads python -I -S -B "$test_file"
  t_expect_rc 0 "$?" "identity worker containment, deadline and attestation controls"
}
