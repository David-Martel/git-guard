#!/bin/sh
# Category 27 — every bundled ast-grep rule has one input that must fire and one
# that must not.
#
# Behaviour protected: each rules-examples/*.yml rule matches the code shape its
# message describes, and stays quiet on the corrected form. Category 7 proves a
# rule PARSES; that is not the same claim. A rule can parse, load into the
# validated cache and never match anything, and the gate then reports a clean
# commit for code the rule exists to catch. qa_gate.sh blocks on these rules
# under `astgrep=block` / `astgrep_panics=block|strict` and always for the BLOCK
# trio, so an inert rule is a block that cannot fail.
#
# What a failure means:
#   * "fires on ..." failed: the rule no longer matches its own example. A repo
#     relying on it (directly, or through astgrep=block) is no longer protected.
#   * "quiet on ..." failed: the rule now matches the corrected code. Under
#     astgrep=block that refuses commits that did the right thing.
#   * "every bundled rule has a row" failed: a rule was added without a
#     failing/passing pair. Add a row below (or an _rb_inert row with the reason).
#
# Rules that cannot fire for a structural reason are recorded with _rb_inert:
# they print a [skip] with the reason on every run and are listed as such in
# docs/RULES.md. They are NOT asserted to stay quiet, because that would
# enshrine the defect.
# Rules with no sound failing/passing pair use _rb_known_gap instead. In
# particular, safe code must not become a must-fire input just because an
# existing rule overmatches it. Correcting that rule must remain possible.
#
# Requirement: dtm-claude docs/reference/DOCUMENTATION_AND_TEST_STANDARD.md §1
# ("every rule and gate ships with at least one input that must fail and one
# that must pass"). Rows are evaluated with `ast-grep scan --rule <yml>` so each
# rule is tested in isolation; fixture paths satisfy each rule's `files:` globs
# (most Rust rules only match under src/ and never under tests/).
#
# Fixtures are generated in the suite temp root at run time. Nothing here is
# committed as a source file of the target language, so git-guard's own gate
# never scans these snippets as code.
# shellcheck shell=sh

# _rb_bin — echo the genuine ast-grep CLI (util-linux `sg` shadows it on Linux).
_rb_bin() {
  if have ast-grep && ast-grep --version 2>/dev/null | grep -qi 'ast-grep'; then
    echo ast-grep
  else
    echo sg
  fi
}

# _rb_hits RULE PATH CONTENT — write CONTENT to PATH in a fresh scratch dir and
# echo how many matches the single rule RULE (a path under rules-examples/)
# reports for it.
_rb_hits() {
  _rb_d="$(mktemp -d "$GG_T_TMPROOT/rb.XXXXXX")" || { echo "-1"; return 0; }
  mkdir -p "$_rb_d/$(dirname "$2")"
  printf '%s\n' "$3" > "$_rb_d/$2"
  ( cd "$_rb_d" && "$_RB_SG" scan --rule "$GG_BUNDLED/$1" --json=compact "$2" 2>/dev/null ) \
    | grep -o '"ruleId"' | wc -l | tr -d ' '
  rm -rf "$_rb_d"
}

# _rb_row RULE PATH FAILING PASSING — FAILING must produce at least one match,
# PASSING must produce none. The failing half is the positive control for the
# passing half: if the rule stopped loading, "quiet" would be vacuous, and the
# failing half catches exactly that.
_rb_row() {
  _RB_SEEN="$_RB_SEEN $1"
  _rb_n="$(_rb_hits "$1" "$2" "$3")"
  if [ "$_rb_n" -ge 1 ] 2>/dev/null; then t_ok "$1 fires on its failing input ($_rb_n match)"
  else t_fail "$1 does NOT fire on its failing input ($2): the rule is inert"; fi
  _rb_n="$(_rb_hits "$1" "$2" "$4")"
  if [ "$_rb_n" = "0" ]; then t_ok "$1 is quiet on its passing input"
  else t_fail "$1 fires on its passing input ($2, $_rb_n match): false positive"; fi
}

# _rb_inert RULE REASON — a rule that cannot fire as written. Visible as a skip.
_rb_inert() {
  _RB_SEEN="$_RB_SEEN $1"
  t_skip "$1 cannot fire: $2"
}

# _rb_known_gap RULE REASON — do not enforce a false positive as expected safety.
_rb_known_gap() {
  _RB_SEEN="$_RB_SEEN $1"
  t_skip "$1 has no sound failing/passing pair: $2"
}

# _rb_fires_only RULE PATH FAILING REASON — the rule fires on its failing input
# (asserted) but also fires on the corrected form, so no passing input exists
# yet. The missing half is a visible skip with the reason.
_rb_fires_only() {
  _RB_SEEN="$_RB_SEEN $1"
  _rb_n="$(_rb_hits "$1" "$2" "$3")"
  if [ "$_rb_n" -ge 1 ] 2>/dev/null; then t_ok "$1 fires on its failing input ($_rb_n match)"
  else t_fail "$1 does NOT fire on its failing input ($2): the rule is inert"; fi
  t_skip "$1 has no passing input: $4"
}

t_case_rule_behaviour() {
  t_begin "27 bundled ast-grep rules: one failing and one passing input each"
  if ! gg_has_astgrep; then
    t_skip "rule behaviour: no genuine ast-grep CLI"
    return 0
  fi
  _RB_SG="$(_rb_bin)"
  _RB_SEEN=""

  # ---- core -----------------------------------------------------------------
  _rb_inert core/fix-empty-catch.yml \
    "pattern 'catch { \$\$\$BODY }' parses to an ERROR node in C#, so it never matches a catch_clause"
  _rb_row core/flag-absolute-paths-rs.yml src/main.rs \
    'fn main() { let p = "C:\\Users\\someone\\PC_AI\\data"; }' \
    'fn main() { let p = "data/PC_AI"; }'
  _rb_row core/prefer-uv-python.yml scripts/run.sh \
    'python3 build.py' \
    'uv run python build.py'

  # ---- csharp ---------------------------------------------------------------
  # The pattern parses as a local_function_statement, so it fires on a local
  # function but NOT on a class method `async void M()` (docs/RULES.md).
  _rb_row csharp/avoid-async-void.yml src/A.cs \
    'class A { void M() { async void L() { await T(); } } }' \
    'class A { void M() { async Task L() { await T(); } } }'
  _rb_row csharp/avoid-generic-catch.yml src/A.cs \
    'class A { void M() { try { F(); } catch (Exception ex) { } } }' \
    'class A { void M() { try { F(); } catch (Exception ex) { Log(ex); } } }'
  _rb_row csharp/avoid-task-result.yml src/A.cs \
    'class A { int M(Task<int> t) { return t.Result; } }' \
    'class A { async Task<int> M(Task<int> t) { return await t; } }'
  _rb_inert csharp/dispose-pattern.yml \
    "the TYPE constraint 'pattern: HttpClient' parses to an ERROR node in C#, so no type ever satisfies it"
  _rb_row csharp/prefer-string-interpolation.yml src/A.cs \
    'class A { string M(int x) { return String.Format("{0}", x); } }' \
    'class A { string M(int x) { return $"{x}"; } }'
  _rb_fires_only csharp/require-configure-await.yml src/A.cs \
    'class A { async Task M(Task t) { await t; } }' \
    "the not: clause reuses \$TASK, already bound to 't.ConfigureAwait(false)', so 'await t.ConfigureAwait(false);' is flagged too"

  # ---- powershell -----------------------------------------------------------
  # Both rules declare `language: bash`, so ast-grep applies them to *.sh/*.bash
  # and never to *.ps1 (tests/12-powershell.t.sh measures 0 findings on a .ps1).
  # PSScriptAnalyzer is the real PowerShell check (qa_gate.sh qa_check_powershell).
  _rb_inert powershell/no-invoke-expression.yml \
    "language: bash never matches a .ps1 file (see tests/12-powershell.t.sh)"
  _rb_inert powershell/prefer-write-verbose.yml \
    "language: bash never matches a .ps1 file (see tests/12-powershell.t.sh)"

  # ---- python ---------------------------------------------------------------
  _rb_row python/bare-except.yml src/m.py \
    'try:
    f()
except:
    raise' \
    'try:
    f()
except Exception:
    raise'
  _rb_row python/broad-suppress.yml src/m.py \
    'with contextlib.suppress(Exception):
    f()' \
    'with contextlib.suppress(FileNotFoundError):
    f()'
  _rb_row python/prefer-pathlib.yml src/m.py \
    'ok = os.path.exists(p)' \
    'ok = pathlib.Path(p).exists()'
  _rb_row python/silent-except-continue.yml src/m.py \
    'for x in xs:
    try:
        f(x)
    except ValueError:
        continue' \
    'for x in xs:
    try:
        f(x)
    except ValueError:
        logger.warning("skipped %s", x)
        continue'
  _rb_row python/silent-except-pass.yml src/m.py \
    'try:
    f()
except OSError:
    pass' \
    'try:
    f()
except OSError:
    logger.exception("f failed")'
  _rb_row python/silent-except-sentinel.yml src/m.py \
    'def g():
    try:
        return f()
    except OSError:
        return None' \
    'def g():
    try:
        return f()
    except OSError:
        logger.exception("f failed")
        return None'

  # ---- rust -----------------------------------------------------------------
  _rb_row rust/avoid-println.yml src/main.rs \
    'fn main() { println!("x"); }' \
    'fn main() { tracing::info!("x"); }'
  # Only the struct-field patterns fire. The `pub fn ... -> Arc<$T>` patterns
  # parse as bodiless signatures and never match a function with a body.
  _rb_row rust/avoid-public-arc-box.yml src/lib.rs \
    'pub struct S { pub inner: Arc<u32> }' \
    'pub struct S { inner: Arc<u32> }'
  _rb_row rust/avoid-static-mut.yml src/lib.rs \
    'static mut C: u32 = 0;' \
    'static C: AtomicU32 = AtomicU32::new(0);'
  _rb_fires_only rust/avoid-sync-mutex-in-async.yml src/lib.rs \
    'async fn f() { let m = std::sync::Mutex::new(0); let guard = m.lock().unwrap(); task().await; drop(guard); }' \
    "the rule also flags ordinary synchronous std::sync::Mutex use; no safe synchronous passing input is established"
  _rb_row rust/avoid-unwrap.yml src/lib.rs \
    'fn f(x: Option<u8>) -> u8 { x.unwrap() }' \
    'fn f(x: Option<u8>) -> u8 { x.unwrap_or(0) }'
  _rb_inert rust/clone-in-hot-loop.yml \
    "inside: has no stopBy: end, so only a clone() whose DIRECT parent is the loop node matches, which a loop body never is"
  _rb_row rust/inefficient-string-allocation.yml src/lib.rs \
    'fn f() -> String { "x".to_string() }' \
    'fn f() -> String { "x".to_owned() }'
  _rb_row rust/missing-error-context.yml src/lib.rs \
    'fn f() -> Result<()> { g()?; Ok(()) }' \
    'fn f() -> Result<()> { g().context("g failed")?; Ok(()) }'
  _rb_row rust/no-glob-reexport.yml src/lib.rs \
    'pub use inner::*;' \
    'pub use inner::a;'
  _rb_row rust/prefer-collect-result.yml src/lib.rs \
    'fn f() { let v = it.map(p).filter(q).collect::<Vec<u8>>(); }' \
    'fn f() { let v = it.map(p).collect::<Result<Vec<u8>, E>>(); }'
  _rb_row rust/prefer-expect-over-allow.yml src/lib.rs \
    '#[allow(dead_code)]
fn f() {}' \
    '#[expect(dead_code, reason = "kept for the FFI table")]
fn f() {}'
  _rb_inert rust/prefer-pathbuf.yml \
    "every pattern is a bodiless fn signature (function_signature_item), which never matches a function with a body"
  _rb_inert rust/require-mimalloc.yml \
    "pattern 'fn main()' is a bodiless signature (function_signature_item) and never matches 'fn main() { ... }'"
  _rb_row rust/use-char-indices.yml src/lib.rs \
    'fn f(s: &str) { for (i, c) in s.chars().enumerate() {} }' \
    'fn f(s: &str) { for (i, c) in s.char_indices() {} }'
  _rb_inert rust/vec-push-in-loop.yml \
    "inside: has no stopBy: end, so only a push() whose DIRECT parent is the loop node matches, which a loop body never is"

  # ---- rust/panics ----------------------------------------------------------
  _rb_row rust/panics/as-ref-unwrap.yml src/lib.rs \
    'fn f(x: &Option<String>) -> &String { x.as_ref().unwrap() }' \
    'fn f(x: &Option<String>) -> Option<&String> { x.as_ref() }'
  _rb_row rust/panics/expect-call.yml src/lib.rs \
    'fn f(x: Option<u8>) -> u8 { x.expect("present") }' \
    'fn f(x: Option<u8>) -> Option<u8> { Some(x?) }'
  _rb_known_gap rust/panics/fixed-size-init.yml \
    "typed array initialization is compile-time size checked; matching a safe [0; 4] array is a false positive, not a panic hazard"
  _rb_row rust/panics/library-unwrap.yml src/lib.rs \
    'fn f(x: Option<u8>) -> u8 { x.unwrap() }' \
    'fn f(x: Option<u8>) -> u8 { x.unwrap_or(0) }'
  _rb_inert rust/panics/match-arm-unwrap.yml \
    "the match_block of the pattern parses to an ERROR node, so it never matches a real match expression"
  _rb_row rust/panics/panic-macro.yml src/lib.rs \
    'fn f() { panic!("bad state"); }' \
    'fn f() -> Result<(), E> { Err(E::BadState) }'
  _rb_row rust/panics/string-slice-panic.yml src/lib.rs \
    'fn f(s: &str) -> &str { &s[1..3] }' \
    'fn f(s: &str) -> Option<&str> { s.get(1..3) }'
  _rb_row rust/panics/todo-macro.yml src/lib.rs \
    'fn f() { todo!() }' \
    'fn f() -> Result<(), E> { Err(E::NotYet) }'
  _rb_row rust/panics/try-from-unwrap.yml src/lib.rs \
    'fn f(x: u32) -> u8 { u8::try_from(x).unwrap() }' \
    'fn f(x: u32) -> Result<u8, E> { Ok(u8::try_from(x)?) }'
  _rb_row rust/panics/try-into-unwrap.yml src/lib.rs \
    'fn f(x: u32) -> u8 { x.try_into().unwrap() }' \
    'fn f(x: u32) -> Result<u8, E> { Ok(x.try_into()?) }'
  _rb_row rust/panics/unchecked-division.yml src/lib.rs \
    'fn f(a: u32, b: u32) -> u32 { a / b }' \
    'fn f(a: u32) -> u32 { a / 2 }'
  _rb_row rust/panics/unchecked-index.yml src/lib.rs \
    'fn f(v: &[u8], i: usize) -> u8 { v[i] }' \
    'fn f(v: &[u8], i: usize) -> Option<&u8> { v.get(i) }'
  _rb_row rust/panics/unimplemented-macro.yml src/lib.rs \
    'fn f() { unimplemented!() }' \
    'fn f() -> Result<(), E> { Err(E::Unsupported) }'
  _rb_row rust/panics/unreachable-macro.yml src/lib.rs \
    'fn f(k: u8) -> u8 { match k { 0 => 1, _ => unreachable!() } }' \
    'fn f(k: u8) -> u8 { match k { 0 => 1, _ => 0 } }'
  _rb_row rust/panics/unsafe-with-panic.yml src/lib.rs \
    'fn f() { unsafe { let p: *const i32 = std::ptr::null(); if p.is_null() { panic!("null"); } } }' \
    'fn f() -> bool { unsafe { let p: *const i32 = std::ptr::null(); p.is_null() } }'
  _rb_row rust/panics/unwrap-call.yml src/lib.rs \
    'fn f(x: Option<u8>) -> u8 { x.unwrap() }' \
    'fn f(x: Option<u8>) -> u8 { x.unwrap_or(0) }'

  # ---- security -------------------------------------------------------------
  _rb_row security/no-eval.yml src/a.js \
    'eval(code);' \
    'JSON.parse(code);'
  # The literal is a placeholder so secret_scan.sh leaves this file alone; the
  # rule matches any quoted literal bound to a secret-named variable.
  _rb_secret_bad='const apiToken = "FAKE-PLACEHOLDER";'           # pragma: allowlist secret
  _rb_secret_good='const apiToken = process.env.API_TOKEN;'        # pragma: allowlist secret
  _rb_row security/no-hardcoded-secrets.yml src/a.ts "$_rb_secret_bad" "$_rb_secret_good"
  _rb_row security/no-innerhtml.yml src/a.js \
    'el.innerHTML = html;' \
    'el.textContent = html;'

  # ---- typescript -----------------------------------------------------------
  _rb_inert typescript/no-any-type.yml \
    "pattern '\$VAR: any' parses as a labeled_statement, not a type annotation"
  _rb_row typescript/no-console-log.yml src/a.ts \
    'console.log(x);' \
    'logger.info(x);'
  _rb_fires_only typescript/no-useless-async.yml src/a.ts \
    'async function f(x) { return x; }' \
    "not: has: lacks stopBy: end, so an await nested in a return ('return await g(x);') is not seen and the function is flagged"
  _rb_row typescript/no-var-declaration.yml src/a.ts \
    'var x = 1;' \
    'let x = 1;'
  _rb_row typescript/prefer-const.yml src/a.ts \
    'let x = 1;' \
    'const x = 1;'

  # ---- completeness: no bundled rule without a row --------------------------
  _rb_missing=""
  for _rb_f in $(cd "$GG_BUNDLED" && gg_find . -name '*.yml' | sed 's|^\./||' | sort); do
    case " $_RB_SEEN " in
      *" $_rb_f "*) : ;;
      *) _rb_missing="$_rb_missing $_rb_f" ;;
    esac
  done
  if [ -z "$_rb_missing" ]; then
    t_ok "every bundled rule has a failing/passing row (or a recorded inert reason)"
  else
    t_fail "bundled rule(s) with no failing/passing row in tests/27-rule-behaviour.t.sh:$_rb_missing"
  fi
  return 0
}
