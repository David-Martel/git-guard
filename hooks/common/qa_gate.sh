#!/bin/sh
#
# git-guard QA gate — broad, LANGUAGE-GATED, CONFIGURABLE, BLOCKING-on-real-errors
# quality layer for the account-wide global pre-commit (subsystem A).
#
# Invoked (as a SUBPROCESS) from ~/.git-hooks/pre-commit AFTER nul-cleanup and
# secret-scan, BEFORE the lefthook dispatch tail. Also callable from the
# codex-security hook so LOCAL core.hooksPath-override repos get the same QA.
#
# DESIGN POLICY (the anti-brick rule):
#   A check may BLOCK only if (a) the tool is present, AND (b) the repo is
#   actually configured for it OR the check is near-zero-false-positive, AND
#   (c) it is fast. Otherwise it WARNs. This keeps ~40 naked WIP repos working
#   while still hard-failing real, fast, configured errors. Per-repo config
#   (.qa-gate.conf in repo root, or .git-guard/qa-gate.conf) OVERRIDES the
#   global defaults and is the documented escape hatch (incl. PII repos).
#
# DEBUG: QA_DEBUG=1 git commit ...  -> verbose per-check timing + raw output.
#
# Exit 0 = clean / all-warn. Exit 1 = a BLOCK-level check failed.
#
# Full reference + schema + troubleshooting: ~/.agents/QA_TOOLING.md

set -u

# ----------------------------------------------------------------------------
# Locations
# ----------------------------------------------------------------------------
QA_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
QA_GLOBAL_CONF="$QA_SELF_DIR/qa-gate.conf"
# Ast-grep rules directory — DECOUPLED for severability (git-guard ships
# standalone). Resolution order (first hit wins), finalized after config load:
#   1. $GIT_GUARD_RULES_DIR (env)         — explicit override, highest priority
#   2. conf key `rules_dir` (global/repo) — set by the local installer
#   3. bundled rules-examples/            — the shareable default (public repo)
# On THIS machine the installer writes `rules_dir=<HOME>/.claude/rules` into the
# deployed qa-gate.conf, so the full private corpus overlays the bundled set
# (OVERRIDE, not merge). qa_refresh_rule_cache validates whatever dir is chosen,
# so pointing at the larger private corpus still yields the same clean cache.
# Bundled-default fallback (resolved relative to this script so it survives a
# symlinked deploy: this file is at <git-guard>/hooks/common/, so the bundled
# rules-examples/ is two levels up at the git-guard root; the installer also
# writes an absolute rules_dir, which takes precedence over this).
QA_RULES_BUNDLED="$QA_SELF_DIR/../../rules-examples"
QA_RULES_DIR=""   # finalized below, after the conf files are parsed
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
[ -n "$REPO_ROOT" ] || exit 0   # not in a repo; nothing to do

# Per-repo override search (first hit wins).
QA_REPO_CONF=""
for cand in "$REPO_ROOT/.qa-gate.conf" "$REPO_ROOT/.git-guard/qa-gate.conf"; do
  if [ -f "$cand" ]; then QA_REPO_CONF="$cand"; break; fi
done

QA_FAILED=0        # set to 1 by any block-level failure
QA_DEBUG="${QA_DEBUG:-0}"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
qa_dbg()  { [ "$QA_DEBUG" = "1" ] && printf 'qa-gate[debug] %s\n' "$*" >&2 || true; }
qa_warn() { printf 'qa-gate WARN: %s\n' "$*" >&2; }
qa_info() { [ "$QA_DEBUG" = "1" ] && printf 'qa-gate: %s\n' "$*" >&2 || true; }
qa_block() {
  # $1 = human message. Emits the un-missable failed-commit feedback.
  QA_FAILED=1
  printf '%s\n' "git-guard QA BLOCKED: $1 Your changes are STAGED but UNCOMMITTED — do NOT 'git reset --hard' (it permanently destroys git-add'ed work). Fix the issue, re-stage, re-commit. Verify: git log -1 --pretty='%h %G? %s'" >&2
}

# ----------------------------------------------------------------------------
# Config — parsed ONCE into shell variables (dots->underscores). Avoids spawning
# sed on every lookup (the docs-only hot-path killer on Windows Git-Bash, where
# each subprocess is ~100-250ms). Global file first, repo file second so repo
# values overwrite. Values are sanitized (only the documented vocab survives).
# ----------------------------------------------------------------------------
# Pure-builtin parser: NO per-line subprocess spawns (printf/tr/sed per line was
# the docs-only hot-path killer — ~66 spawns × ~60ms ≈ 4s on Windows Git-Bash).
# Uses only shell parameter expansion + case.
# Whitespace trimming uses IFS word-splitting via `read` itself: by setting
# IFS to space+tab on the read, the key/value land already trimmed of leading
# whitespace; we then strip trailing with parameter expansion. Zero subshells.
qa_load_cfg_file() {
  f="$1"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # leading-whitespace strip (builtin, bounded loop)
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) : ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    v="${v%%#*}"                                   # drop inline comment
    # trailing-whitespace strip on key and value (builtin)
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$k" in '') continue ;; esac
    # dots -> underscores (builtin)
    nk=""
    while case "$k" in *.*) true ;; *) false ;; esac; do nk="${nk}${k%%.*}_"; k="${k#*.}"; done
    k="${nk}${k}"
    # Allow safe value vocab: on/off/warn/block/digits + path chars `/` and `:`
    # so `rules_dir=/abs/path` (POSIX) and `rules_dir=C:/path` (Windows forward-
    # slash) take effect. Backslash, space, quotes, `$`, backtick and `;` stay
    # excluded — the value is placed via eval in a double-quoted context, and
    # those would allow injection. Windows paths must use forward slashes.
    case "$v" in *[!a-zA-Z0-9_,.:/-]*) continue ;; esac
    eval "qacfg_${k}=\"\$v\""
  done < "$f"
}
qa_load_cfg_file "$QA_GLOBAL_CONF"
# Machine-local overlay (gitignored) written by install.sh — keeps the committed
# qa-gate.conf public-safe while this machine sets `rules_dir`, softens checks,
# etc. Loaded AFTER the committed defaults (overrides them), BEFORE the repo conf
# (which still wins). A config FILE, not an env var (inspectable + versionable).
qa_load_cfg_file "${QA_GLOBAL_CONF}.local"
[ -n "$QA_REPO_CONF" ] && qa_load_cfg_file "$QA_REPO_CONF"

qa_cfg() {
  # $1 = dotted key, $2 = default. Pure builtin expansion — zero spawns.
  k="$1"; nk=""
  while case "$k" in *.*) true ;; *) false ;; esac; do nk="${nk}${k%%.*}_"; k="${k#*.}"; done
  k="${nk}${k}"
  eval "v=\"\${qacfg_${k}:-}\""
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

# Finalize the rules dir now that conf is loaded (env > conf `rules_dir` >
# bundled default). Kept allocation-light: a single qa_cfg lookup.
if [ -n "${GIT_GUARD_RULES_DIR:-}" ]; then
  QA_RULES_DIR="$GIT_GUARD_RULES_DIR"
else
  QA_RULES_DIR="$(qa_cfg rules_dir "$QA_RULES_BUNDLED")"
fi
qa_dbg "rules dir resolved to: $QA_RULES_DIR"

# ----------------------------------------------------------------------------
# Staged-file list — captured ONCE at startup; every filter greps the cached
# variable (no repeated `git diff` spawns).
# ----------------------------------------------------------------------------
QA_STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)"
qa_staged_all() { printf '%s' "$QA_STAGED"; }
qa_staged_match() {
  # $1 = ERE. Prints matching staged files from the cached list.
  [ -n "$QA_STAGED" ] || return 0
  printf '%s\n' "$QA_STAGED" | grep -E "$1" 2>/dev/null || true
}
# Files that are staged but ALSO have unstaged edits (re-stage hazard).
qa_partial_files() {
  s="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)"
  u="$(git diff --name-only --diff-filter=ACMR 2>/dev/null)"
  [ -n "$s" ] && [ -n "$u" ] || return 0
  printf '%s\n' "$s" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$u" | grep -qxF -- "$f" && printf '%s\n' "$f"
  done
}
# Snapshot of files that were partially staged BEFORE any auto-fix ran. Captured
# LAZILY on first use (deferred so docs-only / no-autofix commits pay nothing):
# an auto-fix rewrites a file on disk, which then makes that file look
# "unstaged", so we cannot re-derive the partial set afterward. A file is safe
# to auto-restage IFF it was NOT in this original set.
QA_ORIG_PARTIAL=""
QA_ORIG_PARTIAL_DONE=0
qa_was_partial() {
  # $1 = file. 0 (true) if it was partially staged before auto-fix.
  if [ "$QA_ORIG_PARTIAL_DONE" = "0" ]; then
    QA_ORIG_PARTIAL="$(qa_partial_files)"
    QA_ORIG_PARTIAL_DONE=1
  fi
  [ -n "$QA_ORIG_PARTIAL" ] || return 1
  printf '%s\n' "$QA_ORIG_PARTIAL" | grep -qxF -- "$1"
}

# Re-stage a file ONLY if it had no unstaged component BEFORE auto-fix (avoids
# swallowing pre-existing unstaged hunks into the commit). $1 = file.
qa_restage_safe() {
  f="$1"
  if qa_was_partial "$f"; then
    qa_warn "auto-fixed '$f' but it was partially staged — re-stage manually (NOT auto-added to avoid swallowing unstaged edits)."
    return 0
  fi
  git add -- "$f" 2>/dev/null && qa_info "re-staged auto-fixed file: $f"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a Python tool, preferring the REPO'S OWN pinned virtualenv over
# whatever happens to be on PATH. Prints the resolved path, or nothing if the
# tool is unavailable anywhere (so callers can test with [ -n "$x" ]).
#
# Why: a repo that pins its linter is green by its own toolchain but can be
# BLOCKED by a newer ambient one. Measured 2026-08-16 on David-Martel/clarius,
# which pins ruff 0.15.20 in .venv: `ruff check build.py` passes with the repo's
# ruff and reports 12 errors with ~/.local/bin/ruff 0.16.3 — the same file, the
# same repo config, a different binary. Newer ruff releases add rules and change
# defaults, so this blocks commits for lint the project's own CI does not have,
# in every Python repo on the machine whose pin trails the ambient install.
#
# The gate already honors repo *config* (it passes no --select when pyproject
# declares [tool.ruff]); honoring the repo's *binary* is the same principle.
# The repo's pin is authoritative for the repo.
qa_py_tool() {
  _qpt_name="$1"
  # Repo-local virtualenv first (POSIX layout, then the Windows Scripts/ layout).
  for _qpt_cand in \
    "$REPO_ROOT/.venv/bin/$_qpt_name" \
    "$REPO_ROOT/.venv/Scripts/$_qpt_name.exe"
  do
    if [ -x "$_qpt_cand" ]; then printf '%s\n' "$_qpt_cand"; return 0; fi
  done
  # An ACTIVE virtualenv is next best. Guarded on non-empty: unset VIRTUAL_ENV
  # would otherwise build the absolute path "/bin/<tool>" and can match a real
  # system binary, silently reintroducing the ambient-tool bug this fixes.
  if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "$VIRTUAL_ENV/bin/$_qpt_name" ]; then
    printf '%s\n' "$VIRTUAL_ENV/bin/$_qpt_name"
    return 0
  fi
  # Fall back to PATH. `|| true` so `set -u`/`set -e` callers see empty, not a
  # non-zero exit, when the tool is absent everywhere.
  command -v "$_qpt_name" 2>/dev/null || true
}

QA_FIND="find"
if [ -x /usr/bin/find ]; then QA_FIND=/usr/bin/find
elif have gfind; then QA_FIND="$(command -v gfind)"
elif have find; then QA_FIND="$(command -v find)"
fi

# Does $QA_FIND actually support the `-name X -newer Y` predicate combination the
# rule-cache staleness check depends on? uutils find (common on PATH via a ~/bin
# coreutils shim) rejects it with "the argument '--name <PATTERN>' cannot be used
# multiple times". That failure is INVISIBLE at the call site, which discards
# stderr: the query yields no output, "no files newer than the stamp" is
# indistinguishable from "the query never ran", and the cache is then treated as
# fresh FOREVER — silently enforcing stale rules. Probe once, here, so the
# staleness check can fail SAFE (rebuild) instead of fail FRESH (skip).
QA_FIND_OK=0
_qa_ft="$(mktemp -d 2>/dev/null)" || _qa_ft=""
if [ -n "$_qa_ft" ]; then
  : > "$_qa_ft/stamp"
  : > "$_qa_ft/probe.yml"
  # Make probe.yml strictly newer than stamp regardless of filesystem timestamp
  # granularity (FAT/ReFS can share an mtime for files created in the same tick).
  touch -t 202001010000 "$_qa_ft/stamp" 2>/dev/null
  if [ "$("$QA_FIND" "$_qa_ft" -name '*.yml' -newer "$_qa_ft/stamp" -print 2>/dev/null | wc -l)" -eq 1 ]; then
    QA_FIND_OK=1
  fi
  rm -rf "$_qa_ft"
fi

# Resolve a Python interpreter ONCE: prefer `python`, fall back to `python3`.
# Debian/Ubuntu (and the slim Docker base) ship only `python3`, so hardcoding
# `python` would silently no-op the JSON/YAML validation (a default BLOCK check)
# on most Linux clones — a severability gap. Empty when neither is present.
QA_PY=""
if have python; then QA_PY=python
elif have python3; then QA_PY=python3
fi

# ----------------------------------------------------------------------------
# Language detection (reuses the quality-pipeline.sh:detect_project_type logic).
# ----------------------------------------------------------------------------
qa_detect_types() {
  t=""
  if [ -f "$REPO_ROOT/Cargo.toml" ] || ls "$REPO_ROOT"/*/Cargo.toml >/dev/null 2>&1; then t="${t}rust "; fi
  { [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/setup.py" ] || [ -f "$REPO_ROOT/requirements.txt" ]; } && t="${t}python "
  [ -f "$REPO_ROOT/package.json" ] && t="${t}node "
  ls "$REPO_ROOT"/*.sln "$REPO_ROOT"/**/*.csproj >/dev/null 2>&1 && t="${t}csharp "
  printf '%s' "$t"
}

# ----------------------------------------------------------------------------
# ast-grep — ONE batched scan over the validated rule cache, classified by
# ruleId. sg's exit code is 0 even on matches, so we detect via the JSON output.
# ----------------------------------------------------------------------------
QA_SG=""
# NOTE: prefer the `sg` alias ONLY when it is genuinely ast-grep. On Linux,
# /usr/bin/sg is util-linux's set-group command, which shadows ast-grep and
# would make the structural scan silently no-op (trio never fires). Validate
# via `sg --version` before trusting it; otherwise fall back to `ast-grep`.
if have sg && sg --version 2>/dev/null | grep -qi 'ast-grep'; then QA_SG="sg"
elif have ast-grep && ast-grep --version 2>/dev/null | grep -qi 'ast-grep'; then QA_SG="ast-grep"; fi
# The validated rule cache is MACHINE-GLOBAL by default: one directory shared by
# every repo whose commits this account-wide hook gates. That is deliberate (the
# rebuild is expensive, so it should be amortised), but it makes the cache a
# shared mutable resource, and anything that rebuilds it from a DIFFERENT rules
# dir silently changes what the next commit in every other repo checks.
#
# That is not hypothetical. tests/run.sh exports GIT_GUARD_RULES_DIR to the
# bundled rules-examples so the suite is overlay-proof; because the cache was
# unconditionally shared, running the suite repointed the live gate at the
# bundled rules. On 2026-08-15 that delivered a stale destructive autofix
# (use-walrus-operator) into a real commit in another repo, corrupting a source
# file. GIT_GUARD_RULE_CACHE lets a caller that overrides the rules dir also
# isolate the cache, so testing cannot mutate machine state.
QA_RULE_CACHE="${GIT_GUARD_RULE_CACHE:-$QA_SELF_DIR/qa-rules}"
# The EFFECTIVE sgconfig is GENERATED at runtime with ABSOLUTE ruleDirs (see
# qa_write_sgconfig). ast-grep resolves `ruleDirs` relative to the scan CWD (the
# target repo), NOT the sgconfig's own location — so a committed sgconfig with
# relative paths would silently find zero rules. Generating absolute paths from
# the (machine-local) cache dir makes resolution correct AND portable across
# machines/clones. The committed qa-sgconfig.yml is a human REFERENCE only.
QA_SGCONFIG="$QA_RULE_CACHE/sgconfig.generated.yml"
# The narrow BLOCK trio is matched inline in qa_astgrep_run's case statement
# (avoid-static-mut / no-glob-reexport / unsafe-with-panic).
#
# Panic-set classification. Historically this was a single `qa_is_panic_id` that
# forced the WHOLE set to WARN-ONLY *unconditionally* — even for a repo that
# explicitly set `astgrep=block`. The rules fired, carried `severity: error`, and
# could never block anything, so "no unwrap() in production code" was advice, not
# a gate. Keeping the account-wide DEFAULT at warn is right (blocking every
# .unwrap() across dozens of legacy repos would brick commits); making it
# *unreachable* was not. `astgrep_panics` (below) is the opt-in that lets a repo
# which has done the cleanup actually hold the line.
#
# Sets QA_PCLASS rather than echoing, to stay spawn-free like qa_cfg:
#   unconditional — panics EVERY time the line executes if the value isn't the
#                   happy case; there is no input for which it is safe. This is
#                   the class the "no unwrap" policy is actually about.
#   heuristic     — panics only for SOME inputs, and a caller-side check can make
#                   it genuinely unreachable (e.g. an index inside a region whose
#                   length the caller already validated). Real code defends these
#                   correctly often enough that blocking them account-wide would
#                   punish correct work, so they need the stricter opt-in.
#   ""            — not a panic-set rule at all.
# shellcheck disable=SC2221,SC2222
qa_panic_class() {
  case "$1" in
    # NOT a panic rule, despite matching the old `*expect*` glob: this one is
    # about #[allow] vs #[expect] ATTRIBUTES. The fuzzy match silently made it
    # un-blockable even under astgrep=block. Listed first so it wins.
    prefer-expect-over-allow) QA_PCLASS="" ;;
    # NOT a panic rule either. Its pattern is `let $VAR: [$TYPE; $SIZE] = $INIT;`
    # — i.e. EVERY explicitly-typed fixed-size array declaration. Rust checks
    # array length and element type at COMPILE time, so a mismatch is a build
    # error, never a runtime panic; there is no panic condition to gate on. Left
    # in the heuristic tier it made `astgrep_panics=strict` reject ordinary valid
    # declarations like `let bytes: [u8; 4] = [0; 4];` (reproduced with
    # ast-grep 0.27.3). Its own severity is `info`, which is the honest level.
    fixed-size-init) QA_PCLASS="" ;;
    unwrap-call|library-unwrap|avoid-unwrap|as-ref-unwrap|match-arm-unwrap|try-into-unwrap|expect-call|panic-macro|todo-macro|unimplemented-macro|unreachable-macro)
      QA_PCLASS="unconditional" ;;
    unchecked-index|unchecked-division|string-slice-panic|fixed-size-init)
      QA_PCLASS="heuristic" ;;
    # A newly added rule whose id looks panic-ish stays in the set, but lands in
    # the conservative tier: adding a rule file must never silently start
    # blocking commits in every repo that opted into `block`.
    *unwrap*|*panic*|*unreachable*|*unchecked*|*string-slice*|*try-into*|*match-arm*|*todo*|*expect*)
      QA_PCLASS="heuristic" ;;
    *) QA_PCLASS="" ;;
  esac
}

# Generate the EFFECTIVE sgconfig with ABSOLUTE ruleDirs from the cache. Written
# to the (writable) cache dir so a read-only/symlinked git-guard checkout still
# works and resolution is CWD-independent. Only lists dirs that actually exist
# (a curated rules-examples set may omit csharp/powershell). Pure printf — no
# subprocess spawns. rust/ recurses into rust/panics automatically.
qa_write_sgconfig() {
  [ -d "$QA_RULE_CACHE" ] || return 0
  # ast-grep is a NATIVE binary: on Git-Bash/MSYS/Cygwin it cannot read a
  # POSIX `/c/Users/...` path (it mangles it to `C:/c/Users/...`). Convert the
  # base to a native mixed path (`C:/Users/...`) via cygpath where available;
  # on Linux/macOS the POSIX path is already native, so pass it through.
  base="$QA_RULE_CACHE"
  if command -v cygpath >/dev/null 2>&1; then
    base="$(cygpath -m "$QA_RULE_CACHE" 2>/dev/null || printf '%s' "$QA_RULE_CACHE")"
  fi
  printf '# AUTO-GENERATED by qa_gate.sh — do NOT edit (absolute ruleDirs for portable, CWD-independent resolution).\nruleDirs:\n' > "$QA_SGCONFIG" 2>/dev/null || return 0
  for d in core security rust csharp powershell python typescript; do
    [ -d "$QA_RULE_CACHE/$d" ] && printf '  - %s/%s\n' "$base" "$d" >> "$QA_SGCONFIG"
  done
}

# Rebuild the validated rule cache IFF it is missing or older than the source
# rules. Copies only rules that pass `sg scan --rule` validation (a few source
# rules fail the strict multi-rule loader and would poison the batch). This runs
# at most once per source-rule change, not per commit.
qa_refresh_rule_cache() {
  [ -n "$QA_SG" ] || return 0
  src="$QA_RULES_DIR"
  [ -d "$src" ] || return 0
  # Stamp records BOTH the source mtime (the file's own mtime) and the source
  # PATH (its contents). The path half matters: the cache is keyed only by mtime
  # otherwise, so pointing QA_RULES_DIR at a DIFFERENT rules tree whose files are
  # older than the stamp reused the previous tree's cache silently — the gate
  # then scanned with rules the caller never selected. Observed 2026-08-12 on
  # dtm-p1gen7: a cache built from ~/.claude/rules (70 rules) survived a switch
  # to rules-examples (56), so the bundled panic/silent-failure rules never
  # loaded and their gate checks stopped firing. A stamp written by an older
  # git-guard is empty, so it mismatches and forces exactly one rebuild.
  stamp="$QA_RULE_CACHE/.built-from"
  stamp_src=""
  [ -f "$stamp" ] && stamp_src="$(cat "$stamp" 2>/dev/null)"
  # FAIL SAFE, NOT FRESH: only a find we have PROVEN can answer this question is
  # allowed to certify the cache as up to date. If the probe above failed, treat
  # the cache as stale and rebuild — an unnecessary rebuild costs ~30s once,
  # whereas wrongly certifying freshness enforces stale rules indefinitely with
  # no symptom. Same fail-open class as the `grep -e` PEM hole (git-guard#10).
  if [ "$QA_FIND_OK" = "1" ]; then
    newest="$("$QA_FIND" "$src" -name '*.yml' -newer "$stamp" -print 2>/dev/null | head -n1)"
  else
    newest="__find_unusable__"
  fi
  if [ -d "$QA_RULE_CACHE" ] && [ -f "$stamp" ] && [ -z "$newest" ] && [ "$stamp_src" = "$src" ]; then
    [ -f "$QA_SGCONFIG" ] || qa_write_sgconfig   # ensure the generated sgconfig exists
    return 0   # cache fresh
  fi
  # A cold rebuild spawns one `sg scan --rule` per rule file (~70 files, ~30s on
  # Windows). That is silent, so it reads as a HANG and invites a GIT_GUARD=0
  # bypass — which is exactly what it caused on 2026-08-15. Announce it on stderr
  # (not via qa_dbg, which needs QA_DEBUG=1) so the pause is legible as progress.
  printf '%s\n' "git-guard: ast-grep rule cache is stale — revalidating rules (one-time, ~30s)…" >&2
  [ "$QA_FIND_OK" = "1" ] || qa_warn "'$QA_FIND' cannot evaluate '-name X -newer Y'; rebuilding cache unconditionally (safe but slower). Install GNU findutils to restore incremental caching."
  qa_dbg "rebuilding ast-grep rule cache"
  rm -rf "$QA_RULE_CACHE"; mkdir -p "$QA_RULE_CACHE"
  _src_rules=0; _copied=0
  for d in core security rust rust/panics csharp powershell python typescript; do
    mkdir -p "$QA_RULE_CACHE/$d"
    for f in "$src/$d"/*.yml; do
      [ -f "$f" ] || continue
      _src_rules=$((_src_rules + 1))
      tmp="$(mktemp -d)"
      if "$QA_SG" scan --rule "$f" --json=compact "$tmp" >/dev/null 2>&1; then
        cp "$f" "$QA_RULE_CACHE/$d/" 2>/dev/null && _copied=$((_copied + 1))
      fi
      rm -rf "$tmp"
    done
  done
  qa_write_sgconfig
  # Anti-poison guard: only stamp the cache "fresh" if we actually cached rules
  # when the source had some. A transient ast-grep failure (e.g. the wrong `sg`
  # binary shadowing ast-grep) must NOT stamp an EMPTY cache as current — that
  # would silently disable the BLOCK trio until the source rules next change.
  # Leaving the stamp absent forces a rebuild on the next commit.
  if [ "$_src_rules" -gt 0 ] && [ "$_copied" -eq 0 ]; then
    qa_warn "ast-grep rule cache built EMPTY ($_src_rules source rules, 0 validated) — not stamping; will retry next commit."
  else
    # Record the source PATH, not just an mtime — see the staleness check above.
    printf '%s\n' "$src" > "$stamp"
  fi
}

# Extract unique ruleIds from a compact-JSON scan result.
qa_sg_rule_ids() { grep -o '"ruleId":"[^"]*"' 2>/dev/null | sed 's/.*:"//; s/"$//' | sort -u; }

# ----------------------------------------------------------------------------
# CHECK: nul-cleanup (mandatory hygiene; PII-safe)
# ----------------------------------------------------------------------------
qa_check_nul() {
  # The pre-commit hook may run nul-cleanup itself (unconditional hygiene) and
  # set QA_SKIP_NUL=1 to avoid a double-run. Honor that.
  [ "${QA_SKIP_NUL:-0}" = "1" ] && { qa_dbg "nul-cleanup already run by pre-commit"; return 0; }
  mode="$(qa_cfg nul_cleanup block)"
  [ "$mode" = "off" ] && { qa_dbg "nul_cleanup off"; return 0; }
  [ -x "$QA_SELF_DIR/nul-cleanup.sh" ] || { qa_dbg "nul-cleanup.sh absent"; return 0; }
  qa_dbg "running nul-cleanup (mode=$mode)"
  if [ "$mode" = "block" ]; then
    NUKENUL_MANDATORY=1 "$QA_SELF_DIR/nul-cleanup.sh" >/tmp/qa_nul.$$ 2>&1
    rc=$?
    [ "$QA_DEBUG" = "1" ] && cat /tmp/qa_nul.$$ >&2
    rm -f /tmp/qa_nul.$$
    [ "$rc" -ne 0 ] && qa_block "reserved-filename (NUL) cleanup failed."
  else
    NUKENUL_MANDATORY=0 "$QA_SELF_DIR/nul-cleanup.sh" >/dev/null 2>&1 || qa_warn "nul-cleanup reported issues (non-blocking)."
  fi
}

# ----------------------------------------------------------------------------
# CHECK: ast-grep structural rules — ONE batched scan, classified by ruleId.
#   - autofix (OPT-IN, default off): apply fixable rules, safe-restage.
#   - BLOCK trio always blocks (unless astgrep=off).
#   - panic-set ids follow `astgrep_panics` (warn default | block = unconditional
#     panics only | strict = the whole set) — INDEPENDENT of `astgrep`, so a repo
#     can hold a hard no-unwrap line without blocking on every other style rule,
#     or vice versa.
#   - everything else WARN (or block if astgrep=block).
# The rule cache validates each rule, so ruleDirs load cleanly in one process.
# ast-grep's own `files:` globs handle per-language file targeting, so we pass
# ALL staged source files and let the rules self-gate by language/path.
# ----------------------------------------------------------------------------
qa_astgrep_run() {
  master="$(qa_cfg astgrep warn)"
  [ "$master" = "off" ] && { qa_dbg "astgrep off"; return 0; }
  [ -n "$QA_SG" ] || { qa_dbg "ast-grep CLI absent"; return 0; }

  files="$(qa_staged_match '\.(rs|cs|ps1|py|ts|tsx|js|jsx|sh|bash|json)$')"
  [ -n "$files" ] || { qa_dbg "no ast-grep-relevant staged files"; return 0; }
  # Build the validated cache + GENERATE $QA_SGCONFIG (absolute ruleDirs) FIRST —
  # the generated sgconfig is what the scan consumes, so its existence cannot be
  # a precondition checked before this point (chicken-and-egg).
  qa_refresh_rule_cache
  [ -f "$QA_SGCONFIG" ] || { qa_dbg "sgconfig unavailable (no rules dir or cache build failed)"; return 0; }
  set -- $files
  qa_dbg "ast-grep batched scan on: $*"

  # 1. Auto-fix pass (OPT-IN). Default OFF: a fix: like println!->tracing::info!
  #    would silently create a NON-COMPILING commit in repos without `tracing`.
  if [ "$(qa_cfg astgrep_autofix off)" = "on" ]; then
    pre="$($QA_SG scan -c "$QA_SGCONFIG" --json=compact "$@" 2>/dev/null | qa_sg_rule_ids)"
    if [ -n "$pre" ]; then
      # Snapshot the partial set NOW, BEFORE -U rewrites anything (the lazy
      # snapshot would otherwise fire after the rewrite and mis-flag every fixed
      # file as partial).
      QA_ORIG_PARTIAL="$(qa_partial_files)"; QA_ORIG_PARTIAL_DONE=1
      qa_dbg "autofix pass (-U)"
      "$QA_SG" scan -c "$QA_SGCONFIG" -U "$@" >/dev/null 2>&1 || true
      for f in "$@"; do
        # only restage files ast-grep actually changed (now showing unstaged)
        if git diff --name-only -- "$f" 2>/dev/null | grep -qxF -- "$f"; then
          qa_restage_safe "$f"
        fi
      done
    fi
  fi

  # 2. Detection pass: one scan, classify by ruleId.
  ids="$($QA_SG scan -c "$QA_SGCONFIG" --json=compact "$@" 2>/dev/null | qa_sg_rule_ids)"
  [ -n "$ids" ] || return 0
  for rid in $ids; do
    case " $rid " in
      *" avoid-static-mut "*|*" no-glob-reexport "*|*" unsafe-with-panic "*)
        qa_block "ast-grep rule '$rid' (BLOCK trio)." ;;
      *)
        qa_panic_class "$rid"
        if [ -n "$QA_PCLASS" ]; then
          # Default `warn` keeps the account-wide anti-brick promise intact.
          case "$(qa_cfg astgrep_panics warn)" in
            strict)
              qa_block "ast-grep panic-set '$rid' (astgrep_panics=strict)." ;;
            block)
              if [ "$QA_PCLASS" = "unconditional" ]; then
                qa_block "ast-grep panic-set '$rid' — unconditional panic (astgrep_panics=block)."
              else
                qa_warn "ast-grep panic-set '$rid' — input-dependent panic; defend it or set astgrep_panics=strict to block."
              fi ;;
            *)
              qa_warn "ast-grep panic-set '$rid' — consider ?/explicit handling (non-blocking)." ;;
          esac
        elif [ "$master" = "block" ]; then
          qa_block "ast-grep rule '$rid'."
        else
          qa_warn "ast-grep '$rid' — review (non-blocking)."
        fi ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# CHECK: Rust (fmt advisory, clippy off-by-default)
# ----------------------------------------------------------------------------
qa_check_rust() {
  files="$(qa_staged_match '\.rs$')"
  [ -n "$files" ] || return 0
  have cargo || { qa_dbg "cargo absent"; return 0; }

  fmt_mode="$(qa_cfg rust.fmt warn)"
  if [ "$fmt_mode" != "off" ]; then
    # Staged-scope advisory only: never auto `cargo fmt --all` (would reformat
    # unstaged/whole-workspace files -> partial-staging hazard).
    if ! ( cd "$REPO_ROOT" && cargo fmt --all --check >/dev/null 2>&1 ); then
      if [ "$fmt_mode" = "block" ]; then
        qa_block "Rust formatting (run: cargo fmt --all)."
      else
        qa_warn "Rust formatting differs (run: cargo fmt --all) (non-blocking)."
      fi
    fi
  fi

  clippy_mode="$(qa_cfg rust.clippy off)"
  if [ "$clippy_mode" != "off" ]; then
    qa_dbg "running clippy (mode=$clippy_mode) — may be slow"
    if ! ( cd "$REPO_ROOT" && cargo clippy --all-targets -- -D warnings >/dev/null 2>&1 ); then
      if [ "$clippy_mode" = "block" ]; then
        qa_block "Rust clippy warnings (cargo clippy --all-targets -- -D warnings)."
      else
        qa_warn "Rust clippy warnings present (non-blocking)."
      fi
    fi
  fi
}

# ----------------------------------------------------------------------------
# CHECK: Python (ruff check block, ruff format warn, mypy/basedpyright warn)
# ----------------------------------------------------------------------------
qa_check_python() {
  files="$(qa_staged_match '\.py$')"
  [ -n "$files" ] || return 0
  set -- $files

  # Prefer each tool from the repo's own virtualenv over an ambient PATH copy —
  # see qa_py_tool. A repo pinned to an older linter must not be blocked by a
  # newer one it never asked for.
  QA_RUFF="$(qa_py_tool ruff)"
  QA_MYPY="$(qa_py_tool mypy)"
  QA_BASEDPYRIGHT="$(qa_py_tool basedpyright)"

  # ruff check
  rc_mode="$(qa_cfg python.ruff_check block)"
  if [ "$rc_mode" != "off" ] && [ -n "$QA_RUFF" ]; then
    if [ -f "$REPO_ROOT/pyproject.toml" ] && grep -q '\[tool.ruff' "$REPO_ROOT/pyproject.toml" 2>/dev/null; then
      ruff_args=""   # use repo config
    else
      ruff_args="--select E,F --isolated"  # minimal, near-zero-false-positive defaults
    fi
    if ! ( cd "$REPO_ROOT" && "$QA_RUFF" check $ruff_args "$@" >/tmp/qa_ruff.$$ 2>&1 ); then
      [ "$QA_DEBUG" = "1" ] && cat /tmp/qa_ruff.$$ >&2
      if [ "$rc_mode" = "block" ]; then
        qa_block "ruff lint errors (ruff check --fix to auto-fix many)."
        head -20 /tmp/qa_ruff.$$ >&2 2>/dev/null || true
      else
        qa_warn "ruff lint findings (non-blocking)."
      fi
    fi
    rm -f /tmp/qa_ruff.$$
  fi

  # ruff format (WARN if it would change staged files; no auto-restage of partial)
  rf_mode="$(qa_cfg python.ruff_format warn)"
  if [ "$rf_mode" != "off" ] && [ -n "$QA_RUFF" ]; then
    rf_isolated=""
    [ -n "${ruff_args:-}" ] && rf_isolated="--isolated"
    # shellcheck disable=SC2086  # rf_isolated is a single optional flag, intentionally unquoted
    if ! ( cd "$REPO_ROOT" && "$QA_RUFF" format --check $rf_isolated "$@" >/dev/null 2>&1 ); then
      if [ "$rf_mode" = "block" ]; then
        qa_block "ruff format differences (run: ruff format)."
      else
        qa_warn "ruff format would change staged files (run: ruff format) (non-blocking)."
      fi
    fi
  fi

  # mypy (warn by default — strict mypy needs full project context+stubs)
  mp_mode="$(qa_cfg python.mypy warn)"
  if [ "$mp_mode" != "off" ] && [ -n "$QA_MYPY" ]; then
    if ! ( cd "$REPO_ROOT" && "$QA_MYPY" --ignore-missing-imports --no-error-summary "$@" >/dev/null 2>&1 ); then
      if [ "$mp_mode" = "block" ]; then
        qa_block "mypy type errors."
      else
        qa_warn "mypy type findings (non-blocking)."
      fi
    fi
  fi

  # basedpyright (often absent -> skip silently)
  bp_mode="$(qa_cfg python.basedpyright warn)"
  if [ "$bp_mode" != "off" ] && [ -n "$QA_BASEDPYRIGHT" ]; then
    if ! ( cd "$REPO_ROOT" && "$QA_BASEDPYRIGHT" "$@" >/dev/null 2>&1 ); then
      [ "$bp_mode" = "block" ] && qa_block "basedpyright type errors." || qa_warn "basedpyright findings (non-blocking)."
    fi
  fi
}

# ----------------------------------------------------------------------------
# CHECK: Shell (shellcheck — fast, high-signal -> block on WARNING+ by default)
# Block threshold is -S warning: info/style findings are stylistic suggestions
# with high false-positive rate for BLOCKING (anti-brick policy: block only on
# near-zero-FP issues). Run `shellcheck` directly for the full style report.
# ----------------------------------------------------------------------------
qa_check_shell() {
  files="$(qa_staged_match '\.(sh|bash)$')"
  [ -n "$files" ] || return 0
  mode="$(qa_cfg shell.shellcheck block)"
  [ "$mode" = "off" ] && return 0
  have shellcheck || { qa_dbg "shellcheck absent"; return 0; }
  # shellcheck disable=SC2086  # intentional word-splitting of the file list
  set -- $files
  if ! ( cd "$REPO_ROOT" && shellcheck -S warning "$@" >/tmp/qa_sc.$$ 2>&1 ); then
    [ "$QA_DEBUG" = "1" ] && cat /tmp/qa_sc.$$ >&2
    if [ "$mode" = "block" ]; then
      qa_block "shellcheck errors."
      head -20 /tmp/qa_sc.$$ >&2 2>/dev/null || true
    else
      qa_warn "shellcheck findings (non-blocking)."
    fi
  fi
  rm -f /tmp/qa_sc.$$
}

# ----------------------------------------------------------------------------
# CHECK: C# (dotnet format if available -> warn)
# ----------------------------------------------------------------------------
qa_check_csharp() {
  files="$(qa_staged_match '\.cs$')"
  [ -n "$files" ] || return 0
  mode="$(qa_cfg csharp.format warn)"
  [ "$mode" = "off" ] && return 0
  have dotnet || { qa_dbg "dotnet absent"; return 0; }
  if ! ( cd "$REPO_ROOT" && dotnet format --verify-no-changes >/dev/null 2>&1 ); then
    [ "$mode" = "block" ] && qa_block "dotnet format differences." || qa_warn "dotnet format would change files (non-blocking)."
  fi
}

# ----------------------------------------------------------------------------
# CHECK: PowerShell — PSScriptAnalyzer (warn), with a narrow security BLOCK set.
#
# This replaces a comment that claimed PowerShell was "covered by the batched
# ast-grep scan" because "the powershell/ rule dir self-gates to *.ps1 via each
# rule's `language` field". It does not, and it never did:
#
#   - ast-grep has NO PowerShell grammar. Rules declaring `language: powershell`
#     fail to parse and are validated OUT of the rule cache entirely.
#   - The surviving rules use a `language: bash # PowerShell` workaround, which
#     gates them to *bash* files. A .ps1 is not a bash file, so they never match.
#
# Measured 2026-08-15: a .ps1 containing BOTH `Invoke-Expression $payload` and
# `iex $payload` produced ZERO findings from no-invoke-expression.yml — a rule
# carrying `severity: error` and the message "critical security vulnerability
# and is blocked". It blocked nothing, and the comment above asserted otherwise,
# so nothing ever reported the gap. Same class as a check that cannot report
# "I did not run".
#
# PSScriptAnalyzer flags all of it on the same fixture (PSAvoidUsingInvokeExpression
# x2, PSAvoidUsingCmdletAliases for the `iex` alias, PSAvoidUsingWriteHost).
# ~1.7s via pwsh (4.8s via Windows PowerShell 5.1 — prefer pwsh), and only when
# PowerShell files are actually staged.
# ----------------------------------------------------------------------------
qa_check_powershell() {
  files="$(qa_staged_match '\.(ps1|psm1|psd1)$')"
  [ -n "$files" ] || return 0
  mode="$(qa_cfg powershell.psscriptanalyzer warn)"
  [ "$mode" = "off" ] && return 0

  # Prefer pwsh (fast, cross-platform); fall back to Windows PowerShell.
  _ps=""
  if have pwsh; then _ps="pwsh"
  elif have powershell; then _ps="powershell"
  else qa_dbg "no pwsh/powershell -> PSScriptAnalyzer skipped"; return 0; fi

  # Severability: a clone without the module must degrade to a no-op, not a
  # false green. qa_dbg records WHY, so "skipped" is distinguishable from "clean".
  if ! "$_ps" -NoLogo -NoProfile -NonInteractive \
        -c "if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 3 }" >/dev/null 2>&1; then
    qa_dbg "PSScriptAnalyzer module absent -> PowerShell check skipped"
    return 0
  fi

  _out="/tmp/qa_pssa.$$"
  _lst="/tmp/qa_pssa_files.$$"
  # Pass the file list through a FILE, not string interpolation into the -c
  # payload: paths here routinely contain spaces, and a shell loop building a
  # PowerShell array literal inside a double-quoted -c argument has to survive
  # two levels of quoting. One mis-escape silently scans nothing and reports
  # clean — the exact failure mode this whole check exists to remove.
  printf '%s\n' "$files" > "$_lst"
  # pwsh is a NATIVE binary and cannot open a POSIX path — exactly the hazard
  # already documented for ast-grep in qa_write_sgconfig. Passing "/tmp/qa_pssa_files.N"
  # makes Get-Content fail, the scan produce nothing, and the check report CLEAN
  # on a file containing Invoke-Expression. Caught by this check's own positive
  # control before it shipped, which is the entire argument for having one.
  _lst_native="$_lst"
  if command -v cygpath >/dev/null 2>&1; then
    _lst_native="$(cygpath -m "$_lst" 2>/dev/null || printf '%s' "$_lst")"
  fi
  # Run the payload from a FILE via -File, never inline via -c. An inline payload
  # crosses the bash->PowerShell quoting boundary, and PowerShell's own sigils
  # ($_, $paths) do not survive it intact: the -c form silently reported ZERO
  # findings on a .ps1 containing Invoke-Expression, while the byte-identical
  # payload run with -File reported PSAvoidUsingInvokeExpression correctly.
  # A scan that returns nothing is indistinguishable from a clean file, so this
  # would have shipped as another gate that cannot report "I did not run".
  # Same lesson as composing commit messages with a file rather than a heredoc.
  _pl="/tmp/qa_pssa_payload.$$.ps1"
  {
    printf '%s\n' '$ErrorActionPreference = "Stop"'
    printf '$list = Get-Content -LiteralPath "%s" | Where-Object { $_ -ne "" }\n' "$_lst_native"
    printf '%s\n' '$paths = $list | Where-Object { Test-Path -LiteralPath $_ }'
    printf '%s\n' 'if (-not $paths) { exit 0 }'
    printf '%s\n' 'Invoke-ScriptAnalyzer -Path $paths -Severity Error,Warning |'
    printf '%s\n' '  ForEach-Object { "{0}|{1}|{2}|{3}" -f $_.RuleName, $_.Severity, $_.ScriptName, $_.Line }'
  } > "$_pl"
  _pl_native="$_pl"
  if command -v cygpath >/dev/null 2>&1; then
    _pl_native="$(cygpath -m "$_pl" 2>/dev/null || printf '%s' "$_pl")"
  fi
  ( cd "$REPO_ROOT" && "$_ps" -NoLogo -NoProfile -NonInteractive -File "$_pl_native" ) > "$_out" 2>/dev/null
  rm -f "$_lst" "$_pl"
  qa_dbg "PSScriptAnalyzer: $(wc -l < "$_out" 2>/dev/null | tr -d ' ') finding(s) across $(printf '%s\n' "$files" | wc -l | tr -d ' ') staged file(s)"

  # The security subset always blocks (unless the check is off) — mirrors the
  # narrow ast-grep BLOCK trio. These are the RCE / plaintext-credential rules;
  # they are near-zero-false-positive, which is the bar for blocking here.
  _sec="$(grep -E '^(PSAvoidUsingInvokeExpression|PSAvoidUsingPlainTextForPassword|PSAvoidUsingConvertToSecureStringWithPlainText|PSAvoidUsingUserNameAndPasswordParams)\|' "$_out" 2>/dev/null)"
  if [ -n "$_sec" ]; then
    qa_block "PowerShell security findings (PSScriptAnalyzer):"
    printf '%s\n' "$_sec" | head -20 >&2
  elif [ -s "$_out" ]; then
    if [ "$mode" = "block" ]; then
      qa_block "PSScriptAnalyzer findings."
      head -20 "$_out" >&2 2>/dev/null || true
    else
      qa_warn "PSScriptAnalyzer findings (non-blocking): $(wc -l < "$_out" | tr -d ' ') in $(printf '%s\n' "$files" | wc -l | tr -d ' ') file(s)."
      [ "$QA_DEBUG" = "1" ] && head -20 "$_out" >&2
    fi
  fi
  rm -f "$_out"
}

# ----------------------------------------------------------------------------
# CHECK: structured-data validation (json block, yaml warn) — cheap, real.
# Uses python only if present; never forces uv install.
# ----------------------------------------------------------------------------
qa_check_validate() {
  [ -n "$QA_PY" ] || { qa_dbg "no python interpreter -> structured-data validation skipped"; return 0; }
  jmode="$(qa_cfg validate.json block)"
  if [ "$jmode" != "off" ]; then
    jf="$(qa_staged_match '\.json$')"
    if [ -n "$jf" ]; then
      for f in $jf; do
        [ -f "$REPO_ROOT/$f" ] || continue
        if ! "$QA_PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$REPO_ROOT/$f" >/dev/null 2>&1; then
          [ "$jmode" = "block" ] && qa_block "invalid JSON: $f." || qa_warn "invalid JSON: $f (non-blocking)."
        fi
      done
    fi
  fi
  ymode="$(qa_cfg validate.yaml warn)"
  if [ "$ymode" != "off" ]; then
    yf="$(qa_staged_match '\.(yml|yaml)$')"
    if [ -n "$yf" ] && "$QA_PY" -c "import yaml" >/dev/null 2>&1; then
      for f in $yf; do
        [ -f "$REPO_ROOT/$f" ] || continue
        if ! "$QA_PY" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$REPO_ROOT/$f" >/dev/null 2>&1; then
          [ "$ymode" = "block" ] && qa_block "invalid YAML: $f." || qa_warn "invalid YAML: $f (non-blocking)."
        fi
      done
    fi
  fi
}

# ----------------------------------------------------------------------------
# CHECK: large file guard (warn)
# ----------------------------------------------------------------------------
qa_check_largefile() {
  mode="$(qa_cfg largefile warn)"
  [ "$mode" = "off" ] && return 0
  kb="$(qa_cfg largefile_kb 5120)"
  case "$kb" in ''|*[!0-9]*) kb=5120 ;; esac
  max=$((kb * 1024))
  qa_staged_all | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$REPO_ROOT/$f" ] || continue
    sz=$(wc -c < "$REPO_ROOT/$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$max" ]; then
      # Note: warn-mode cannot set QA_FAILED from a subshell pipe; block-mode
      # for large files is intentionally NOT offered (LFS repos vary widely).
      printf 'qa-gate WARN: large staged file %s (%s bytes > %s KB) — consider Git LFS. (non-blocking)\n' "$f" "$sz" "$kb" >&2
    fi
  done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
qa_main() {
  [ "$(qa_cfg qa.enabled on)" = "on" ] || { qa_dbg "qa.enabled=off -> skip"; exit 0; }
  # Fast no-op when nothing is staged.
  [ -n "$(qa_staged_all)" ] || { qa_dbg "no staged files"; exit 0; }

  if [ "$QA_DEBUG" = "1" ]; then
    printf 'qa-gate[debug] repo=%s types="%s" repo_conf=%s\n' "$REPO_ROOT" "$(qa_detect_types)" "${QA_REPO_CONF:-<none>}" >&2
  fi

  start_total=$(date +%s 2>/dev/null || echo 0)

  # nul-cleanup first (filesystem hygiene, language-agnostic).
  qa_check_nul

  # Language-gated checks — each is a TRUE no-op if no matching staged files.
  qa_check_shell
  qa_check_python
  qa_check_rust
  qa_check_csharp
  qa_check_powershell

  # ast-grep: ONE batched scan over core/security/rust/csharp/powershell rules.
  # Rules self-gate by language via their `language:`/`files:` fields. Trio
  # blocks, panic-set warns, rest warn (or block if astgrep=block).
  qa_astgrep_run

  # Structured-data + size.
  qa_check_validate
  qa_check_largefile

  if [ "$QA_DEBUG" = "1" ]; then
    end_total=$(date +%s 2>/dev/null || echo 0)
    printf 'qa-gate[debug] total %ss, result=%s\n' "$((end_total - start_total))" "$([ "$QA_FAILED" = 0 ] && echo PASS || echo BLOCK)" >&2
  fi

  [ "$QA_FAILED" = "0" ] && exit 0 || exit 1
}

qa_main
