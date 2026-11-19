#!/bin/sh
# The ONE rule for which Python the QA gate runs. Sourced by qa_gate.sh, and by
# `git-guard doctor`, which probes `import yaml` with exactly this interpreter:
# a `python3` with PyYAML behind a `python` without it does not help the gate.
#
# Prefer `python`, fall back to `python3`. Debian/Ubuntu (and the slim Docker
# base) ship only `python3`, so hardcoding `python` would silently no-op the
# JSON/YAML validation (a default BLOCK check) on most Linux clones. Prints the
# command name, or nothing when neither is present.
qa_python_select() {
  if command -v python >/dev/null 2>&1; then printf '%s' python
  elif command -v python3 >/dev/null 2>&1; then printf '%s' python3
  fi
}
