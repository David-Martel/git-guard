# QA_TOOLING.md — Account-wide git QA subsystem (canonical reference)

> The single source of truth for the **git-guard QA layer (subsystem A)**: the
> broad, language-gated, configurable, blocking-on-real-errors quality gate
> composed into the GLOBAL `~/.git-hooks` chain. If a check fires unexpectedly,
> if a commit is blocked, or if you need to add/extend a rule — start here.
>
> Companion docs: [`~/.agents/GIT_COMMIT_SAFETY.md`](GIT_COMMIT_SAFETY.md)
> (commit-safety doctrine / IRON RULES) and
> [`~/.agents/VIGIL_PARTITION_PLAN.md`](VIGIL_PARTITION_PLAN.md) (the staged
> follow-on plan). Last updated: 2026-06-06.

---

## 1. Architecture — how a commit flows through the hooks

There are THREE entry paths to git hooks on this machine:

```
                                  git commit
                                      │
        ┌─────────────────────────────┼──────────────────────────────┐
        │                             │                              │
  GLOBAL chain                 LOCAL core.hooksPath           repo lefthook /
  (core.hooksPath =            override (.githooks)           .githooks (naked
   ~/.git-hooks)               intublade/jetson/pixel          repos hit GLOBAL)
        │                             │
        ▼                             ▼
  ~/.git-hooks/pre-commit     <repo>/.githooks/pre-commit
   (lefthook stub +            └─ calls ──► ~/.config/codex-security/
    git-guard sentinel)                     git-hooks/pre-commit
        │                                        │
        ├─ git-guard sentinel block:             ├─ secret_scan.sh (BLOCK)
        │   1. secret_scan.sh        (BLOCK)     └─ qa_gate.sh      (BLOCK/WARN)
        │   2. nul-cleanup.sh        (BLOCK)
        │   3. qa_gate.sh            (BLOCK/WARN)  ← THIS subsystem
        │   4. protected-branch WARN
        │   5. partial-staging WARN
        │
        └─ call_lefthook run "pre-commit"  (unchanged tail; dispatches to a
                                            repo's lefthook.yml / .githooks)
```

- **Naked repos** (~40, incl. SENSITIVE `finance-warehouse` / `fin-aid-applications`)
  have no local hook → they hit the GLOBAL `~/.git-hooks/pre-commit`. Before this
  subsystem they got ONLY nul-cleanup; now they also get secret-scan + the QA gate.
- **Local-override repos** (`core.hooksPath=.githooks`: intublade/jetson/pixel)
  bypass the global chain; their `.githooks/pre-commit` calls
  `~/.config/codex-security/git-hooks/pre-commit`, which now runs secret-scan + QA.
- **The `post-*` hooks** (`post-commit`/`post-checkout`/`post-merge`) are the
  FULL dispatcher (LFS / run-repo-hook / ps-module-sync). `post-commit` also has
  a git-guard sentinel that prints the landed SHA. Only `pre-commit`/`pre-push`
  are lefthook stubs — do NOT double-run dispatch.

### Bypass / escape hatches (documented, not accidental)
- `LEFTHOOK=0 git commit …` — short-circuits the stub BEFORE the git-guard block
  (so it skips secret-scan AND QA). Conscious bypass.
- `git commit --no-verify` — skips all client hooks. Discouraged (see GIT_COMMIT_SAFETY).
- Per-repo `.qa-gate.conf` — the granular, in-band escape hatch (see §5).

---

## 2. The checks (what runs, what gates it, block vs warn)

**Governing policy (the anti-brick rule):** a check may **BLOCK** only if (a) the
tool is present, AND (b) the repo is configured for it OR the check is
near-zero-false-positive, AND (c) it is fast. Otherwise it **WARNs**. This keeps
~40 naked WIP repos committing while still hard-failing real, fast, configured
errors. The default blocking surface is deliberately NARROW.

| Check | Trigger (staged files) | Tool | Default | Notes |
|---|---|---|---|---|
| secret-scan | added lines (any file) | `secret_scan.sh` | **BLOCK** | MVC; added-lines-only |
| nul-cleanup | always | NukeNul.exe / shell | **BLOCK** | reserved-filename hygiene, PII-safe |
| ast-grep trio | `*.rs` | `sg` (batched) | **BLOCK** | avoid-static-mut, no-glob-reexport, unsafe-with-panic |
| ast-grep panic-set | `*.rs` | `sg` | **WARN** | unwrap/panic/unchecked… never blocks |
| ast-grep other | source files | `sg` | **WARN** | core/security/csharp/powershell rules |
| ruff check | `*.py` | `ruff` | **BLOCK** | repo config if present, else `--select E,F --isolated` |
| ruff format | `*.py` | `ruff` | **WARN** | warns if it would reformat staged files |
| mypy | `*.py` | `mypy` | **WARN** | strict mypy needs full project context |
| basedpyright | `*.py` | `basedpyright` | **WARN** | usually absent → skipped |
| shellcheck | `*.sh`/`*.bash` | `shellcheck` | **BLOCK** | fast, high-signal |
| cargo fmt | `*.rs` | `cargo` | **WARN** | advisory; never auto-`--all`-restage |
| cargo clippy | `*.rs` | `cargo` | **off** | slow + WIP repos don't build clean → off by default |
| dotnet format | `*.cs` | `dotnet` | **WARN** | if available |
| json validate | `*.json` | python | **BLOCK** | parse only |
| yaml validate | `*.yml`/`*.yaml` | python+pyyaml | **WARN** | parser may be absent |
| largefile | always | builtin | **WARN** | > `largefile_kb` (default 5120) → suggest LFS |

**Language gating:** checks are gated by STAGED FILE EXTENSION, not just repo
type. A docs-only commit is a TRUE no-op (no language tool runs). Python tools
never run on a rust-only diff and vice-versa.

A blocked commit prints the un-missable message (IRON RULE 1):
`git-guard QA BLOCKED: <reason>. Your changes are STAGED but UNCOMMITTED — do NOT
'git reset --hard' … Verify: git log -1 --pretty='%h %G? %s'`

---

## 3. Tool inventory + where each config lives

Every tool is resolved via `PATH` (`command -v`) and **self-skips when absent** —
no tool is required. The table shows where each reads its config.

| Tool | Resolution | Its config |
|---|---|---|
| sg / ast-grep | `PATH` | generated `qa-rules/sgconfig.generated.yml` → validated rule cache |
| ruff | `PATH` | repo `pyproject.toml [tool.ruff]`, else `--select E,F --isolated` |
| mypy | `PATH` | `--ignore-missing-imports` (lenient) |
| shellcheck | `PATH` | none |
| cargo | `PATH` | repo `rustfmt.toml` / `Cargo.toml` |
| dotnet | `PATH` | repo `.editorconfig` |
| NukeNul (optional NUL accelerator) | `$NUKENUL_BIN` (else POSIX-shell fallback) | n/a |

Files OWNED by this subsystem (all under `~/.git-hooks/common/` unless noted):

| File | Role |
|---|---|
| `qa_gate.sh` | the QA engine (language gating, config, ast-grep, checks) |
| `qa-gate.conf` | GLOBAL DEFAULT config (block/warn/off per check) |
| `qa-sgconfig.yml` | ast-grep root config → points at the validated rule cache |
| `qa-rules/` | VALIDATED rule cache (auto-rebuilt; see §4) |
| `nul-cleanup.sh` | pre-existing reserved-filename cleanup (reused, not modified) |
| `~/.git-hooks/pre-commit` | git-guard sentinel block invokes the above |
| `~/.config/codex-security/git-hooks/pre-commit` | override-repo entry → secret-scan + QA |

---

## 4. The ast-grep rule cache (why it exists, how to refresh)

Source rules live at `~/.claude/rules/{core,security,rust,rust/panics,csharp,powershell}/`
(~56 files). ast-grep's multi-rule loader (`sg scan -c sgconfig.yml`) is ~20×
faster than one `sg scan --rule` per file (≈200ms vs ≈4.4s for 46 rules), BUT a
few source rules fail its strict parse and would poison the WHOLE batch:

- `rust/todo-expect-message.yml`
- `rust/panics/test-expect-todo.yml`
- `powershell/avoid-write-host.yml`
- `powershell/prefer-strict-mode.yml`

So `qa_gate.sh` maintains a **validated cache** at `~/.git-hooks/common/qa-rules/`:
each source rule is checked with `sg scan --rule <f>` and only copied if it
parses. The cache (currently **52** rules: core 11, security 3, rust 15,
rust/panics 15, csharp 6, powershell 2) is rebuilt automatically whenever a
source `.yml` is newer than the cache stamp `qa-rules/.built-from` (a `find
-newer` check, near-free when warm). First build (or after editing rules) costs
~15s once; steady-state commits pay nothing for it.

### Classification (which rule blocks)
- **BLOCK trio** (by ruleId): `avoid-static-mut`, `no-glob-reexport`,
  `unsafe-with-panic`. Precedent: `~/.claude/hooks/rust-pre-commit.sh:44-46`.
- **Panic-set → governed by `astgrep_panics`, independent of `astgrep`.**
  Blocking every `.unwrap()` across 40 repos by default would be a disaster, so
  the default stays `warn`. But it used to be *unconditionally* warn-only — a
  repo that had done the cleanup and set `astgrep=block` still could not make
  "no `unwrap()` in production code" hold, because the classifier ignored config
  entirely. The rules fired, carried `severity: error`, and gated nothing.
  `astgrep_panics` is the opt-in that closes that gap:

  | value | effect |
  |---|---|
  | `warn` *(default)* | whole panic set warns — unchanged account-wide behaviour |
  | `block` | **unconditional** panics block; **heuristic** ones still warn |
  | `strict` | the whole panic set blocks |

  - **unconditional** — panics every time the line executes off the happy path;
    no input makes it safe: `unwrap-call`, `library-unwrap`, `avoid-unwrap`,
    `as-ref-unwrap`, `match-arm-unwrap`, `try-into-unwrap`, `expect-call`,
    `panic-macro`, `todo-macro`, `unimplemented-macro`, `unreachable-macro`.
  - **heuristic** — panics only for *some* inputs, and a caller-side check can
    make it genuinely unreachable (an index inside a region whose length the
    caller already validated is a real defence, not a latent crash):
    `unchecked-index`, `unchecked-division`, `string-slice-panic`,
    `fixed-size-init`. These need `strict`.
  - `astgrep=off` still overrides every tier — the escape hatch is absolute.
  - Note `prefer-expect-over-allow` is **not** a panic rule (it is about
    `#[allow]` vs `#[expect]` attributes). The old fuzzy `*expect*` glob swept it
    into the deny-set and made it permanently un-blockable; classification is now
    by exact ruleId, with the fuzzy globs kept only as a conservative fallback so
    a newly added rule lands in `heuristic` rather than silently blocking.
- **Everything else → WARN** (or BLOCK only if a repo sets `astgrep=block`).

Adopting `block`/`strict` on an existing crate is a cleanup project, not a flag
day — measure first (`sg scan` the panic set, count findings), fix or defend each
site, then flip the key so it cannot regress.

### How to ADD / UPDATE an ast-grep rule
1. Drop/edit the `.yml` in the appropriate `~/.claude/rules/<lang>/` dir (the
   source of truth; the cache is derived). Validate it standalone:
   `sg scan --rule ~/.claude/rules/<lang>/<id>.yml --json=compact <somefile>`
2. The next commit auto-rebuilds the cache (source is newer). To force now:
   `rm -rf ~/.git-hooks/common/qa-rules` (rebuilds on next commit).
3. To make a NEW rule BLOCK: add its ruleId to the trio `case` in
   `qa_gate.sh:qa_astgrep_run` (search for `avoid-static-mut`). Keep the block
   set narrow + near-zero-false-positive.
4. To scan a NEW language dir: add it to `ruleDirs` in `qa-sgconfig.yml` AND to
   the `for d in …` list in `qa_refresh_rule_cache`.

---

## 5. Per-repo override — schema + precedence

**Precedence (highest wins):** repo `.qa-gate.conf` (or `.git-guard/qa-gate.conf`)
→ global `~/.git-hooks/common/qa-gate.conf` → built-in defaults.

**Format:** flat `key = value`, one per line, `#` comments, no sections, no
quotes. Parsed by a **pure-builtin** reader in `qa_gate.sh` (zero subprocess
spawns — this is why docs-only commits are ~200ms, not 4.8s). Dotted keys map
internally (`python.ruff_check` → `qacfg_python_ruff_check`).

**Per-check values:** `block` (refuse commit) | `warn` (print, proceed) | `off`
(skip). A repo can only set keys that exist in the global default.

**Keys** (defaults shown):
```
qa.enabled=on             # master kill-switch for the whole QA layer
nul_cleanup=block
astgrep=warn              # warn|block|off (trio blocks unless off)
astgrep_panics=warn       # warn|block|strict — panic set (unwrap/expect/panic!/index…).
                          #   block  = unconditional panics only; strict = whole set.
                          #   Independent of `astgrep`; `astgrep=off` overrides both.
astgrep_autofix=off       # OPT-IN: apply fix: rules + restage (see WARNING below)
rust.fmt=warn   rust.clippy=off
python.ruff_check=block   python.ruff_format=warn   python.mypy=warn   python.basedpyright=warn
shell.shellcheck=block
csharp.format=warn
powershell.astgrep=warn
validate.json=block   validate.yaml=warn
largefile=warn   largefile_kb=5120
```

**Examples** (place at repo root as `.qa-gate.conf`):
```ini
# Opt the whole repo out (escape hatch for an unusual repo):
qa.enabled=off
```
```ini
# SENSITIVE PII repos (finance-warehouse / fin-aid-applications) — lighter
# profile: keep secret-scan+nul (those run regardless / in the pre-commit), but
# soften QA noise. They are naked repos, so this file is how they tune it.
python.mypy=off
python.ruff_format=off
astgrep=warn
largefile=off
```
```ini
# A repo that DOES build clean and wants the strict gate:
rust.clippy=block
astgrep=block
python.mypy=block
```
```ini
# A repo where the println!->tracing!::info auto-fix is known-safe:
astgrep_autofix=on
```

> **WARNING — `astgrep_autofix`:** default OFF on purpose. A `fix:` such as
> `avoid-println` rewrites `println!(…)` → `tracing::info!(…)` and re-stages it.
> In a repo that does NOT depend on `tracing`, that silently produces a
> NON-COMPILING commit. Only enable per-repo where the fixes are known-safe.
> When on, auto-fixed files are re-staged ONLY if they were fully staged before
> the fix (partially-staged files are warned, never auto-added — so an unstaged
> hunk is never swallowed into the commit).

---

## 6. DEBUG mode

`QA_DEBUG=1 git commit …` (or run `QA_DEBUG=1 ~/.git-hooks/common/qa_gate.sh`
with files staged) prints, to stderr:
- repo root, detected types, which `.qa-gate.conf` (if any) is in effect
- each check as it runs (`qa-gate[debug] running …`)
- full tool output for the failing/warning check (ruff/shellcheck/ast-grep)
- total elapsed seconds + PASS/BLOCK

Use it to identify exactly which check fired and why. Example:
```bash
QA_DEBUG=1 ~/.git-hooks/common/qa_gate.sh   # with files staged
```

---

## 7. How to fix / extend the tooling

- **A check is too aggressive across repos:** lower its global default in
  `qa-gate.conf` to `warn`/`off`. Keep the block set narrow.
- **Add a new language/tool:** add a `qa_check_<lang>()` in `qa_gate.sh`
  (model it on `qa_check_shell`: gate by `qa_staged_match`, read mode via
  `qa_cfg`, honor block/warn/off, `have <tool>` guard), call it from `qa_main`,
  add its key(s) to `qa-gate.conf`.
- **Add an ast-grep rule:** see §4.
- **Performance:** the hot path must avoid per-line/per-call subprocess spawns
  (each is ~60-200ms on Windows Git-Bash). Use builtins (`case`, parameter
  expansion); cache git/config reads once (`QA_STAGED`, `qacfg_*`). Measure with
  `bash -x … 2>trace` then count external commands.
- **Validate after any edit:** `sh -n qa_gate.sh` (POSIX syntax), then re-run the
  matrix in §9.

---

## 8. Known gaps

1. **Local-hooksPath-override repos** only get QA if their `.githooks/pre-commit`
   calls the codex-security hook (intublade does; jetson/pixel use a separate
   pwsh secret scanner and would need a one-line add to gain the full QA).
2. **`--no-verify` / `LEFTHOOK=0`** bypass all client-side hooks. Client hooks
   are advisory by nature — server-side rulesets are the real enforcement.
3. **Server-side rulesets ARE available** (verified: `gh api
   repos/David-Martel/intublade/rules/branches/main` returns active
   `required_signatures`/`non_fast_forward`/`pull_request` rules). The earlier
   "plan-blocked 403" claim was overstated. Use rulesets for true enforcement.
4. **basedpyright** is not installed on this host → its check no-ops.
5. **First commit after editing `~/.claude/rules`** pays a ~15s one-time cache
   rebuild.
6. **NukeNul** targets genuine Windows reserved device-names; a normal file
   literally named `nul.txt` on Git-Bash's POSIX FS is left alone (it is not a
   reserved device there).

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Commit blocked, "QA BLOCKED: ruff" | real lint error in staged `.py` | `ruff check --fix`, re-stage; or `python.ruff_check=warn` in repo `.qa-gate.conf` |
| Blocked "ast-grep rule 'avoid-static-mut'" | `static mut` in staged rust | use atomics/OnceLock; or `astgrep=off` for the repo |
| Every `.unwrap()` warns | panic-set rules (advisory) | informational only — never blocks |
| Commit very slow (>10s) | cold ast-grep rule cache rebuild | one-time; subsequent commits fast |
| Docs commit slow | NukeNul spawn + lefthook stub | expected ~2s; QA itself is ~200ms |
| "shellcheck errors" on a fine script | real SC finding | fix, or `shell.shellcheck=warn` |
| QA not running at all | `LEFTHOOK=0`, `--no-verify`, or `qa.enabled=off` | remove the bypass |
| Override `.qa-gate.conf` ignored | wrong filename/location or bad value char | must be repo-root `.qa-gate.conf` (or `.git-guard/qa-gate.conf`); values limited to `[a-zA-Z0-9_,.-]` |
| A rule never fires | excluded from cache (failed validate) or not in a `ruleDirs` lang | validate standalone (§4); check `qa-rules/` |
| Wrong/no language detected | gating is by staged file EXTENSION | ensure the file is staged; check `QA_DEBUG=1` types line |

---

## 10. Revert / rollback

- **Whole QA layer (keep MVC):** restore `~/.git-hooks.pre-qa-backup`:
  `rm -rf ~/.git-hooks && cp -r ~/.git-hooks.pre-qa-backup ~/.git-hooks` (then
  `rm -rf ~/.git-hooks/common/qa-rules` if desired). Also remove the
  `qa_gate`/`nul`/QA lines from the pre-commit sentinel (or use the backup).
- **Everything (MVC + QA):** restore the original pre-everything state:
  `rm -rf ~/.git-hooks && mv ~/.git-hooks.pre-mvc-backup ~/.git-hooks`.
- **Granular:** delete the `# >>> git-guard mvc >>>` … `# <<< git-guard mvc <<<`
  blocks in `pre-commit`/`post-commit`; `rm` `qa_gate.sh`, `qa-gate.conf`,
  `qa-sgconfig.yml`, `qa-rules/`, and `~/.config/codex-security/git-hooks/pre-commit`.
- **Per-check:** set the offending check to `off` in `qa-gate.conf` (global) or a
  repo `.qa-gate.conf` (one repo). No file deletion needed.
