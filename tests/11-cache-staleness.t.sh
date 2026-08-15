#!/bin/sh
# Category 11 — the ast-grep rule-cache staleness check must fail SAFE.
#
# Background. qa_gate.sh decides whether its validated rule cache is current by
# asking find for any source rule newer than the cache stamp:
#
#     "$QA_FIND" "$src" -name '*.yml' -newer "$stamp" -print 2>/dev/null
#
# uutils find — routinely first on PATH via a ~/bin coreutils shim — cannot
# evaluate that predicate combination ("the argument '--name <PATTERN>' cannot
# be used multiple times"). The call site discards stderr, so the failure is
# INVISIBLE: an errored query and a genuinely-fresh cache both produce empty
# output. Treating empty as "fresh" certifies a stale cache FOREVER, silently
# enforcing rules the caller never selected — the same fail-open shape as the
# `grep -e` PEM hole fixed in git-guard#10.
#
# The fix probes find's capability once and, when the probe fails, forces a
# rebuild instead of trusting the answer. Rebuilding unnecessarily costs ~30s
# once; wrongly skipping it has no symptom at all. Slow-but-correct beats
# fast-but-blind for a gate.
#
# These cases pin BOTH controls, because a discriminator that always returns
# "capable" would pass a positive-only test while restoring the bug.

# _find_probe FINDBIN — replicate qa_gate's capability probe. Echoes the number
# of matches; the probe treats exactly 1 as "capable".
_find_probe() {
  _t="$(mktemp -d)" || return 99
  : > "$_t/stamp"
  : > "$_t/probe.yml"
  touch -t 202001010000 "$_t/stamp" 2>/dev/null
  _n="$("$1" "$_t" -name '*.yml' -newer "$_t/stamp" -print 2>/dev/null | wc -l)"
  rm -rf "$_t"
  printf '%s' "$_n" | tr -d ' \t\n'
}

t_case_cache_staleness() {
  t_begin "11 rule-cache staleness check fails safe on an incapable find"

  # ---- POSITIVE control: a capable find must be recognised as capable -------
  # Without this, a probe hardwired to "incapable" would rebuild on every single
  # commit — correct, but a ~30s tax per commit that would get the gate disabled.
  if [ -x /usr/bin/find ]; then
    _got="$(_find_probe /usr/bin/find)"
    if [ "$_got" = "1" ]; then
      t_ok "positive control: GNU find is detected as capable"
    else
      t_fail "positive control: GNU find probe returned '$_got', expected 1 (would force a rebuild every commit)"
    fi
  else
    t_skip "positive control: /usr/bin/find absent"
  fi

  # ---- NEGATIVE control: an incapable find must NOT be trusted --------------
  # Stub a find that fails exactly the way uutils find does.
  _stub="$(mktemp -d)" || { t_fail "cannot mktemp"; return 0; }
  cat > "$_stub/find" <<'EOS'
#!/bin/sh
echo "error: the argument '--name <PATTERN>' cannot be used multiple times" >&2
exit 2
EOS
  chmod +x "$_stub/find"
  _got="$(_find_probe "$_stub/find")"
  if [ "$_got" = "1" ]; then
    t_fail "negative control: a FAILING find was reported capable — the cache would be certified fresh forever"
  else
    t_ok "negative control: failing find is not trusted (probe=$_got)"
  fi
  rm -rf "$_stub"

  # ---- the guard is actually WIRED to the staleness decision ----------------
  # The probe is worthless if the freshness branch ignores it. Assert the
  # capability flag gates the `-newer` query rather than sitting unused.
  _q="$GG_ROOT/hooks/common/qa_gate.sh"
  if grep -q 'QA_FIND_OK' "$_q" 2>/dev/null &&
     grep -q 'if \[ "\$QA_FIND_OK" = "1" \]; then' "$_q" 2>/dev/null; then
    t_ok "wiring: staleness query is guarded by the capability probe"
  else
    t_fail "wiring: qa_gate.sh runs the '-newer' freshness query without checking QA_FIND_OK"
  fi

  # ---- no unguarded fail-open freshness path remains ------------------------
  # The original bug in one line: `-newer` feeding a freshness decision with
  # stderr discarded and no capability check. Catch a reintroduction.
  if grep -n -- '-newer' "$_q" 2>/dev/null | grep -qv 'QA_FIND_OK\|^\s*#'; then
    # There IS a -newer line (expected); confirm the capability flag precedes it.
    _newer_line="$(grep -n -- '-newer "\$stamp"' "$_q" 2>/dev/null | head -1 | cut -d: -f1)"
    _flag_line="$(grep -n 'if \[ "\$QA_FIND_OK" = "1" \]; then' "$_q" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$_newer_line" ] && [ -n "$_flag_line" ] && [ "$_flag_line" -lt "$_newer_line" ]; then
      t_ok "ordering: capability check precedes the staleness query"
    else
      t_fail "ordering: could not confirm the capability check precedes the '-newer' query (flag=$_flag_line newer=$_newer_line)"
    fi
  else
    t_ok "ordering: no unguarded '-newer' freshness query present"
  fi

  return 0
}
