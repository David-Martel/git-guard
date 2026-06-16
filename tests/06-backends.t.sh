#!/bin/sh
# Category 6 — Docker / cross-platform backend selection + NUL cleanup.
# Exercises bin/git-guard-run's backend forcing (native / wsl), the Docker path
# (build OR skip-with-reason when the engine is down), the WSL fallback on
# Windows, and reserved-filename (NUL) cleanup on a POSIX backend. Sourced by
# run.sh. Uses GIT_GUARD_RULES_DIR (already exported by run.sh) so every backend
# resolves the bundled rules, never the machine-local private overlay.
# shellcheck shell=sh

GG_RUN="$GG_ROOT/bin/git-guard-run"

# Did a backend actually run as the one we forced? Asserts the "backend = X"
# banner git-guard-run prints to stderr AND a non-FAIL self-test result.
t_backend_runs() {
  want="$1"; logf="$(gg_tmp_log)"
  # Capture BOTH streams: the "backend = X" banner is on stderr, but the
  # self-test's "RESULT: PASS" / "SKIP:" line is on stdout.
  GIT_GUARD_BACKEND="$want" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
    sh "$GG_RUN" verify >"$logf" 2>&1 </dev/null
  rc=$?
  banner="$(tr -d '\r' < "$logf" | grep -c "backend = $want")"
  result="$(tr -d '\r' < "$logf" | grep -cE 'RESULT: PASS|SKIP:')"
  rm -f "$logf"
  [ "$banner" -ge 1 ] && [ "$result" -ge 1 ] && [ "$rc" -eq 0 ]
}

t_case_backends() {
  t_begin "06 backends: native / wsl / docker + NUL cleanup"

  # --- native backend always available ---
  if t_backend_runs native; then
    t_ok "GIT_GUARD_BACKEND=native runs the native backend (verify PASS/SKIP)"
  else
    t_fail "forced native backend did not run cleanly"
  fi

  # --- wsl backend (Windows only; util-linux sg there -> verify SKIPs cleanly) ---
  # WSL interop can expose wsl.exe inside a Linux self-hosted runner, but nested
  # WSL is not a supported or required backend there. Only Windows hosts assert it.
  if gg_is_windows && have wsl.exe && wsl.exe true >/dev/null 2>&1; then
    if t_backend_runs wsl; then
      t_ok "GIT_GUARD_BACKEND=wsl runs the WSL backend (PASS or clean SKIP)"
    else
      t_fail "forced wsl backend did not run cleanly"
    fi
    # WSL is the documented Windows fallback when Docker is down - assert the
    # auto path reaches it (banner appears) on Windows.
    if gg_is_windows; then
      logf="$(gg_tmp_log)"
      GIT_GUARD_RULES_DIR="$GG_BUNDLED" sh "$GG_RUN" verify >/dev/null 2>"$logf" </dev/null
      if tr -d '\r' < "$logf" | grep -q "backend = wsl"; then
        t_ok "auto-detect falls through Docker(down)->WSL on Windows"
      else
        t_skip "auto-detect did not reach WSL (docker may be up, or native chosen)"
      fi
      rm -f "$logf"
    fi
  else
    t_skip "wsl backend: Windows host with wsl.exe unavailable"
  fi

  # --- docker backend: build OR skip-with-reason if the engine is down ---
  if gg_has_docker; then
    if docker build -t git-guard:test -f "$GG_ROOT/docker/Dockerfile" "$GG_ROOT" >/dev/null 2>&1; then
      t_ok "docker image builds from docker/Dockerfile"
    else
      t_fail "docker image build failed"
    fi
  else
    t_skip "docker backend: engine down/absent - Dockerfile structural sanity checked instead"
    # Best-available offline check: the Dockerfile is well-formed (the required
    # instructions are present and ordered sanely).
    df="$GG_ROOT/docker/Dockerfile"
    ok=0
    grep -q '^FROM ' "$df" && grep -q '^COPY \. /opt/git-guard' "$df" \
      && grep -q '^ENTRYPOINT ' "$df" && grep -q 'ast-grep/cli' "$df" && ok=1
    t_assert "$([ "$ok" = 1 ] && echo 0 || echo 1)" "Dockerfile has FROM/COPY/ENTRYPOINT + ast-grep install (well-formed)"
  fi

  # --- NUL / reserved-filename cleanup (POSIX backends only) ---
  if gg_is_windows; then
    t_skip "NUL cleanup: cannot create a reserved-name file on native Windows (covered on Linux/WSL)"
  else
    r="$(gg_mktemp_repo)"
    # Create a reserved-name file and confirm mandatory cleanup removes it (rc 0).
    : > "$r/nul"
    ( cd "$r" && NUKENUL_MANDATORY=1 sh "$GG_ROOT/hooks/common/nul-cleanup.sh" >/dev/null 2>&1 ); rc=$?
    t_expect_rc 0 "$rc" "nul-cleanup completes (mandatory mode)"
    if [ ! -e "$r/nul" ]; then t_ok "reserved-name file 'nul' was removed"; else t_fail "'nul' not removed"; fi
    gg_rmrepo "$r"
  fi
}
