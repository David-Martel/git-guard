#!/bin/sh
# Category 12 — PowerShell is checked by something that actually fires.
#
# Background. qa_gate carried a comment asserting PowerShell was "covered by the
# batched ast-grep scan" because "the powershell/ rule dir self-gates to *.ps1
# via each rule's `language` field". Both halves were false:
#
#   - ast-grep has no PowerShell grammar, so `language: powershell` rules fail to
#     parse and are validated OUT of the rule cache.
#   - The `language: bash # PowerShell` workaround gates a rule to BASH files, so
#     a .ps1 never matches it.
#
# Measured 2026-08-15: a .ps1 containing BOTH `Invoke-Expression $payload` and
# `iex $payload` produced ZERO findings from no-invoke-expression.yml — a rule
# with `severity: error` whose message reads "critical security vulnerability and
# is blocked". It blocked nothing, and the comment claimed coverage, so nothing
# ever surfaced the gap.
#
# These cases pin the replacement. The load-bearing one is the POSITIVE control:
# a check that cannot be shown to fire is indistinguishable from the inert rule
# it replaced.

_ps_bin() {
  if have pwsh; then printf 'pwsh'
  elif have powershell; then printf 'powershell'
  else printf ''; fi
}

# _ps_probe FILENAME CONTENT — stage CONTENT as FILENAME in a throwaway repo,
# run qa_gate, return its exit code (1 = blocked).
_ps_probe() {
  _r="$(gg_mktemp_repo)" || return 99
  printf '%s\n' "$2" > "$_r/$1"
  # Keep unrelated gates out of the verdict.
  printf 'astgrep=off\nvalidate.json=off\nvalidate.yaml=off\n' > "$_r/.qa-gate.conf"
  ( cd "$_r" && git add -A >/dev/null 2>&1 )
  ( cd "$_r" && sh "$GG_ROOT/hooks/common/qa_gate.sh" >/dev/null 2>&1 )
  _rc=$?
  gg_rmrepo "$_r"
  return $_rc
}

t_case_powershell() {
  t_begin "12 PowerShell security findings actually block"

  _psbin="$(_ps_bin)"
  if [ -z "$_psbin" ]; then
    t_skip "powershell: no pwsh/powershell on PATH"
    return 0
  fi
  if ! "$_psbin" -NoLogo -NoProfile -NonInteractive \
       -c "if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 3 }" >/dev/null 2>&1; then
    t_skip "powershell: PSScriptAnalyzer module not installed"
    return 0
  fi

  # ---- the regression this replaces: prove ast-grep CANNOT see it -----------
  # Not a hypothetical. If a future ast-grep gains a PowerShell grammar and this
  # starts finding something, that is worth knowing — hence an explicit case
  # rather than a silent assumption baked into the design.
  _rules="$GG_ROOT/rules-examples/powershell/no-invoke-expression.yml"
  if [ -f "$_rules" ] && have sg; then
    _t="$(mktemp -d)"
    printf 'Invoke-Expression $payload\niex $payload\n' > "$_t/danger.ps1"
    _n="$(sg scan --rule "$_rules" --json=compact "$_t/danger.ps1" 2>/dev/null | grep -o '"ruleId"' | wc -l | tr -d ' ')"
    rm -rf "$_t"
    if [ "$_n" = "0" ]; then
      t_ok "context: ast-grep finds 0 in a .ps1 with IEX (why PSScriptAnalyzer is needed)"
    else
      t_ok "context: ast-grep now reports $_n on .ps1 — grammar may exist; revisit the note in qa-gate.conf"
    fi
  fi

  # ---- POSITIVE control: the security subset must BLOCK ---------------------
  _ps_probe "danger.ps1" '$p = "whoami"
Invoke-Expression $p'
  _got=$?
  if [ "$_got" = "1" ]; then
    t_ok "blocks: Invoke-Expression in a staged .ps1"
  else
    t_fail "blocks: Invoke-Expression NOT blocked (rc=$_got) — the check is inert, same as the rule it replaced"
  fi

  # ---- NEGATIVE control: clean PowerShell must PASS -------------------------
  # Without this, a check hardwired to block would pass the positive control
  # while making every PowerShell commit impossible.
  _ps_probe "clean.ps1" '[CmdletBinding()]
param([Parameter(Mandatory)][string]$Name)
Write-Output "hello $Name"'
  _got=$?
  if [ "$_got" = "0" ]; then
    t_ok "allows: clean PowerShell passes"
  else
    t_fail "allows: clean PowerShell was blocked (rc=$_got) — false positive"
  fi

  # ---- a non-security finding must WARN, not block --------------------------
  # Write-Host is the canonical style-only finding. Blocking on it would violate
  # the anti-brick policy (only fast, near-zero-FP checks may block).
  _ps_probe "noisy.ps1" 'Write-Host "status"'
  _got=$?
  if [ "$_got" = "0" ]; then
    t_ok "warns: Write-Host is non-blocking (anti-brick policy respected)"
  else
    t_fail "warns: Write-Host BLOCKED (rc=$_got) — style findings must not block"
  fi

  # ---- severability: no false green when the module is missing --------------
  # The check must be able to say "I did not run". qa_dbg records the reason;
  # assert the skip path exists rather than silently treating absence as clean.
  if grep -q 'PSScriptAnalyzer module absent' "$GG_ROOT/hooks/common/qa_gate.sh" 2>/dev/null; then
    t_ok "severability: module-absent path is recorded, not silently green"
  else
    t_fail "severability: no explicit module-absent path in qa_gate.sh"
  fi

  return 0
}
