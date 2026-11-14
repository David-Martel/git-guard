#!/bin/sh
# Protects: an interpreter-free hook path. Identity verification on POSIX and the pre-push
#   mandate step of a repository without a debt register run without Python or uv, and the
#   checks still run (git-guard #118: clarius forbids executing Python, hooks included).
# Detects: any python, python3, py or uv execution on those paths (tripwire shims leave a
#   marker); a "native" path that skips the check instead of performing it (a mismatched
#   signature must still fail under enforce and be reported under warn, and a pushed commit
#   that carries a debt register must still reach the scanner).
# Needs: ssh-keygen with -Y signing and GNU or uutils timeout for the identity part (POSIX; the
#   Windows path keeps its contained worker, reported SKIPPED here); git for the mandate part.
# Breadcrumb: hooks/common/identity.sh gg_verify_native; hooks/common/mandate_scan.sh
#   mandate_pushed_baselines.

# gg_tripwire DIR MARKER — python, python3, py and uv shims that record each call and fail.
gg_tripwire() {
  mkdir -p "$1" "${lab:?}/nohooks"
  for gg_tw in python python3 py uv; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 97\n' "$gg_tw" "$2" > "$1/$gg_tw"
    chmod +x "$1/$gg_tw"
  done
}

t_case_native_no_interpreter() {
  t_begin "native hooks: no python/python3/py/uv on identity (POSIX) and baseline-free pre-push mandate"
  lab="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg-native.XXXXXX")" || { t_fail "native lab"; return; }
  marker="$lab/interpreter-calls"
  gg_tripwire "$lab/trip" "$marker"
  # Positive control: the tripwire itself fires.
  (PATH="$lab/trip:$PATH" python3 -c 'pass' >/dev/null 2>&1)
  if [ -s "$marker" ]; then t_ok "tripwire records an interpreter call"; else t_fail "tripwire records an interpreter call"; fi
  : > "$marker"

  # --- mandate --pre-push without a debt register ---------------------------------------
  r="$(gg_mktemp_repo)" || { t_fail "mandate repo"; rm -rf "$lab"; return; }
  printf 'fn main() {}\n' > "$r/main.rs"
  git -C "$r" add main.rs && git -C "$r" -c core.hooksPath="$lab/nohooks" commit -q -m one
  tip="$(git -C "$r" rev-parse HEAD)"
  zero=0000000000000000000000000000000000000000
  (cd "$r" && printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$zero" |
    PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/mandate_scan.sh" --pre-push >"$lab/m.out" 2>&1)
  t_expect_rc 0 "$?" "mandate pre-push without a debt register passes"
  if [ -s "$marker" ]; then
    t_fail "mandate pre-push without a debt register runs no interpreter ($(head -n 2 "$marker" | tr '\n' ';'))"
  else
    t_ok "mandate pre-push without a debt register runs no interpreter"
  fi
  : > "$marker"
  # Control: a pushed commit that carries a register still goes to the scanner. With the
  # tripwire as the only interpreter the scanner cannot start, which must be reported.
  mkdir -p "$r/.git-guard"
  printf '{}\n' > "$r/.git-guard/mandate-baseline.json"
  git -C "$r" add .git-guard && git -C "$r" -c core.hooksPath="$lab/nohooks" commit -q -m register
  reg="$(git -C "$r" rev-parse HEAD)"
  printf 'fn main() { }\n' > "$r/main.rs"
  git -C "$r" -c core.hooksPath="$lab/nohooks" commit -q -am after
  tip2="$(git -C "$r" rev-parse HEAD)"
  (cd "$r" && printf 'refs/heads/main %s refs/heads/main %s\n' "$tip2" "$tip" |
    PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/mandate_scan.sh" --pre-push >"$lab/m2.out" 2>&1)
  if [ -s "$marker" ] && grep -q 'NOT evaluated' "$lab/m2.out"; then
    t_ok "a pushed commit carrying a register ($(printf '%s' "$reg" | cut -c1-8)) still reaches the scanner"
  else
    t_fail "a pushed commit carrying a register still reaches the scanner (marker: $(wc -c < "$marker"); $(head -c 200 "$lab/m2.out"))"
  fi
  : > "$marker"
  # A ref list git cannot resolve is a TOOL ERROR (2), never a silent pass.
  (cd "$r" && printf 'refs/heads/main %s refs/heads/main %s\n' "1111111111111111111111111111111111111111" "$zero" |
    PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/mandate_scan.sh" --pre-push >"$lab/m3.out" 2>&1)
  t_expect_rc 2 "$?" "mandate pre-push: an unresolvable pushed commit is a TOOL ERROR"
  gg_rmrepo "$r"
  : > "$marker"

  # --- identity verify (POSIX native runner) ----------------------------------------------
  if gg_is_windows; then
    t_skip "identity native runner: Windows keeps the contained worker (git-guard #118 follow-up)"
    rm -rf "$lab"; return
  fi
  if ! gg_id_ready; then gg_id_skip_or_fail "identity native runner"; rm -rf "$lab"; return; fi
  gg_id_lab "$lab" || { t_fail "identity lab keys"; rm -rf "$lab"; return; }
  as="$lab/allowed_signers"
  r="$(gg_mktemp_repo)" || { t_fail "identity repo"; rm -rf "$lab"; return; }
  gg_id_commit "$r" "$lab/keys/claude@testhost" claude "clean agent commit"
  clean="$(git -C "$r" rev-parse HEAD)"
  gg_id_commit "$r" "$lab/keys/claude@testhost" codex "mismatched trailer"

  # Failure case 1, no native tool: a timeout that cannot bound (here it refuses -k, as
  # BusyBox and some BSD builds do) fails closed with exit 3, and does not reach Python.
  mkdir -p "$lab/notimeout"
  printf '#!/bin/sh\necho "timeout: unknown option -- k" >&2\nexit 125\n' > "$lab/notimeout/timeout"
  chmod +x "$lab/notimeout/timeout"
  (cd "$r" && PATH="$lab/trip:$lab/notimeout:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" verify --allowed-signers "$as" "$clean" >"$lab/n1.out" 2>&1)
  t_expect_rc 3 "$?" "identity verify: no usable timeout fails closed (exit 3, not a pass)"
  if [ -s "$marker" ]; then t_fail "identity verify: no usable timeout does not fall back to Python ($(head -n 1 "$marker"))"
  else t_ok "identity verify: no usable timeout does not fall back to Python"; fi
  grep -q 'timeout(1) with -k' "$lab/n1.out"
  t_assert "$?" "identity verify: no usable timeout names the missing tool"
  : > "$marker"
  # Failure case 2, native tool error: the runner starts but the bounded query fails.
  mkdir -p "$lab/badtimeout"
  printf '#!/bin/sh\n[ "$*" = "-k 1 5 true" ] && exit 0\necho "timeout: failed to run command" >&2\nexit 125\n' > "$lab/badtimeout/timeout"
  chmod +x "$lab/badtimeout/timeout"
  (cd "$r" && PATH="$lab/trip:$lab/badtimeout:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" verify --allowed-signers "$as" "$clean" >"$lab/n2.out" 2>&1)
  t_expect_rc 3 "$?" "identity verify: a native runner error fails closed (exit 3, not a pass)"
  if [ -s "$marker" ]; then t_fail "identity verify: a native runner error does not fall back to Python ($(head -n 1 "$marker"))"
  else t_ok "identity verify: a native runner error does not fall back to Python"; fi
  grep -q 'bounded signature query failed (exit 125)' "$lab/n2.out"
  t_assert "$?" "identity verify: a native runner error reports its exit status"
  : > "$marker"
  # Same two cases on the real pre-push route (default warn): reported, never silent.
  git -C "$r" config gpg.ssh.allowedSignersFile "$as"
  for gg_case in notimeout badtimeout; do
    (cd "$r" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$zero" |
      PATH="$lab/trip:$lab/$gg_case:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" pre-push origin >"$lab/np.out" 2>&1)
    np_rc=$?
    if [ "$np_rc" -ne 0 ] && [ ! -s "$marker" ]; then
      t_ok "identity pre-push ($gg_case): fails closed (exit $np_rc) without Python"
    else
      t_fail "identity pre-push ($gg_case): fails closed without Python (rc $np_rc; marker $(wc -c < "$marker"))"
    fi
    : > "$marker"
  done
  git -C "$r" config --unset gpg.ssh.allowedSignersFile

  # The positive route needs a real timeout that bounds.
  if ! timeout -k 1 5 true >/dev/null 2>&1; then
    if [ "${CI:-}" = "true" ]; then t_fail "identity native runner needs GNU or uutils timeout in CI"; else t_skip "identity native runner: no timeout with -k on this host"; fi
    gg_rmrepo "$r"; rm -rf "$lab"; return
  fi
  (cd "$r" && PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" verify --allowed-signers "$as" "$clean" >"$lab/v0.out" 2>&1)
  t_expect_rc 0 "$?" "identity verify (native): a clean commit passes"
  (cd "$r" && PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" verify --allowed-signers "$as" HEAD >"$lab/v1.out" 2>&1)
  t_expect_rc 1 "$?" "identity verify (native): a mismatched trailer still fails"
  if [ -s "$marker" ]; then
    t_fail "identity verify runs no interpreter ($(head -n 2 "$marker" | tr '\n' ';'))"
  else
    t_ok "identity verify runs no interpreter"
  fi
  : > "$marker"
  # The real pre-push route in default warn mode: configured signers, new commits.
  git -C "$r" config gpg.ssh.allowedSignersFile "$as"
  (cd "$r" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$zero" |
    PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" pre-push origin >"$lab/p.out" 2>&1)
  p_rc=$?
  if [ "$p_rc" -eq 1 ] && grep -q 'mismatch' "$lab/p.out"; then
    t_ok "identity pre-push (native): the mismatch is found and reported"
  else
    t_fail "identity pre-push (native): the mismatch is found and reported (rc $p_rc: $(head -c 200 "$lab/p.out"))"
  fi
  if [ -s "$marker" ]; then
    t_fail "identity pre-push runs no interpreter ($(head -n 2 "$marker" | tr '\n' ';'))"
  else
    t_ok "identity pre-push runs no interpreter"
  fi
  # Multi-ref push: the result over all refs is the worst one, in either order. The native
  # runner once reset the caller's running status (a shared global rc), so a mismatched ref
  # followed by a clean one returned 0 and enforce accepted it (autopilot review of #119).
  mr() {  # mr LABEL WANT REF-LINE... : feed the ref lines to the real pre-push route
    mr_label="$1" mr_want="$2"; shift 2
    (cd "$r" && printf '%s\n' "$@" |
      PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" pre-push origin >"$lab/mr.out" 2>&1)
    t_expect_rc "$mr_want" "$?" "identity pre-push (native): $mr_label"
  }
  bad_ref="refs/heads/bad $(git -C "$r" rev-parse HEAD) refs/heads/bad $zero"
  good_ref="refs/heads/good $clean refs/heads/good $zero"
  gone_ref="refs/heads/gone 1111111111111111111111111111111111111111 refs/heads/gone $zero"
  mr "[mismatched, clean] still fails (1)" 1 "$bad_ref" "$good_ref"
  mr "[clean, mismatched] still fails (1)" 1 "$good_ref" "$bad_ref"
  mr "[unlistable, clean] keeps the not-checked status (2)" 2 "$gone_ref" "$good_ref"
  mr "[clean, clean] passes (positive control)" 0 "$good_ref" "$good_ref"
  : > "$marker"
  # A successful query leaves no verifier descendant behind: timeout only signals its group
  # at the deadline, so a background child of ssh-keygen outlived a query that returned 0.
  real_sshkeygen="$(command -v ssh-keygen)"
  mkdir -p "$lab/bg"
  printf '#!/bin/sh\n( sleep 2; : > "%s/survivor" ) </dev/null >/dev/null 2>&1 &\nexec "%s" "$@"\n' "$lab" "$real_sshkeygen" > "$lab/bg/ssh-keygen"
  chmod +x "$lab/bg/ssh-keygen"
  (cd "$r" && git config gitGuard.identityTimeoutSeconds 20 &&
    PATH="$lab/trip:$lab/bg:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" verify --allowed-signers "$as" "$clean" >"$lab/bg.out" 2>&1)
  t_expect_rc 0 "$?" "identity verify (native): the clean commit passes through the background-spawning verifier"
  sleep 3
  if [ -e "$lab/survivor" ]; then t_fail "identity verify (native): no verifier descendant survives a successful query"
  else t_ok "identity verify (native): no verifier descendant survives a successful query"; fi
  git -C "$r" config --unset gitGuard.identityTimeoutSeconds
  # install.sh's containment probe: a zombie (terminated, not yet reaped by a non-reaping
  # PID 1) is not a survivor; kill -0 alone said it was and refused a working timeout.
  vnc_src="$(sed -n '/^vnc_alive() {$/,/^}$/p' "$GG_ROOT/install.sh")"
  if [ -z "$vnc_src" ]; then
    t_fail "install.sh defines vnc_alive"
  else
    eval "$vnc_src"
    sleep 30 & live=$!
    sleep 0 & dead=$!; wait "$dead" 2>/dev/null
    sh -c 'sleep 0 & echo $! > "$1"; exec sleep 5' sh "$lab/zpid" & zparent=$!
    sleep 1
    zpid="$(cat "$lab/zpid")"
    if vnc_alive "$live"; then t_ok "vnc_alive: a running process is alive"; else t_fail "vnc_alive: a running process is alive"; fi
    if vnc_alive "$dead"; then t_fail "vnc_alive: a reaped process is gone"; else t_ok "vnc_alive: a reaped process is gone"; fi
    if vnc_alive "$zpid"; then t_fail "vnc_alive: a zombie is not a survivor"; else t_ok "vnc_alive: a zombie is not a survivor"; fi
    kill "$live" "$zparent" 2>/dev/null; wait "$live" "$zparent" 2>/dev/null
  fi
  # Bounded: a verifier that hangs is stopped at the deadline and fails closed.
  printf '#!/bin/sh\nsleep 30\n' > "$lab/trip/ssh-keygen"; chmod +x "$lab/trip/ssh-keygen"
  start="$(date +%s)"
  (cd "$r" && git config gitGuard.identityTimeoutSeconds 2 &&
    PATH="$lab/trip:$PATH" sh "$GG_ROOT/hooks/common/identity.sh" verify --allowed-signers "$as" HEAD >"$lab/v2.out" 2>&1)
  v2_rc=$?
  took=$(( $(date +%s) - start ))
  if [ "$v2_rc" -ne 0 ] && [ "$took" -lt 15 ] && grep -q 'bounded signature query' "$lab/v2.out"; then
    t_ok "identity verify (native): a hanging verifier is stopped at the deadline and fails closed (${took}s)"
  else
    t_fail "identity verify (native): a hanging verifier is stopped and fails closed (rc $v2_rc, ${took}s)"
  fi
  gg_rmrepo "$r"
  rm -rf "$lab"
}
