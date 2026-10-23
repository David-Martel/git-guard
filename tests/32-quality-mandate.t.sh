#!/bin/sh
# Category 32 — the owner's quality mandate (hooks/common/mandate_scan.sh).
#
# Behaviour protected:
#   * --staged blocks a mandate finding on a line the commit adds or modifies,
#     and lets pre-existing debt in the same file through untouched; the line
#     mapping is exact at the first line of a file (ast-grep ranges are 0-based,
#     git and ruff are 1-based).
#   * pydantic v1, explicit Any, silent excepts, Rust panics block; test files
#     are exempt from the no-Any / silent-failure / panic rules but NOT from the
#     pydantic rule; vendored trees are exempt entirely.
#   * a mandate suppression needs a recorded reason (`SAFETY:`); with one, the
#     suppressed finding passes.
#   * per-rule `mandate.<rule>=off|warn|changed|block` takes effect, and an
#     unknown value is a TOOL ERROR, not a default.
#   * the debt register (.git-guard/mandate-baseline.json) blocks MALFORMED,
#     REGRESSION, UNRATCHETED, UNDECLARED and STALE, passes when it holds, and is
#     wired into hooks/pre-push only for commits that carry it.
#   * a scanner that exits 2 or prints unparseable output is a TOOL ERROR that
#     blocks, and so is an installed `ast-grep` whose version probe fails; a
#     scanner that is not installed (or a util-linux `sg`) is a WARN naming the
#     unevaluated rules (the anti-brick rule).
#   * repository policy (.qa-gate.conf) is read from the snapshot being checked:
#     the index at pre-commit, each pushed commit at pre-push.
#   * qa_gate.sh calls the scanner at pre-commit; QA_KNOWN_KEYS, the
#     qa-gate.conf defaults and the scanner's RULES table name the same keys.
#
# What a failure means: a mandate rule that cannot fail (a gate that reports
# clean on the code it exists to refuse), a rule that blocks old debt and so
# bricks every edit to a legacy file, a tool failure read as "no findings", or
# a ratchet that silently lets the backlog grow.
#
# Requirement: owner quality mandate 2026-10-14 (docs/QA_TOOLING.md "Quality
# mandate"); dtm-claude docs/reference/DOCUMENTATION_AND_TEST_STANDARD.md §1
# (every rule ships with an input that must fail and one that must pass).
# Needs ruff and a genuine ast-grep; each part self-SKIPs naming the missing
# tool. Fixtures are generated in the suite temp root at run time.
# shellcheck shell=sh

_QM_SCAN="$GG_ROOT/hooks/common/mandate_scan.sh"

# _qm_repo — a fresh fixture repo (path on stdout).
_qm_repo() { gg_mktemp_repo; }

# _qm_put REPO PATH CONTENT — write CONTENT (printf %b) to REPO/PATH and stage it.
_qm_put() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%b' "$3" > "$1/$2"
  ( cd "$1" && git add -- "$2" )
}

# _qm_commit REPO MSG — record fixture history. core.hooksPath points at an
# empty directory so the machine's installed hooks (a global core.hooksPath)
# cannot judge fixture setup commits; the code under test is run explicitly.
_qm_commit() {
  mkdir -p "$GG_T_TMPROOT/qm-no-hooks"
  ( cd "$1" && git add -A && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit -q -m "$2" )
}

# _qm_conf REPO TEXT — write TEXT (printf %b) as the repo's .qa-gate.conf and
# STAGE it: the scanner reads policy from the snapshot it scans (the index at
# pre-commit), so an unstaged conf deliberately has no effect.
_qm_conf() {
  printf '%b' "$2" > "$1/.qa-gate.conf"
  ( cd "$1" && git add .qa-gate.conf )
}

# _qm_scan REPO LOG ARGS... — run the scanner in REPO, stderr to LOG.
_qm_scan() {
  _qm_r="$1"; _qm_l="$2"; shift 2
  ( cd "$_qm_r" && sh "$_QM_SCAN" "$@" ) >/dev/null 2>"$_qm_l"
}

# _qm_push REPO LOG — run hooks/pre-push for the ref list in $GG_T_TMPROOT/qm-refs.
# The downstream chain is pinned to a no-op so an installed lefthook cannot
# change the result.
_qm_push() {
  printf '#!/bin/sh\nexit 0\n' > "$GG_T_TMPROOT/qm-noop-downstream"
  chmod +x "$GG_T_TMPROOT/qm-noop-downstream"
  ( cd "$1" && GIT_GUARD_DOWNSTREAM_PRE_PUSH="$GG_T_TMPROOT/qm-noop-downstream" \
      sh "$GG_ROOT/hooks/pre-push" origin git@example ) <"$GG_T_TMPROOT/qm-refs" >"$2" 2>&1
}

# _qm_has LOG TEXT MSG — assert LOG contains TEXT (fixed string).
_qm_has() {
  if grep -qF -- "$2" "$1"; then t_ok "$3"; else
    t_fail "$3 (expected '$2' in output)"; sed 's/^/           /' "$1" | head -20 >&2
  fi
}

# _qm_lacks LOG TEXT MSG — assert LOG does not contain TEXT.
_qm_lacks() {
  if grep -qF -- "$2" "$1"; then
    t_fail "$3 (unexpected '$2' in output)"; sed 's/^/           /' "$1" | head -20 >&2
  else t_ok "$3"; fi
}

# _qm_swallow — a new except-pass handler (except_pass + blind_except).
_QM_SWALLOW='def probe():\n    try:\n        connect()\n    except Exception:\n        pass\n'
# _qm_narrow_swallow — narrow except-pass (except_pass only, no BLE001).
_QM_NARROW='def probe():\n    try:\n        connect()\n    except OSError:\n        pass\n'
_QM_CLEAN='\n\ndef added(value: int) -> int:\n    return value + 1\n'

t_case_quality_mandate() {
  t_begin "32 quality mandate: changed lines, rules, suppressions, debt register"
  log="$(gg_tmp_log)"

  if ! gg_has_python; then
    t_skip "quality mandate: no Python interpreter (the scanner needs python3)"
    return 0
  fi

  # ---- key inventory: one source of truth, three places ----------------------
  _qm_rules="$(sh "$_QM_SCAN" --list-rules | cut -f1 | sort | tr '\n' ' ')"
  _qm_conf="$(sed -n 's/^mandate\.\([a-z0-9_]*\)=.*/\1/p' "$GG_ROOT/hooks/common/qa-gate.conf" \
    | grep -vxE 'enabled|vendored' | sort | tr '\n' ' ')"
  # shellcheck disable=SC2016  # the sed pattern matches a literal "$QA_KNOWN_KEYS"
  _qm_known="$(sed -n 's/^QA_KNOWN_KEYS="\$QA_KNOWN_KEYS \(.*\)"$/\1/p' "$GG_ROOT/hooks/common/qa_gate.sh" \
    | tr ' ' '\n' | sed -n 's/^mandate\.//p' | grep -vxE 'enabled|vendored' | sort | tr '\n' ' ')"
  if [ -n "$_qm_rules" ] && [ "$_qm_rules" = "$_qm_conf" ] && [ "$_qm_rules" = "$_qm_known" ]; then
    t_ok "RULES, qa-gate.conf and QA_KNOWN_KEYS name the same mandate keys"
  else
    t_fail "mandate key drift: RULES='$_qm_rules' conf='$_qm_conf' known='$_qm_known'"
  fi
  _qm_defaults_rules="$(sh "$_QM_SCAN" --list-rules | cut -f1,2 | tr '\t' '=' | sort | tr '\n' ' ')"
  _qm_defaults_conf="$(sed -n 's/^mandate\.\([a-z0-9_]*\)=\([a-z]*\).*/\1=\2/p' \
    "$GG_ROOT/hooks/common/qa-gate.conf" | grep -v '^enabled=' | sort | tr '\n' ' ')"
  if [ "$_qm_defaults_rules" = "$_qm_defaults_conf" ]; then
    t_ok "qa-gate.conf defaults match the scanner's built-in defaults"
  else
    t_fail "default drift: RULES='$_qm_defaults_rules' conf='$_qm_defaults_conf'"
  fi

  if ! gg_has_ruff || ! gg_has_astgrep; then
    t_skip "quality mandate scans: need ruff and a genuine ast-grep (ruff=$(gg_has_ruff && echo y || echo n))"
    return 0
  fi

  # Protects: valid open-text commands and classification predicates stay usable.
  # Detects: name/return-shape heuristics silently promoted to account-wide vetoes.
  # Needs: genuine ast-grep/ruff above; isolated index, range and actual hook calls.
  # Breadcrumb: hooks/common/qa-gate.conf and mandate_scan.py RULES; agent-hooks#11.
  r="$(_qm_repo)"
  _qm_put "$r" README.md 'classifier fixture\n'
  _qm_commit "$r" "classification base"
  _qm_advisory_base="$(git -C "$r" rev-parse HEAD)"
  _qm_classifier='import shlex\n\n\ndef is_classifiable(command: str) -> bool:\n    """An unmatched quote means unclassified, not an operational failure."""\n    try:\n        shlex.split(command, posix=True)\n    except ValueError:\n        return False\n    return True\n'
  _qm_put "$r" src/classify.py "$_qm_classifier"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "default staged heuristics allow open command text and an intentional False predicate"
  _qm_has "$log" "WARN [except_sentinel]" "default sentinel heuristic remains visible as a warning"
  _qm_has "$log" "WARN [str_enum_param]" "default parameter-name heuristic remains visible as a warning"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "actual pre-commit permits the valid classifier under packaged defaults"
  _qm_has "$log" "WARN [except_sentinel]" "pre-commit retains the predicate advisory"
  _qm_has "$log" "WARN [str_enum_param]" "pre-commit retains the open-text advisory"
  for _qm_level in changed block; do
    for _qm_rule in except_sentinel str_enum_param; do
      _qm_conf "$r" "mandate.$_qm_rule=$_qm_level\n"
      _qm_scan "$r" "$log" --staged; rc=$?
      t_expect_rc 1 "$rc" "explicit staged $_qm_rule=$_qm_level still enforces the selected heuristic"
      _qm_has "$log" "BLOCK [$_qm_rule]" "the staged opt-in names $_qm_rule"
    done
  done
  _qm_conf "$r" ''
  _qm_commit "$r" "valid classifier under default advisory policy"
  _qm_scan "$r" "$log" --range "$_qm_advisory_base..HEAD"; rc=$?
  t_expect_rc 0 "$rc" "default range heuristics allow the same valid classifier"
  _qm_has "$log" "WARN [except_sentinel]" "range sentinel heuristic remains visible"
  _qm_has "$log" "WARN [str_enum_param]" "range open-text heuristic remains visible"
  for _qm_level in changed block; do
    for _qm_rule in except_sentinel str_enum_param; do
      _qm_conf "$r" "mandate.$_qm_rule=$_qm_level\n"
      _qm_commit "$r" "explicit range $_qm_rule=$_qm_level"
      _qm_scan "$r" "$log" --range "$_qm_advisory_base..HEAD"; rc=$?
      t_expect_rc 1 "$rc" "explicit range $_qm_rule=$_qm_level still enforces the selected heuristic"
      _qm_has "$log" "BLOCK [$_qm_rule]" "the range opt-in names $_qm_rule"
    done
  done
  _qm_conf "$r" ''
  _qm_put "$r" src/failure.py 'def catches_control_flow() -> bool:\n    try:\n        return True\n    except:\n        return False\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an unrelated actual bare-except violation still blocks with advisory defaults"
  _qm_has "$log" "BLOCK [bare_except]" "the positive blocking control retains its own rule"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 1 "$rc" "actual pre-commit still rejects the unrelated bare-except violation"
  gg_rmrepo "$r"

  # Protects: upgrading these defaults cannot replace a false veto with STALE.
  # Detects: legacy ceilings re-imposing a now-advisory rule at real pre-push.
  # Needs: a genuine old-policy baseline and snapshot policy; same scanners above.
  # Breadcrumb: mandate_scan.py check_baseline/evaluate_baseline; config defaults.
  r="$(_qm_repo)"
  _qm_put "$r" src/classify.py "$_qm_classifier"
  _qm_conf "$r" 'mandate.except_sentinel=changed\nmandate.str_enum_param=changed\n'
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "a legacy strict-policy baseline is generated by the real scanner"
  _qm_commit "$r" "legacy strict heuristic baseline"
  _qm_legacy_base="$(git -C "$r" rev-parse HEAD)"
  _qm_conf "$r" ''
  _qm_commit "$r" "adopt advisory defaults without rewriting legacy ceilings"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 0 "$rc" "legacy ceilings for the two WARN heuristics are advisory"
  _qm_has "$log" "WARN legacy baseline [except_sentinel]" "legacy predicate ceiling is reported honestly"
  _qm_has "$log" "WARN legacy baseline [str_enum_param]" "legacy command ceiling is reported honestly"
  _qm_tip="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_legacy_base" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "actual pre-push accepts the default-WARN legacy-baseline migration"
  _qm_put "$r" src/second.py "$_qm_classifier"
  _qm_commit "$r" "another valid classifier under advisory defaults"
  for _qm_level in changed block; do
    for _qm_rule in except_sentinel str_enum_param; do
      _qm_parent="$(git -C "$r" rev-parse HEAD)"
      _qm_conf "$r" "mandate.$_qm_rule=$_qm_level\n"
      _qm_commit "$r" "restore strict ratchet $_qm_rule=$_qm_level"
      _qm_scan "$r" "$log" --check-baseline; rc=$?
      t_expect_rc 1 "$rc" "explicit $_qm_rule=$_qm_level retains its legacy ratchet"
      _qm_has "$log" "BLOCK REGRESSION $_qm_rule" "the strict baseline names its actual new finding"
      _qm_tip="$(git -C "$r" rev-parse HEAD)"
      printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_parent" > "$GG_T_TMPROOT/qm-refs"
      _qm_push "$r" "$log"; rc=$?
      t_expect_rc 1 "$rc" "actual pre-push preserves the explicit $_qm_rule=$_qm_level ratchet"
    done
  done
  _qm_conf "$r" ''
  _qm_put "$r" src/second.py '\n'
  _qm_commit "$r" "restore valid advisory source"
  for _qm_negative in literal_enum unknown_rule malformed; do
    case "$_qm_negative" in
      literal_enum) _qm_register='{"version":1,"policy_revision":"git-guard-mandate-1","measured_at_commit":"fixture","rules":{"literal_enum":{"src/classify.py":1}}}'; _qm_problem=STALE ;;
      unknown_rule) _qm_register='{"version":1,"policy_revision":"git-guard-mandate-1","measured_at_commit":"fixture","rules":{"unknown_rule":{}}}'; _qm_problem=STALE ;;
      malformed) _qm_register='{"version":1,"policy_revision":"git-guard-mandate-1","measured_at_commit":"fixture","rules":{"except_sentinel":{"src/classify.py":0}}}'; _qm_problem=MALFORMED ;;
    esac
    _qm_parent="$(git -C "$r" rev-parse HEAD)"
    _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register\n"
    _qm_commit "$r" "negative legacy migration $_qm_negative"
    _qm_tip="$(git -C "$r" rev-parse HEAD)"
    printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_parent" > "$GG_T_TMPROOT/qm-refs"
    _qm_push "$r" "$log"; rc=$?
    t_expect_rc 1 "$rc" "actual pre-push still rejects unrelated $_qm_negative register state"
    _qm_has "$log" "BLOCK $_qm_problem" "the $_qm_negative control retains its original $_qm_problem failure"
  done
  gg_rmrepo "$r"

  # ---- changed lines: new swallow blocks, old debt does not -------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_SWALLOW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a staged new 'except Exception: pass' blocks"
  _qm_has "$log" "[except_pass]" "the block names the except_pass rule"
  _qm_has "$log" "fix:" "the block says how to fix it"
  _qm_has "$log" "SAFETY: <why this is correct>" "the block says how to record justified debt"
  _qm_has "$log" "git-guard mandate: BLOCKED" "the run ends in a determined BLOCKED summary"
  _qm_commit "$r" "debt"
  printf '%b' "$_QM_CLEAN" >> "$r/src/app.py"
  ( cd "$r" && git add src/app.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "pre-existing debt in a touched file + a clean added line passes"
  _qm_has "$log" "git-guard mandate: PASSED" "the pass is stated, not silent"
  gg_rmrepo "$r"

  # Actual Audio #118/main 04765ec: registry merges inherited widgets.py:83
  # Mapping[str, Any]. Protects: merge resolutions are new only versus ALL
  # parents; Detects: main-side debt falsely blocks an unrelated merge, or a
  # last-merge filter hides earlier unpublished branch debt in --range.
  # Needs: Git, ruff, ast-grep; Breadcrumb: mandate_scan.py staged_changes/range_changes.
  r="$(_qm_repo)"
  _qm_put "$r" widgets.py 'def guidance_html(data: str) -> str:\n    return str(data)\n'
  _qm_commit "$r" "clean merge base"
  _qm_merge_base="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && git checkout -qb topic )
  _qm_put "$r" registry.txt 'registry-only topic change\n'
  _qm_put "$r" topic.py "$_QM_NARROW"
  _qm_commit "$r" "unpublished topic debt before merge"
  ( cd "$r" && git checkout -qb main-side "$_qm_merge_base" )
  _qm_audio_main='from typing import Any, Mapping\n\ndef guidance_html(data: Mapping[str, Any], *, include_heading: bool = True) -> str:\n    return str(data)\n'
  _qm_put "$r" widgets.py "$_qm_audio_main"
  _qm_commit "$r" "Audio main-side Mapping[str, Any]"
  ( cd "$r" && git checkout -q topic && \
    git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" merge --no-ff --no-commit main-side ) >"$log" 2>&1
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "an Audio main-side Any inherited by a staged registry merge passes"
  printf '%b' "\n$_QM_NARROW" >> "$r/widgets.py"
  ( cd "$r" && git add widgets.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a genuinely new merge-resolution swallow still blocks"
  _qm_has "$log" "[except_pass]" "the merge resolution retains its new except_pass finding"
  _qm_put "$r" widgets.py "$_qm_audio_main"
  _qm_commit "$r" "merge main without new resolution debt"
  _qm_scan "$r" "$log" --range "$_qm_merge_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "a last merge cannot hide earlier unpublished branch debt from range scanning"
  _qm_has "$log" "topic.py" "the range still scans the earlier unpublished topic file"
  _qm_has "$log" "[except_pass]" "the earlier unpublished swallow remains blocked in the range"
  gg_rmrepo "$r"

  # PR #72 actual review: inter-hunk context joined clean edits across old debt.
  r="$(_qm_repo)"
  _qm_put "$r" app.py 'value = 1\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        pass\n\nvalue2 = 1\n'
  _qm_commit "$r" "existing debt between clean edits"
  _qm_put "$r" app.py 'value = 2\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        pass\n\nvalue2 = 2\n'
  ( cd "$r" && git config diff.interHunkContext 20 )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "inter-hunk context cannot turn unchanged debt into staged findings"
  gg_rmrepo "$r"

  # PR #72 actual review: Git LF rows and Ruff CR rows disagreed and passed debt.
  r="$(_qm_repo)"
  ( cd "$r" && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit --allow-empty -qm "base" )
  _qm_cr_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" app.py 'import subprocess\rsubprocess.run(["false"])\r'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "lone-CR staged source is a tool error, never a clean scan"
  _qm_has "$log" "lone CR line endings" "the staged error explains ambiguous line coordinates"
  _qm_commit "$r" "CR source"
  _qm_scan "$r" "$log" --range "$_qm_cr_base..HEAD"; rc=$?
  t_expect_rc 2 "$rc" "lone-CR range source is a tool error, never a clean scan"
  _qm_has "$log" "lone CR line endings" "the range error explains ambiguous line coordinates"
  gg_rmrepo "$r"

  # Pure renames have no +++ header, but their destinations still need BLOCK rules.
  r="$(_qm_repo)"
  _qm_put "$r" legacy.txt 'from pydantic.v1 import BaseModel\n'
  _qm_put "$r" literal.txt 'from typing import Literal\n\n\ndef f(c: Literal["a", "b"]) -> None:\n    print(c)\n'
  _qm_commit "$r" "non-source inputs"
  _qm_rename_base="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && git mv legacy.txt app.py && git mv literal.txt literal.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a pure staged rename into Python still enforces whole-file BLOCK rules"
  _qm_lacks "$log" "[literal_enum]" "a pure rename adds no lines to warn on"
  _qm_commit "$r" "source renames"
  _qm_scan "$r" "$log" --range "$_qm_rename_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "a pure range rename into Python still enforces whole-file BLOCK rules"
  gg_rmrepo "$r"

  # ---- line mapping is exact on line 1 (ast-grep 0-based vs git 1-based) -------
  r="$(_qm_repo)"
  _qm_put "$r" src/types_.py 'from typing import Optional\n\n\ndef f(x: Optional[int]) -> int:\n    return x or 0\n'
  _qm_commit "$r" "base"
  _qm_put "$r" src/types_.py 'from typing import Any, Optional\n\n\ndef f(x: Optional[int]) -> int:\n    return x or 0\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an Any import introduced on line 1 is caught on line 1"
  _qm_has "$log" "src/types_.py:1 " "the finding is reported at line 1, not 0 or 2"
  gg_rmrepo "$r"

  # An added "++ 1" is valid Python but its diff line starts "+++ ". It must
  # not redirect a later hunk's finding to a made-up path (PR #72 review 6200036532).
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py 'value = 1\n\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        raise\n'
  _qm_commit "$r" "header-like source base"
  _qm_header_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py '++ 1\nvalue = 1\n\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        pass\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "header-like added source does not hide a later staged violation"
  _qm_has "$log" "[except_pass]" "the staged later hunk retains its except_pass finding"
  _qm_commit "$r" "header-like source with later violation"
  _qm_scan "$r" "$log" --range "$_qm_header_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "header-like added source does not hide a later range violation"
  _qm_has "$log" "[except_pass]" "the range later hunk retains its except_pass finding"
  gg_rmrepo "$r"

  # ---- pydantic v1: blocks, including in test files ----------------------------
  r="$(_qm_repo)"
  # Exercise changed-line policy: BLOCK would find the violation regardless of hunks.
  _qm_conf "$r" 'mandate.pydantic_v1=changed\n'
  # Git records are LF-delimited; a source U+2028 must not reset the later hunk.
  _qm_put "$r" 'vendor\model.py' 'marker = "old"\n\nfrom pydantic import BaseModel\n'
  _qm_commit "$r" "clean pydantic fixture"
  _qm_put "$r" 'vendor\model.py' 'marker = "prefix diff --git a/fake b/fake"\n\nfrom pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "'from pydantic.v1 import BaseModel' blocks"
  _qm_has "$log" "[pydantic_v1]" "the block names pydantic_v1"
  gg_rmrepo "$r"
  # PR #72 actual review: this tracked filename was parsed as an ast-grep option.
  r="$(_qm_repo)"
  ( cd "$r" && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit --allow-empty -qm "base" )
  _qm_option_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" './--globs=!*.py' 'from pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an option-shaped filename cannot hide staged pydantic v1"
  _qm_has "$log" "[pydantic_v1]" "the option-shaped staged file retains its finding"
  ( cd "$r" && sh "$_QM_SCAN" --all ) >"$log.json" 2>"$log"
  "$(gg_python)" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["totals"]["pydantic_v1"] != 1)' "$log.json"; rc=$?
  t_expect_rc 0 "$rc" "whole-tree counts retain pydantic v1 in the option-shaped file"
  _qm_commit "$r" "option-shaped source"
  _qm_scan "$r" "$log" --range "$_qm_option_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "an option-shaped filename cannot hide range pydantic v1"
  _qm_has "$log" "[pydantic_v1]" "the option-shaped range file retains its finding"
  gg_rmrepo "$r"
  # PR #72 actual review: both scanners silently skipped valid Latin-1 Python.
  r="$(_qm_repo)"
  ( cd "$r" && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit --allow-empty -qm "base" )
  _qm_scan "$r" "$log" --write-baseline
  _qm_commit "$r" "clean encoding baseline"
  _qm_encoding_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" app.py '# coding: latin-1\n# \351\nfrom pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 staged source is a tool error, never a clean scan"
  _qm_has "$log" "is not UTF-8" "the source error names the required conversion"
  _qm_scan "$r" "$log" --all; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 census cannot report falsely clean counts"
  _qm_scan "$r" "$log" --write-baseline; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 source cannot create a falsely clean baseline"
  _qm_commit "$r" "Latin-1 source"
  _qm_scan "$r" "$log" --range "$_qm_encoding_base..HEAD"; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 range source is a tool error, never a clean scan"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 source cannot pass a falsely clean baseline"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" tests/test_model.py 'from pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "pydantic v1 in a test file still blocks (tests are not exempt)"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" src/model.py 'from pydantic import BaseModel, ConfigDict\n\n\nclass M(BaseModel):\n    model_config = ConfigDict(extra="forbid")\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a v2 model with model_config passes"
  gg_rmrepo "$r"

  # ---- no explicit Any; test files exempt ---------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/f.py 'from typing import Any\n\n\ndef f(x: Any) -> None:\n    print(x)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an added 'def f(x: Any) -> None' blocks"
  _qm_has "$log" "[no_any]" "the block names no_any"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" tests/test_f.py 'from typing import Any\n\n\ndef f(x: Any) -> None:\n    print(x)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "explicit Any in tests/ is exempt"
  gg_rmrepo "$r"

  # ---- vendored trees are exempt entirely ---------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" vendor/lib/app.py "$_QM_SWALLOW"
  _qm_put "$r" external_systems/x/app.py "$_QM_SWALLOW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "vendor/ and external*/ are exempt"
  _qm_put "$r" qobi/chumpy/ch.py "$_QM_SWALLOW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "control: an undeclared third-party tree is scanned"
  _qm_conf "$r" 'mandate.vendored=qobi/chumpy\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.vendored=qobi/chumpy exempts the declared tree"
  _qm_conf "$r" 'mandate.vendored=../outside\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "a mandate.vendored entry escaping the repo is a config TOOL ERROR"
  gg_rmrepo "$r"

  # ---- suppressions need a reason ----------------------------------------------
  r="$(_qm_repo)"
  # Preserve physical lines after U+2028 so a later changed suppression cannot vanish.
  _qm_put "$r" src/s.py 'import subprocess\n\nprint(1)\n'
  _qm_commit "$r" "clean suppression fixture"
  _qm_put "$r" src/s.py '# note x\nimport subprocess\nsubprocess.run(["true"])  # noqa: PLW1510\n\nprint(1)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "'# noqa: PLW1510' with no SAFETY reason blocks"
  _qm_has "$log" "[suppression_reason]" "the block names suppression_reason"
  _qm_lacks "$log" "[unchecked_subprocess]" "the noqa itself still suppresses PLW1510"
  _qm_put "$r" src/s.py '# note x\nimport subprocess\nsubprocess.run(["true"])  # noqa: PLW1510  # SAFETY: best-effort child status is intentionally ignored\n\nprint(1)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "the same noqa with '# SAFETY: <reason>' passes"
  _qm_put "$r" src/s.py '# ruff: noqa: E722\n\ndef probe():\n    try:\n        connect()\n    except:\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a file-level Ruff suppression without a reason blocks"
  ( cd "$r" && sh "$_QM_SCAN" --all ) >"$log.json" 2>"$log"
  "$(gg_python)" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["totals"]["suppression_reason"] != 1)' "$log.json"; rc=$?
  t_expect_rc 0 "$rc" "whole-tree counts retain the unjustified file-level suppression"
  _qm_put "$r" src/s.py '# ruff: noqa: E722  # SAFETY: all exceptions are immediately re-raised\n\ndef probe():\n    try:\n        connect()\n    except:\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a justified file-level Ruff suppression still passes"
  _qm_put "$r" src/s.py '# ruff: noqa: E722  # best-effort: all exceptions are immediately re-raised\n\ndef probe():\n    try:\n        connect()\n    except:\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a file-level Ruff suppression accepts the existing best-effort reason"
  _qm_put "$r" src/s.py '# ruff: noqa: PGH004\n\ndef probe():\n    try:\n        connect()\n    except:  # noqa\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a file-level PGH004 suppression cannot hide a blanket noqa"
  ( cd "$r" && sh "$_QM_SCAN" --all ) >"$log.json" 2>"$log"
  "$(gg_python)" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["totals"]["suppression_reason"] != 1)' "$log.json"; rc=$?
  t_expect_rc 0 "$rc" "whole-tree counts retain an attempted suppression of the suppression guard"
  _qm_put "$r" src/s.py '# ruff: noqa: PGH004  # SAFETY: reviewed suppression\n\ndef probe():\n    try:\n        connect()\n    except:  # noqa\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a reason cannot make the suppression guard self-suppressible"
  _qm_put "$r" src/s.py 'def probe():\n    try:\n        connect()\n    except OSError:  # ast-grep-ignore: mandate-except-pass  # SAFETY: optional probe\n        pass\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a same-line ast-grep-ignore with a reason suppresses on every ast-grep version"
  # Only comments count: a string that MENTIONS a suppression neither needs a
  # reason nor suppresses anything (found by running the gate on mandate_scan.py).
  _qm_put "$r" src/s.py 'HELP = "write # noqa: BLE001 or ast-grep-ignore on the line"\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a string literal mentioning '# noqa: BLE001' is not a suppression"
  _qm_put "$r" src/s.py 'def probe():\n    try:\n        connect()\n    except OSError:\n        x = "ast-grep-ignore: mandate-except-pass"\n        pass\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an ast-grep-ignore inside a string does not suppress a finding"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic\nfn probe() { panic!("failed"); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a Rust-only mandate suppression without a reason blocks"
  _qm_has "$log" "[suppression_reason]" "the Rust-only block names suppression_reason"
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic  # SAFETY: fixture exercises a deliberate panic\nfn probe() { panic!("failed"); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "the same Rust-only suppression with a reason passes"
  gg_rmrepo "$r"

  # ---- per-rule severity ---------------------------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/n.py "$_QM_NARROW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "control: a narrow except-pass blocks at the default severity"
  _qm_conf "$r" 'mandate.except_pass=off\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.except_pass=off lets it through"
  _qm_conf "$r" 'mandate.except_pass=warn\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.except_pass=warn does not block"
  _qm_has "$log" "WARN [except_pass]" "warn still reports the finding"
  _qm_conf "$r" 'mandate.except_pass=sometimes\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "an unknown severity value is a TOOL ERROR, not a default"
  _qm_has "$log" "mandate.except_pass=sometimes is not one of" "the error names the bad value"
  _qm_conf "$r" 'mandate.enabled=off\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.enabled=off switches the layer off"
  gg_rmrepo "$r"

  # ---- whole-file `block` reaches old debt; `changed` does not -----------------
  r="$(_qm_repo)"
  _qm_put "$r" src/old.py "$_QM_NARROW"
  _qm_commit "$r" "debt"
  printf '%b' "$_QM_CLEAN" >> "$r/src/old.py"
  ( cd "$r" && git add src/old.py )
  _qm_conf "$r" 'mandate.except_pass=block\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "mandate.except_pass=block refuses old debt anywhere in a staged file"
  gg_rmrepo "$r"

  # ---- Rust panics: production blocks, test code passes ------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap()\n}\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an added .unwrap() in non-test Rust blocks"
  _qm_has "$log" "[rust_panic]" "the block names rust_panic"
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap_or(0)\n}\n\n#[cfg(test)]\n#[allow(dead_code)]\nmod tests {\n    fn helper() { Some(1).unwrap(); }\n}\n'
  _qm_put "$r" tests/it.rs 'fn t() { Some(1).unwrap(); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" ".unwrap() inside stacked #[cfg(test)] attributes and under tests/ passes"
  _qm_put "$r" src/lib.rs '#[test]\n#[ignore]\nfn t() { Some(1).unwrap(); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" ".unwrap() inside stacked #[test] attributes passes"
  printf '%b' '\npub fn production() { Some(1).unwrap(); }\n' >> "$r/src/lib.rs"
  ( cd "$r" && git add src/lib.rs )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a preceding test attribute does not exempt the next production item"
  gg_rmrepo "$r"

  # Actual review #72: untracked attributes must not smudge scanned source.
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  _qm_commit "$r" "clean source"
  _qm_scan "$r" "$log" --write-baseline
  _qm_commit "$r" "clean baseline"
  _qm_before_diff="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "raw staged source contains the except-pass before attributes"
  printf '*.py -diff\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "untracked binary attributes cannot hide a staged source finding"
  _qm_smudge="$GG_T_TMPROOT/qm-smudge"
  printf '#!/bin/sh\ncat >/dev/null\nprintf "value = 1\\n"\n' > "$_qm_smudge"
  chmod +x "$_qm_smudge"
  ( cd "$r" && git config filter.qm-smudge.clean cat && git config filter.qm-smudge.smudge "$_qm_smudge" )
  printf '*.py filter=qm-smudge\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "untracked checkout attributes cannot hide a staged except-pass"
  rm "$r/.gitattributes"
  _qm_commit "$r" "source regression"
  printf '*.py -diff\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --range "$_qm_before_diff..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "untracked binary attributes cannot hide a range source finding"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "raw committed source exceeds its baseline before attributes"
  printf '*.py filter=qm-smudge\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "untracked checkout attributes cannot hide committed baseline regression"
  gg_rmrepo "$r"

  # ---- warn-level rule (Literal-as-enum) reports and passes --------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/l.py 'from typing import Literal\n\n\ndef f(c: Literal["a", "b"]) -> None:\n    print(c)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "Literal[\"a\", \"b\"] warns by default, does not block"
  _qm_has "$log" "WARN [literal_enum]" "the Literal enum warning is printed"
  gg_rmrepo "$r"

  # ---- tool failures fail closed; a missing tool warns -------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  mkdir -p "$r/.venv/bin"   # created after staging: the repo venv's ruff wins
  printf '#!/bin/sh\necho "error: injected selector failure" >&2\nexit 2\n' > "$r/.venv/bin/ruff"
  chmod +x "$r/.venv/bin/ruff"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "ruff exit 2 is a TOOL ERROR that blocks"
  _qm_has "$log" "TOOL ERROR [ruff]" "the TOOL ERROR names ruff"
  _qm_has "$log" "injected selector failure" "the TOOL ERROR carries ruff's stderr"
  printf '#!/bin/sh\necho "this is not json"\nexit 1\n' > "$r/.venv/bin/ruff"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "unparseable ruff output is a TOOL ERROR, never zero findings"
  _qm_has "$log" "unparseable JSON" "the TOOL ERROR says the output could not be parsed"
  printf '#!/bin/sh\nsleep 30\n' > "$r/.venv/bin/ruff"
  ( cd "$r" && GIT_GUARD_MANDATE_TIMEOUT=2 sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 2 "$rc" "a scanner that hangs past GIT_GUARD_MANDATE_TIMEOUT is a TOOL ERROR"
  _qm_has "$log" "did not finish within 2s" "the TOOL ERROR says the scanner hung"
  rm -rf "$r/.venv"
  _qm_bin="$GG_T_TMPROOT/qm-noruff-bin"
  mkdir -p "$_qm_bin"
  for _qm_t in sh git dirname env ast-grep sort tr; do
    _qm_p="$(command -v "$_qm_t" 2>/dev/null)" && ln -sf "$_qm_p" "$_qm_bin/$_qm_t"
  done
  # The interpreter itself, not a version-manager shim that needs PATH to work.
  _qm_p="$("$(gg_python)" -c 'import sys; print(sys.executable)' 2>/dev/null)" &&
    ln -sf "$_qm_p" "$_qm_bin/python3"
  if PATH="$_qm_bin" command -v ruff >/dev/null 2>&1; then
    t_skip "missing-ruff case: could not build a PATH without ruff"
  else
    ( cd "$r" && VIRTUAL_ENV='' PATH="$_qm_bin" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
    t_expect_rc 0 "$rc" "ruff not installed warns and does not block"
    _qm_has "$log" "ruff is not installed, so these rules were NOT evaluated" \
      "the warning names the unevaluated rules"
  fi
  # A python3 that is on PATH but cannot start (an unconfigured version-manager
  # shim) must read as "no interpreter", not as BLOCKED or TOOL ERROR.
  _qm_shim="$GG_T_TMPROOT/qm-shim-bin"
  mkdir -p "$_qm_shim"
  for _qm_t in sh git dirname; do
    _qm_p="$(command -v "$_qm_t" 2>/dev/null)" && ln -sf "$_qm_p" "$_qm_shim/$_qm_t"
  done
  printf '#!/bin/sh\necho "shim ERROR No version is set" >&2\nexit 1\n' > "$_qm_shim/python3"
  chmod +x "$_qm_shim/python3"
  ( cd "$r" && PATH="$_qm_shim" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 0 "$rc" "a python3 shim that cannot start warns and does not block"
  _qm_has "$log" "quality mandate was NOT evaluated" "the warning says the mandate did not run"
  gg_rmrepo "$r"

  # ---- debt register -----------------------------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_scan "$r" "$log" --write-baseline; rc=$?
  t_expect_rc 0 "$rc" "--write-baseline records the existing debt"
  _qm_commit "$r" "baseline"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 0 "$rc" "the register holds at the commit it was written for"
  _qm_has "$log" "debt register holds" "the hold is stated"
  printf '%b' "\n\ndef second():\n    try:\n        connect()\n    except OSError:\n        pass\n" >> "$r/src/app.py"
  _qm_commit "$r" "regress"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "a file whose count rose blocks (REGRESSION)"
  _qm_has "$log" "REGRESSION except_pass src/app.py: 2 finding(s), ceiling 1" "REGRESSION names rule, file and counts"
  printf '%b' "def probe():\n    return 1\n" > "$r/src/app.py"
  _qm_commit "$r" "fixed but not ratcheted"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "a count that fell without lowering the ceiling blocks (UNRATCHETED)"
  _qm_has "$log" 'delete rules.except_pass["src/app.py"]' "UNRATCHETED gives the exact JSON edit"
  # pre-push hook: the same register is enforced for a pushed commit.
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    0000000000000000000000000000000000000000 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "hooks/pre-push refuses a commit whose register does not hold"
  _qm_has "$log" "debt register does not hold" "pre-push says why"
  _qm_before_ratchet="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >/dev/null 2>&1
  _qm_commit "$r" "ratchet"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    "$_qm_before_ratchet" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "the ratchet commit passes when earlier debt is already remote"
  _qm_fault_bin="$GG_T_TMPROOT/qm-buffer-fault"
  mkdir -p "$_qm_fault_bin"
  printf '#!/bin/sh\nexit 1\n' > "$_qm_fault_bin/mktemp"
  chmod +x "$_qm_fault_bin/mktemp"
  PATH="$_qm_fault_bin:$PATH" _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "failed mandatory ref-buffer creation refuses the push"
  rm "$_qm_fault_bin/mktemp"
  printf '#!/bin/sh\nexit 1\n' > "$_qm_fault_bin/cat"
  chmod +x "$_qm_fault_bin/cat"
  PATH="$_qm_fault_bin:$PATH" _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "failed ref-buffer write refuses the push"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json '{"version": 1, "rules": []}\n'
  _qm_commit "$r" "malformed"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "a malformed register blocks"
  _qm_has "$log" "MALFORMED" "the block says MALFORMED"
  _qm_put "$r" .git-guard/mandate-baseline.json '{"version": 1, "policy_revision": "git-guard-mandate-1", "measured_at_commit": "x", "rules": {"literal_enum": {"src/app.py": 1}}}\n'
  _qm_commit "$r" "undeclared + stale"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "undeclared findings and a stale entry block"
  _qm_has "$log" "UNDECLARED except_pass" "a rule with findings and no entry is UNDECLARED"
  _qm_has "$log" "STALE rules.literal_enum" "an entry for a non-enforced rule is STALE"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  _qm_commit "$r" "no register"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    0000000000000000000000000000000000000000 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "a repo with no register pushes as before"
  _qm_lacks "$log" "git-guard mandate" "and the mandate prints nothing for it"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    1111111111111111111111111111111111111111 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "a no-register force push needs no local copy of the remote commit"
  _qm_lacks "$log" "TOOL ERROR" "an absent remote commit is not a scanner failure"
  gg_rmrepo "$r"

  # ---- every pushed commit is checked, not only the tip --------------------------
  # (git-guard #72 review, P1.) An intermediate commit with a malformed register
  # used to reach the remote whenever the tip's register was fine.
  r="$(_qm_repo)"
  _qm_put "$r" README.md 'base\n'
  _qm_commit "$r" "base"
  _qm_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json '{"version": 1, "rules": []}\n'
  _qm_commit "$r" "malformed in the middle"
  _qm_mid="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >/dev/null 2>&1
  _qm_commit "$r" "valid at the tip"
  _qm_tip="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_base" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "a malformed register in an intermediate pushed commit blocks"
  _qm_has "$log" "MALFORMED" "the block says MALFORMED"
  _qm_has "$log" "$(printf %s "$_qm_mid" | cut -c1-12)" "and names the intermediate commit"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" \
    1111111111111111111111111111111111111111 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "an absent remote commit does not hide an intermediate malformed register"
  _qm_has "$log" "MALFORMED" "the available local history still enforces its register"
  # positive control: once the remote already has the bad commit, only the tip is new.
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_mid" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "the same tip pushes once the remote already holds the bad commit"
  ( cd "$r" && git update-ref refs/remotes/origin/main "$_qm_mid" )
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" \
    1111111111111111111111111111111111111111 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "an unfetched remote replacement does not recheck already published debt"
  _qm_lacks "$log" "MALFORMED" "the known remote history remains outside the introduced commits"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >/dev/null 2>&1
  _qm_commit "$r" "valid source and register"
  _qm_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_commit "$r" "source-only register regression"
  _qm_mid="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  _qm_commit "$r" "source-only restoration"
  _qm_tip="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_base" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "a source-only intermediate register regression blocks"
  _qm_has "$log" "$(printf %s "$_qm_mid" | cut -c1-12)" "the source-only block names its introduced commit"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_mid" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "the restored tip passes once the intermediate commit is remote"
  gg_rmrepo "$r"

  # ---- a type change (symlink -> regular file) is scanned (git-guard #72 review) --
  r="$(_qm_repo)"
  _qm_conf "$r" 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\n'
  _qm_put "$r" README.md 'base\n'
  ( cd "$r" && mkdir -p src && ln -s ../README.md src/model.py )
  _qm_commit "$r" "symlink"
  _qm_type_base="$(git -C "$r" rev-parse HEAD)"
  rm -f "$r/src/model.py"
  _qm_put "$r" src/model.py 'from pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a symlink turned into a file with pydantic.v1 blocks (type change is scanned)"
  _qm_has "$log" "pydantic_v1" "the block names pydantic_v1"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 1 "$rc" "pre-commit dispatches mandate checks for a source type change"
  _qm_has "$log" "pydantic_v1" "pre-commit reports the actual type-change finding"
  _qm_commit "$r" "source replaces symlink"
  _qm_scan "$r" "$log" --range "$_qm_type_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "a range symlink-to-file type change enforces pydantic.v1"
  gg_rmrepo "$r"

  # Same review: added source symlinks caused exporter errors. Protect the
  # regular-file-only policy in staged/range/caller paths; detect alias target
  # text treated as source. Needs the symlink support used by the case above.
  r="$(_qm_repo)"
  _qm_conf "$r" 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\n'
  _qm_put "$r" README.md 'value = 1\n'
  _qm_commit "$r" "base"
  _qm_type_base="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && ln -s README.md alias.py && git add alias.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "an added Python symlink is skipped before staged export"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "pre-commit preserves the source-symlink skip policy"
  _qm_commit "$r" "source alias"
  _qm_scan "$r" "$log" --range "$_qm_type_base..HEAD"; rc=$?
  t_expect_rc 0 "$rc" "an added Python symlink is skipped before range export"
  gg_rmrepo "$r"

  # ---- repository policy is read from the same snapshot as the code ------------
  # (git-guard #72 review, P2.) The scanner used to read .qa-gate.conf from the
  # working tree once and apply it to every snapshot it scanned, so a pushed
  # branch was judged under whatever branch happened to be checked out, and an
  # unstaged conf edit decided what a commit was held to.
  _qm_register='{"version": 1, "policy_revision": "git-guard-mandate-1", "measured_at_commit": "fixture", "rules": {}}\n'
  r="$(_qm_repo)"
  _qm_put "$r" README.md 'base\n'
  _qm_commit "$r" "base"
  _qm_base="$(git -C "$r" rev-parse HEAD)"
  # ref A: its own conf declares lib/a vendored, so its except-pass is exempt.
  ( cd "$r" && git checkout -q -b ref-a "$_qm_base" )
  _qm_put "$r" .qa-gate.conf 'mandate.vendored=lib/a\n'
  _qm_put "$r" lib/a/app.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register"
  _qm_commit "$r" "ref a"
  _qm_a="$(git -C "$r" rev-parse HEAD)"
  # ref B: its own conf makes except_pass advisory, so its except-pass is not counted.
  ( cd "$r" && git checkout -q -b ref-b "$_qm_base" )
  _qm_put "$r" .qa-gate.conf 'mandate.except_pass=warn\n'
  _qm_put "$r" src/b.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register"
  _qm_commit "$r" "ref b"
  _qm_b="$(git -C "$r" rev-parse HEAD)"
  # ref C: no conf (policy on), an undeclared finding: its register does not hold.
  ( cd "$r" && git checkout -q -b ref-c "$_qm_base" )
  _qm_put "$r" src/c.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register"
  _qm_commit "$r" "ref c"
  _qm_c="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && git checkout -q --detach "$_qm_base" )
  printf 'refs/heads/ref-a %s refs/heads/ref-a %s\nrefs/heads/ref-b %s refs/heads/ref-b %s\n' \
    "$_qm_a" 0000000000000000000000000000000000000000 "$_qm_b" 0000000000000000000000000000000000000000 \
    > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "a two-ref push judges each ref by its own committed conf (vendored dir, severity)"
  _qm_lacks "$log" "UNDECLARED" "neither ref is checked under the other's (or the checkout's) policy"
  printf 'mandate.enabled=off\n' > "$r/.qa-gate.conf"   # untracked: the checkout opts out
  printf 'refs/heads/ref-c %s refs/heads/ref-c %s\n' "$_qm_c" 0000000000000000000000000000000000000000 \
    > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "a checkout with mandate.enabled=off still enforces a pushed ref whose own conf is on"
  _qm_has "$log" "UNDECLARED except_pass" "the pushed ref's register is evaluated"
  rm -f "$r/.qa-gate.conf"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" .qa-gate.conf 'mandate.except_pass=off\n'
  _qm_put "$r" src/n.py "$_QM_NARROW"
  printf 'mandate.except_pass=changed\n' > "$r/.qa-gate.conf"   # unstaged edit
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "the staged conf (except_pass=off) governs the commit, not the unstaged edit"
  _qm_has "$log" "policy: index" "the summary names the staged policy it applied"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" src/n.py "$_QM_NARROW"
  printf 'mandate.except_pass=off\nmandate.enabled=off\n' > "$r/.qa-gate.conf"   # never staged
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an unstaged conf that switches rules off does not relax the commit"
  printf 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\nmandate.enabled=off\n' \
    > "$r/.qa-gate.conf"
  gg_run_gate_log "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "qa_gate.sh defers to the staged mandate policy too"
  gg_rmrepo "$r"

  # ---- a broken ast-grep is a TOOL ERROR; an unrelated `sg` is "absent" -------
  # (git-guard #72 review, P2.) A known `ast-grep` executable whose version probe
  # fails used to fall through to the missing-tool WARN and pass.
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_SWALLOW"
  _qm_fake="$GG_T_TMPROOT/qm-fake-astgrep"
  mkdir -p "$_qm_fake"
  printf '#!/bin/sh\necho "ast-grep: cannot load runtime" >&2\nexit 3\n' > "$_qm_fake/ast-grep"
  chmod +x "$_qm_fake/ast-grep"
  ( cd "$r" && PATH="$_qm_fake:$PATH" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 2 "$rc" "an ast-grep whose --version exits 3 is a TOOL ERROR that blocks"
  _qm_has "$log" "TOOL ERROR [ast-grep]" "the TOOL ERROR names ast-grep"
  printf '#!/bin/sh\nexit 0\n' > "$_qm_fake/ast-grep"
  ( cd "$r" && PATH="$_qm_fake:$PATH" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 2 "$rc" "an ast-grep that prints no version is a TOOL ERROR too"
  _qm_sgbin="$GG_T_TMPROOT/qm-sg-bin"
  mkdir -p "$_qm_sgbin"
  for _qm_t in sh git dirname env sort tr ruff; do
    _qm_p="$(command -v "$_qm_t" 2>/dev/null)" && ln -sf "$_qm_p" "$_qm_sgbin/$_qm_t"
  done
  _qm_p="$("$(gg_python)" -c 'import sys; print(sys.executable)' 2>/dev/null)" &&
    ln -sf "$_qm_p" "$_qm_sgbin/python3"
  printf '#!/bin/sh\necho "sg from util-linux 2.39"\n' > "$_qm_sgbin/sg"
  chmod +x "$_qm_sgbin/sg"
  ( cd "$r" && VIRTUAL_ENV='' PATH="$_qm_sgbin" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 1 "$rc" "an unrelated system sg is treated as no ast-grep (ruff still blocks the swallow)"
  _qm_has "$log" "ast-grep is not installed, so these rules were NOT evaluated" \
    "the util-linux sg reads as a missing ast-grep, not a TOOL ERROR"
  gg_rmrepo "$r"

  # ---- qa_gate.sh calls the scanner at pre-commit ------------------------------
  r="$(_qm_repo)"
  printf 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\n' \
    > "$r/.qa-gate.conf"
  ( cd "$r" && git add .qa-gate.conf )
  _qm_put "$r" 'vendor\caf"é.py' "$_QM_SWALLOW"
  gg_run_gate_log "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "qa_gate.sh blocks a staged mandate finding in a quoted UTF-8 filename with a quote"
  _qm_has "$log" "quality mandate findings" "the gate's block names the mandate"
  printf 'mandate.enabled=off\n' >> "$r/.qa-gate.conf"
  ( cd "$r" && git add .qa-gate.conf )
  gg_run_gate_log "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "qa_gate.sh with mandate.enabled=off passes"
  gg_rmrepo "$r"

  rm -f "$log"
  return 0
}
