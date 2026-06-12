#!/bin/sh
# Category 7 — rule integrity: every rules-examples/*.yml is a PARSE-VALID
# ast-grep rule (`ast-grep scan --rule <f>`). A rule that fails the strict
# loader would be silently dropped from the validated cache, disabling it; this
# catches that at test time. Sourced by run.sh.
# shellcheck shell=sh

t_case_rule_integrity() {
  t_begin "07 rule integrity (every rules-examples/*.yml parses)"
  if ! gg_has_astgrep; then
    t_skip "rule integrity: ast-grep CLI absent (cannot parse-check rules)"; return 0
  fi
  sg_bin="ast-grep"; have ast-grep || sg_bin="sg"
  scratch="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg.rules.XXXXXX")"
  : > "$scratch/probe.txt"
  bad=0; total=0
  # Iterate via `find … | while read` (no SC2044 word-splitting of $(find)).
  # The loop runs in a subshell, so accumulate counts into files and read back.
  : > "$scratch/.total"; : > "$scratch/.bad"
  find "$GG_BUNDLED" -name '*.yml' | sort | while IFS= read -r f; do
    printf 'x' >> "$scratch/.total"
    if ! "$sg_bin" scan --rule "$f" --json=compact "$scratch" >/dev/null 2>&1; then
      t_fail "INVALID rule (failed to parse): $f"
      printf 'x' >> "$scratch/.bad"
    fi
  done
  total=$(wc -c < "$scratch/.total" 2>/dev/null | tr -d ' ')
  bad=$(wc -c < "$scratch/.bad" 2>/dev/null | tr -d ' ')
  rm -rf "$scratch"
  if [ "$bad" -eq 0 ]; then
    t_ok "all $total bundled example rules parse cleanly"
  else
    t_fail "$bad of $total bundled rules failed to parse"
  fi
}
