#!/bin/sh
# Category 13 — staged-file type checks honor pyproject project scope.
# Sourced by run.sh; helpers from lib.sh.
# shellcheck shell=sh

t_case_python_scope() {
  t_begin "13 Python type gates honor configured project scope"
  if ! gg_has_python; then
    t_skip "Python absent — TOML scope parser not exercised"
    return 0
  fi

  r="$(gg_mktemp_repo)"
  mkdir -p "$r/scripts" "$r/src" "$r/.venv/bin"
  printf 'value: int = 1\n' > "$r/scripts/typed.py"
  printf 'import missing_ros_runtime\n' > "$r/src/ros_node.py"
  {
    printf '[tool.mypy]\n'
    printf 'files = ["scripts/typed.py"]\n'
    printf '[tool.basedpyright]\n'
    printf 'include = ["scripts"]\n'
  } > "$r/pyproject.toml"
  {
    printf 'python.ruff_check=off\n'
    printf 'python.ruff_format=off\n'
    printf 'astgrep=off\n'
  } > "$r/.qa-gate.conf"
  ( cd "$r" && git add scripts/typed.py src/ros_node.py pyproject.toml .qa-gate.conf )

  scope_log="$(gg_tmp_log)"
  export GG_TYPE_SCOPE_LOG="$scope_log"
  for checker in mypy basedpyright; do
    {
      printf '#!/bin/sh\n'
      # shellcheck disable=SC2016  # write literal runtime variables into the fixture script
      printf 'printf "%%s:%%s\\n" "%s" "$*" >> "$GG_TYPE_SCOPE_LOG"\n' "$checker"
      printf 'exit 0\n'
    } > "$r/.venv/bin/$checker"
    chmod +x "$r/.venv/bin/$checker"
  done

  gate_log="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 0 "$rc" "configured type scopes remain non-blocking and runnable"
  if grep -qx 'mypy:--ignore-missing-imports --no-error-summary scripts/typed.py' "$scope_log"; then
    t_ok "mypy receives only its configured file"
  else
    t_fail "mypy bypassed or lost its configured file scope"
  fi
  if grep -qx 'basedpyright:scripts/typed.py' "$scope_log"; then
    t_ok "basedpyright receives only its configured include tree"
  else
    t_fail "basedpyright bypassed or lost its configured include scope"
  fi
  if grep -q 'src/ros_node.py' "$scope_log"; then
    t_fail "excluded ROS file leaked into a staged-file type invocation"
  else
    t_ok "out-of-scope ROS file is not type-checked by the account-wide gate"
  fi

  unset GG_TYPE_SCOPE_LOG
  rm -f "$scope_log" "$gate_log"
  gg_rmrepo "$r"
}
