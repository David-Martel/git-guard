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
  gg_find "$GG_BUNDLED" -name '*.yml' | sort | while IFS= read -r f; do
    printf 'x' >> "$scratch/.total"
    if ! "$sg_bin" scan --rule "$f" --json=compact "$scratch" >/dev/null 2>&1; then
      t_fail "INVALID rule (failed to parse): $f"
      printf 'x' >> "$scratch/.bad"
    fi
  done
  total=$(wc -c < "$scratch/.total" 2>/dev/null | tr -d ' ')
  bad=$(wc -c < "$scratch/.bad" 2>/dev/null | tr -d ' ')
  rm -rf "$scratch"
  if [ "$total" -eq 0 ]; then
    t_fail "rule integrity found zero bundled example rules"
  elif [ "$bad" -eq 0 ]; then
    t_ok "all $total bundled example rules parse cleanly"
  else
    t_fail "$bad of $total bundled rules failed to parse"
  fi

  # --- no autofix may DROP a metavariable its own rule captures ---------------
  # Parsing is not enough: a rule can parse, load, fire, AND still destroy code.
  # use-walrus-operator.yml paired `if $COND: $VAR = $EXPR` with
  # `if ($VAR := $EXPR):`, discarding $COND so the assignment became the
  # condition. Removed from the private corpus 2026-08-04 -- but this bundled
  # copy was missed, and because the validated rule cache is machine-global,
  # running THIS SUITE repointed the live gate at these rules and delivered the
  # stale fix into a real commit on 2026-08-15, corrupting a source file.
  #
  # Metavars under `not:` are excluded: they constrain where a rule matches and
  # never bind a subtree the fix could re-emit (counting them false-positives on
  # prefer-const and no-useless-async, which are correct). A fix referencing NO
  # metavar is a deletion, which legitimately discards its captures.
  if ! gg_has_pyyaml; then
    t_skip "dropped-metavar audit: PyYAML absent (NOT verified)"
    return 0
  fi
  drop_out="$("$(gg_python)" - "$GG_BUNDLED" <<'PYEOF' 2>&1
import re, sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
MV = re.compile(r"\$\$\$[A-Z_][A-Z0-9_]*|\$[A-Z_][A-Z0-9_]*")
def mv(node, skip_fix=True):
    out = set()
    if isinstance(node, str):
        out.update(m.lstrip("$") for m in MV.findall(node))
    elif isinstance(node, dict):
        for k, v in node.items():
            if (skip_fix and k == "fix") or k == "not":
                continue
            out |= mv(v, skip_fix)
    elif isinstance(node, list):
        for i in node:
            out |= mv(i, skip_fix)
    return out
for p in sorted(root.rglob("*.yml")):
    try:
        doc = yaml.safe_load(p.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    fix = doc.get("fix")
    if not isinstance(fix, str):
        continue
    cap = mv(doc.get("rule", {})) | mv(doc.get("constraints", {}))
    emi = mv(fix, skip_fix=False)
    dropped = sorted(cap - emi)
    if dropped and emi:
        print(f"{p.relative_to(root).as_posix()}: drops {','.join(dropped)}")
PYEOF
)"
  if [ -n "$drop_out" ]; then
    t_fail "bundled rule(s) have a fix: that drops a captured metavariable:"
    printf '%s\n' "$drop_out" | sed 's/^/           /' >&2
  else
    t_ok "no bundled autofix drops a metavariable it captures"
  fi
}
