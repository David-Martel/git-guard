#!/bin/sh
# Protects: an interpreter-free pre-commit mandate for staged Rust (git-guard #118 PR 2). A
#   commit with no staged Python is scanned by hooks/common/mandate_native.sh, which runs no
#   python, python3, py or uv, and still applies every rule that can fire: rust_panic through
#   ast-grep, the suppression_reason comment check, the index policy (severities, enabled,
#   vendored), test-path exemption, suppressions and merge-parent intersection.
# Detects: an interpreter call on that route (tripwire shims leave a marker); a native path
#   that passes what the scanner blocks; a missing or failing ast-grep read as a clean scan;
#   a rule table that drifts from mandate_scan.py; staged Python no longer reaching the
#   scanner.
# Needs: git and a genuine ast-grep (reported SKIPPED without one; the missing-tool case
#   still runs). Every repository is a temp one.
# Breadcrumb: hooks/common/mandate_native.sh; hooks/common/mandate_scan.sh (--staged route).

_nm_scan() {
  # _nm_scan REPO LOG [PATH-PREFIX] — the real entry point, tripwires first on PATH.
  ( cd "$1" && PATH="${3:+$3:}$_nm_lab/trip:$PATH" sh "$GG_ROOT/hooks/common/mandate_scan.sh" --staged ) >/dev/null 2>"$2"
}
_nm_clean() {
  # _nm_clean MSG — assert no interpreter ran, then reset the marker.
  if [ -s "$_nm_marker" ]; then t_fail "$1 runs no interpreter ($(head -n 1 "$_nm_marker"))"; else t_ok "$1 runs no interpreter"; fi
  : > "$_nm_marker"
}

t_case_native_staged_mandate() {
  t_begin "native staged mandate: Rust without python/python3/py/uv, same rules as the scanner"
  _nm_lab="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg-nm.XXXXXX")" || { t_fail "lab"; return; }
  _nm_marker="$_nm_lab/calls"
  lab="$_nm_lab" gg_tripwire "$_nm_lab/trip" "$_nm_marker"
  log="$_nm_lab/log"

  # Drift guard: the native rule table equals mandate_scan.py's RULES (read as text, not run).
  want="$(awk '
    /^    _rule\($/ { inr = 1; key = ""; def = ""; ruff = ""; n = 0; next }
    inr && /^    \),?$/ { print key "|" def "|" ruff; inr = 0; next }
    inr { n++; line = $0
      if (n == 1) { gsub(/[ ",]/, "", line); key = line }
      if (line ~ /Severity\./) { d = line; sub(/.*Severity\./, "", d); sub(/,.*/, "", d); def = tolower(d) }
      if (line ~ /ruff=\(/) { r = line; sub(/.*ruff=\(/, "", r); sub(/\).*/, "", r); gsub(/[" ]/, "", r); sub(/,$/, "", r); ruff = r } }
  ' "$GG_ROOT/hooks/common/mandate_scan.py")"
  have_="$(sed -n "/^NM_RULES='/,/'\$/p" "$GG_ROOT/hooks/common/mandate_native.sh" | sed "s/^NM_RULES='//; s/'\$//")"
  if [ -n "$want" ] && [ "$want" = "$have_" ]; then t_ok "native rule table matches mandate_scan.py RULES"
  else t_fail "native rule table matches mandate_scan.py RULES"; fi

  # Missing ast-grep (no native scanner at all): the rule is reported NOT evaluated, as the
  # scanner reports it; never a silent pass, and no interpreter.
  r="$(gg_mktemp_repo)" || { t_fail "repo"; rm -rf "$_nm_lab"; return; }
  # A PATH of only the tools the native route needs, plus a util-linux style `sg`.
  _nm_min="$(_qm_path_dir "$_nm_lab/minbin")"
  _qm_min_bin "$_nm_min" sh git awk sed grep cut wc mktemp date cat mkdir rm mv tr sort dirname basename head tail env uname cygpath
  printf '#!/bin/sh\necho "sg from util-linux"\n' > "$_nm_min/sg"; chmod +x "$_nm_min/sg"
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap()\n}\n'
  ( cd "$r" && PATH="$_nm_lab/trip:$_nm_min" sh "$GG_ROOT/hooks/common/mandate_scan.sh" --staged ) >/dev/null 2>"$log"
  t_expect_rc 0 "$?" "no ast-grep: not a block (anti-brick, as the scanner)"
  _qm_has "$log" "ast-grep is not installed, so these rules were NOT evaluated: rust_panic" "no ast-grep: rust_panic is named as NOT evaluated"
  _qm_has "$log" "1 rule(s) NOT evaluated" "no ast-grep: the summary says a rule did not run"
  _nm_clean "no ast-grep"
  gg_rmrepo "$r"

  # Our own suppression filter, as mandate_scan.py suppressed() applies it. Genuine ast-grep
  # (0.51) already drops ast-grep-ignore lines itself, so real-scanner fixtures never reach
  # the filter. A stub ast-grep reports panics on the lines in NM_STUB_LINES instead, which
  # needs no genuine ast-grep, so this runs before the skip below.
  r="$(gg_mktemp_repo)" || { t_fail "repo"; rm -rf "$_nm_lab"; return; }
  mkdir -p "$_nm_lab/stubsg"
  printf '#!/bin/sh\ncase "$1" in --version) echo "ast-grep 0.39.5"; exit 0 ;; esac\nfor l in $NM_STUB_LINES; do printf "::warning file=src/lib.rs,line=%%s,endLine=%%s,title=mandate-rust-panic::Panicking call\\n" "$l" "$l"; done\n' > "$_nm_lab/stubsg/ast-grep"
  chmod +x "$_nm_lab/stubsg/ast-grep"
  _nm_stub() { ( cd "$r" && NM_STUB_LINES="$1" PATH="$_nm_lab/stubsg:$_nm_lab/trip:$PATH" sh "$GG_ROOT/hooks/common/mandate_scan.sh" --staged ) >/dev/null 2>"$log"; }
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic  // SAFETY: fixture\nfn p() { panic!("x"); }\n'
  _nm_stub 2; t_expect_rc 0 "$?" "filter: a reasoned ast-grep-ignore on the comment-only line above suppresses"
  _qm_put "$r" src/lib.rs 'fn p() { panic!("x"); } // ast-grep-ignore: mandate-rust-panic  // SAFETY: fixture\n'
  _nm_stub 1; t_expect_rc 0 "$?" "filter: a reasoned ast-grep-ignore on the same line suppresses"
  _qm_put "$r" src/lib.rs 'fn q() {} // ast-grep-ignore: mandate-rust-panic  // SAFETY: not this line\nfn p() { panic!("x"); }\n'
  _nm_stub 2; t_expect_rc 1 "$?" "filter: an ignore trailing code on the line above does not suppress"
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-other-rule  // SAFETY: names another rule\nfn p() { panic!("x"); }\n'
  _nm_stub 2; t_expect_rc 1 "$?" "filter: an ignore naming another rule does not suppress"
  _qm_put "$r" src/lib.rs 'fn p() { let _s = "// ast-grep-ignore: mandate-rust-panic"; panic!("x"); }\n'
  _nm_stub 1; t_expect_rc 1 "$?" "filter: an ignore inside a string literal does not suppress"
  _qm_put "$r" src/lib.rs 'pub fn s() -> &'"'"'static str { "// ast-grep-ignore: mandate-rust-panic" }\n'
  _nm_stub ""; t_expect_rc 0 "$?" "an ignore inside a string literal is not a suppression without a reason"
  _nm_clean "suppression filter (stub ast-grep)"
  gg_rmrepo "$r"

  if ! gg_has_astgrep; then
    if [ "${CI:-}" = "true" ]; then t_fail "native staged mandate needs ast-grep in CI"; else t_skip "native staged mandate: no genuine ast-grep"; fi
    rm -rf "$_nm_lab"; return
  fi

  # Production unwrap blocks; the report names the rule, line and source text.
  r="$(gg_mktemp_repo)" || { t_fail "repo"; rm -rf "$_nm_lab"; return; }
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap()\n}\n'
  _nm_scan "$r" "$log"; t_expect_rc 1 "$?" "an added unwrap in production Rust blocks"
  _qm_has "$log" "BLOCK [rust_panic] RS-01 src/lib.rs:2 (ast-grep:mandate-rust-panic)" "the block names rule, path, line and origin"
  _qm_has "$log" ">> x.unwrap()" "the block quotes the staged line"
  _qm_has "$log" "BLOCKED — 1 finding(s) on 1 file(s)" "the summary counts the finding"
  _nm_clean "rust_panic block"
  # Native tool error: an ast-grep that fails is a TOOL ERROR (2), never a pass or Python.
  mkdir -p "$_nm_lab/badsg"
  printf '#!/bin/sh\ncase "$1" in --version) echo "ast-grep 0.0.0" ;; *) echo "boom" >&2; exit 3 ;; esac\n' > "$_nm_lab/badsg/ast-grep"
  chmod +x "$_nm_lab/badsg/ast-grep"
  _nm_scan "$r" "$log" "$_nm_lab/badsg"; t_expect_rc 2 "$?" "a failing ast-grep is a TOOL ERROR"
  _qm_has "$log" "TOOL ERROR [ast-grep]: exited 3" "the TOOL ERROR names the tool and exit"
  printf '#!/bin/sh\ncase "$1" in --version) echo "ast-grep 0.0.0" ;; *) echo "not a github annotation" ;; esac\n' > "$_nm_lab/badsg/ast-grep"
  _nm_scan "$r" "$log" "$_nm_lab/badsg"; t_expect_rc 2 "$?" "unparseable ast-grep output is a TOOL ERROR"
  printf '#!/bin/sh\necho "nope"; exit 1\n' > "$_nm_lab/badsg/ast-grep"
  _nm_scan "$r" "$log" "$_nm_lab/badsg"; t_expect_rc 2 "$?" "an ast-grep whose version probe fails is a TOOL ERROR"
  # Names itself but fails only the version probe; a scan would succeed with no findings,
  # so only the probe check can turn this into a TOOL ERROR.
  printf '#!/bin/sh\ncase "$1" in --version) echo "ast-grep 0.0.0"; exit 1 ;; esac\nexit 0\n' > "$_nm_lab/badsg/ast-grep"
  _nm_scan "$r" "$log" "$_nm_lab/badsg"; t_expect_rc 2 "$?" "an ast-grep that names itself but fails its version probe is a TOOL ERROR"
  _qm_has "$log" "version probe failed (exit 1, stdout 'ast-grep 0.0.0')" "the version-probe TOOL ERROR names the exit code and output"
  _nm_clean "ast-grep failure cases"
  # Suppression with and without a reason; test paths are exempt.
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic\nfn probe() { panic!("failed"); }\n'
  _nm_scan "$r" "$log"; t_expect_rc 1 "$?" "a suppression without a reason blocks"
  _qm_has "$log" "[suppression_reason] PY-09 src/lib.rs:1 (text)" "the reason check names the comment line"
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic  # SAFETY: fixture exercises a deliberate panic\nfn probe() { panic!("failed"); }\n'
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "the same suppression with a reason passes"
  _qm_put "$r" src/lib.rs 'fn s() -> &'"'"'static str { "// ast-grep-ignore: mandate-rust-panic" }\nfn probe() { panic!("failed"); }\n'
  _nm_scan "$r" "$log"; t_expect_rc 1 "$?" "an ast-grep-ignore inside a string suppresses nothing"
  _qm_put "$r" src/lib.rs 'pub fn ok() {}\n'
  _qm_put "$r" tests/it.rs 'fn t() { Some(1).unwrap(); }\n'
  _qm_put "$r" build.rs 'fn main() { Some(1).unwrap(); }\n'
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "tests/ and build.rs are exempt"
  _nm_clean "suppressions and test paths"
  gg_rmrepo "$r"

  # Policy from the index: severities, enabled, vendored, malformed values.
  r="$(gg_mktemp_repo)" || { t_fail "repo"; rm -rf "$_nm_lab"; return; }
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap()\n}\n'
  _qm_conf "$r" 'mandate.rust_panic=warn\n'
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "mandate.rust_panic=warn does not block"
  _qm_has "$log" "WARN [rust_panic]" "warn still reports the finding"
  _qm_conf "$r" 'mandate.rust_panic=off\n'
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "mandate.rust_panic=off lets it through"
  _qm_conf "$r" 'mandate.rust_panic=sometimes\n'
  _nm_scan "$r" "$log"; t_expect_rc 2 "$?" "an unknown severity is a TOOL ERROR"
  _qm_has "$log" "mandate.rust_panic=sometimes is not one of" "the error names the bad value"
  _qm_conf "$r" 'mandate.vendored=src\n'
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "a declared vendored directory is not scanned"
  _qm_conf "$r" 'mandate.vendored=../x\n'
  _nm_scan "$r" "$log"; t_expect_rc 2 "$?" "a vendored entry with .. is a TOOL ERROR"
  _qm_conf "$r" 'mandate.enabled=off\n'
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "mandate.enabled=off switches it off"
  printf 'mandate.rust_panic=off\n' > "$r/.qa-gate.conf"  # unstaged: the index decides
  ( cd "$r" && git rm -q -f --cached .qa-gate.conf )
  _nm_scan "$r" "$log"; t_expect_rc 1 "$?" "an unstaged conf does not change the staged verdict"
  _nm_clean "policy cases"
  # block reaches old debt in a staged file; changed does not.
  rm -f "$r/.qa-gate.conf"
  _qm_commit "$r" "debt"
  printf '%b' '\npub fn g() -> u8 { 1 }\n' >> "$r/src/lib.rs"
  ( cd "$r" && git add src/lib.rs )
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "changed: old debt on an unchanged line does not block"
  _qm_conf "$r" 'mandate.rust_panic=block\n'
  _nm_scan "$r" "$log"; t_expect_rc 1 "$?" "block: old debt anywhere in a staged file blocks"
  _nm_clean "block versus changed"
  gg_rmrepo "$r"

  # A merge keeps only lines new against every parent: an unwrap brought in by the other
  # parent is old debt there, so it does not block at the default severity.
  r="$(gg_mktemp_repo)" || { t_fail "repo"; rm -rf "$_nm_lab"; return; }
  _qm_put "$r" src/lib.rs 'pub fn a() {}\n'
  _qm_commit "$r" "base"
  ( cd "$r" && git checkout -q -b side )
  _qm_put "$r" src/side.rs 'pub fn s(x: Option<u8>) -> u8 { x.unwrap() }\n'
  _qm_commit "$r" "side debt"
  ( cd "$r" && git checkout -q - && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" merge -q --no-commit --no-ff side >/dev/null 2>&1 )
  _nm_scan "$r" "$log"; t_expect_rc 0 "$?" "a merge does not re-judge the other parent's lines"
  _nm_clean "merge"
  gg_rmrepo "$r"

  # Staged Python still reaches the scanner (control: the marker appears).
  r="$(gg_mktemp_repo)" || { t_fail "repo"; rm -rf "$_nm_lab"; return; }
  _qm_put "$r" src/lib.rs 'pub fn ok() {}\n'
  _qm_put "$r" app.py 'x = 1\n'
  _nm_scan "$r" "$log"
  if [ -s "$_nm_marker" ]; then t_ok "staged Python still goes to the scanner"; else t_fail "staged Python still goes to the scanner"; fi
  : > "$_nm_marker"
  gg_rmrepo "$r"
  rm -rf "$_nm_lab"
}
