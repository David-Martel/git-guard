# QA_TOOLING.md — Account-wide git QA subsystem (canonical reference)

> The single source of truth for the **git-guard QA layer (subsystem A)**: the
> broad, language-gated, configurable, blocking-on-real-errors quality gate
> composed into the GLOBAL `~/.git-hooks` chain. If a check fires unexpectedly,
> if a commit is blocked, or if you need to add/extend a rule — start here.
>
> Companion docs: [`~/.agents/GIT_COMMIT_SAFETY.md`](GIT_COMMIT_SAFETY.md)
> (commit-safety doctrine / IRON RULES) and [`PLAN.md`](../PLAN.md) (at the
> root of the git-guard checkout or release tree, not beside `~/.agents`: the
> severable-engine architecture and staged rollout plan, which superseded §3 of
> the earlier, no-longer-published VIGIL partition plan). See `git log` for
> this file's revision history.
>
> **Since PR-4:** `~/.git-hooks` resolves through `~/.local/share/git-guard/current`
> to an IMMUTABLE, `git archive`-materialized version dir, not git-guard's live
> working checkout. A `git checkout`/WIP edit in the git-guard checkout no
> longer changes anyone's installed hooks — see the README "Quick start" and
> `install.sh`'s header comment for the mechanism (`git-guard install` /
> `git-guard update --to <tag>`).
>
> **Since the PR-4 follow-up:** `hooks/pre-commit` and `qa_gate.sh` resolve
> their own directory with `pwd -P` (physical) ONCE at entry and reuse that
> resolved path for every `common/*.sh` they dispatch to — so a single hook
> invocation is pinned to whichever version was `current` when it STARTED,
> even if a concurrent `git-guard update --to <tag>` re-points `current`
> mid-invocation. An unknown/misspelled `.qa-gate.conf` key is now also a
> hard, blocking error (see §5), and `install.sh`/`update` give a clear error
> when run from an installed archive instead of `.git-guard`'s live checkout.

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

### Environment variables and installer flags

Every `GIT_GUARD_*` variable the hooks, `bin/` and `install.sh` read on this
branch. "Unset" means the default behaviour applies.

| Variable | Read by | Effect |
|---|---|---|
| `GIT_GUARD=0` | `hooks/pre-commit`, `hooks/pre-push`, `hooks/prepare-commit-msg` | **A near-total bypass, not an attribution switch** (the auditable human emergency escape). `pre-commit` exits at its first check (`hooks/pre-commit:16`), so secret scanning, NUL cleanup, the QA gate and the downstream pre-commit chain are all skipped. `pre-push` still uploads git-lfs objects, then exits before any downstream push gate (`hooks/pre-push:37`). `prepare-commit-msg` adds no `Agent:` trailer. `post-commit` does not read it. `LEFTHOOK=0` has the same effect in `pre-commit` and `pre-push`. Git's hook-skip flag does not skip `prepare-commit-msg`. To suppress only attribution, set `GIT_GUARD_AGENT` to any value other than `codex`/`claude` (for example `none`) instead of using this near-total bypass. |
| `GIT_GUARD_AGENT` | `hooks/prepare-commit-msg` | Forces attribution: `codex` or `claude`. Any other non-empty value disables attribution. Unset means auto-detect from `CODEX_THREAD_ID` / `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT`. |
| `GIT_GUARD_DOWNSTREAM_HOOK` | `hooks/pre-commit` | Executable chained after git-guard's pre-commit. It takes precedence over the repo's `.git-guard/pre-commit.local` and over lefthook. |
| `GIT_GUARD_DOWNSTREAM_PRE_PUSH` | `hooks/pre-push` | The same, for pre-push (precedence over `.git-guard/pre-push.local` and lefthook). |
| `GIT_GUARD_DOWNSTREAM_POST_COMMIT` | `hooks/post-commit` | The same, for post-commit (precedence over `.git-guard/post-commit.local` and `git config gitGuard.downstreamPostCommit`). Its failure never fails the commit. |
| `GIT_GUARD_ALLOW_MISSING_LEFTHOOK=1` | `hooks/pre-commit`, `hooks/pre-push` | Allows a repo that ships a lefthook config to commit/push while lefthook is not installed. Without it, that case BLOCKS, because otherwise every lefthook gate would be skipped silently. |
| `GIT_GUARD_RULES_DIR` | `hooks/common/qa_gate.sh`, `bin/git-guard`, `bin/git-guard-run` | Overlay rules dir. It takes precedence over `rules_dir` in `qa-gate.conf` and over the bundled `rules-examples/` (see §4). |
| `GIT_GUARD_RULE_CACHE` | `hooks/common/qa_gate.sh` | Validated ast-grep rule cache dir. The default is the machine-global `<hooks>/common/qa-rules`. Set it together with `GIT_GUARD_RULES_DIR` so a test or experiment cannot repoint the live cache (`tests/run.sh` does this). |
| `GIT_GUARD_VERSIONS_PYTHON` | `hooks/common/fleet_versions.sh` | Interpreter for the fleet version checker (default `python3`); see "Fleet version minimums". |
| `GIT_GUARD_BACKEND`, `GIT_GUARD_IMAGE` | `bin/git-guard-run` | Force the `docker` / `wsl` / `native` backend, and set the Docker image tag (default `git-guard:local`). The README documents these. |
| `GIT_GUARD_STORE` | `install.sh` | Version store root (default `~/.local/share/git-guard`). Same as `--store`. |
| `GIT_GUARD_HOOKS_LINK` | `install.sh` | Path of the hooks symlink that `core.hooksPath` is set to (default `~/.git-hooks`). Same as `--hooks-link`. |
| `GIT_GUARD_TEST_PAUSE_AFTER_RESOLVE` | `hooks/pre-commit` | **Test-only** seam (seconds to sleep after the version resolve). Never set it in real use. |

`install.sh` flags (`./install.sh --help` prints the header). `git-guard install`
passes all of its arguments straight to `install.sh` (`bin/git-guard`
`cmd_install`):

| Flag | Effect |
|---|---|
| `--to <tag>` | Materializes that tag into the store and atomically points `current` at it. The default is `v$(cat VERSION)`. |
| `--store <dir>` | Version store root (overrides `GIT_GUARD_STORE`). |
| `--rules-dir <abs-path>` | Versioned install: writes `rules_dir=` into the persistent overlay `<store>/qa-gate.conf.local`, which is carried across updates, and copies it into the installed version. With `--dev-symlink` it writes only the live checkout's gitignored `hooks/common/qa-gate.conf.local` (`install.sh:314-320`): no persistent overlay is created, so a later switch to a versioned install does **not** keep it. |
| `--hooks-link <path>` | Hooks symlink path (overrides `GIT_GUARD_HOOKS_LINK`). |
| `--dev-symlink` | Legacy mode: links the hooks at this live checkout. Only for git-guard's own development. |
| `--dry-run` | Prints every mutation as `DRY: …` and changes nothing. |
| `--status` | Runs `bin/git-guard status` (install state, version, resolved rules dir). |
| `--uninstall` | Removes the `~/.git-hooks` symlink and restores its pre-git-guard backup, removes the `~/.agents/QA_TOOLING.md` and `GIT_COMMIT_SAFETY.md` symlinks and restores their backups. It leaves `core.hooksPath` and the materialized versions under the store in place (`install.sh:110-124`). |

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
| nul-cleanup | always | bundled Rust inventory / physical shell scan | **BLOCK** | owned regular single-link zero-byte removal only; directories, symlinks and nonempty/ambiguous matches are preserved, and block only when tracked or staged; untracked/ignored content, unreadable subtrees and toolchain failures warn; a crashed candidate worker blocks only when a reserved path is tracked or staged; audit-only under Git Bash/MSYS/Cygwin; skipped for a `/` or `$HOME` work tree |
| ast-grep trio | `*.rs` | `sg` (batched) | **BLOCK** | avoid-static-mut, no-glob-reexport, unsafe-with-panic |
| ast-grep panic-set | `*.rs` | `sg` | **WARN** | unwrap/panic/unchecked…; `astgrep_panics=block` blocks unconditional panics, `strict` blocks the whole set |
| ast-grep other | source files | `sg` | **WARN** | core/security/csharp/powershell rules |
| ruff check | `*.py` | `ruff` | **BLOCK** | repo config if present, else `--select E,F --isolated` |
| ruff format | `*.py` | `ruff` | **WARN** | warns if it would reformat staged files |
| mypy | configured staged `*.py` | `mypy` | **WARN** | honors `[tool.mypy].files`; strict mypy needs full project context |
| basedpyright | configured staged `*.py` | `basedpyright` | **WARN** | honors `[tool.basedpyright].include`/`exclude`; absent tools skip |
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

For mypy and basedpyright, extension gating is followed by repository-scope
gating. Explicit staged paths normally override each checker's project
`files`/`include` boundary, so git-guard filters them first and never widens a
repository's admitted type-check surface. Mypy string scopes are comma-separated;
basedpyright exclusions apply even when `include` is omitted. Scope parsing uses
`tomllib` on Python 3.11+ or `tomli` on older Python. Missing parsers and malformed
scopes are reported, and a checker configured as `block` blocks the commit when
its scope cannot be read. The default `warn` mode remains non-blocking.

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
| mypy | repo `.venv`, active venv, then `PATH` | repo `[tool.mypy]`; staged paths filtered by `files` |
| basedpyright | repo `.venv`, active venv, then `PATH` | repo `[tool.basedpyright]`; staged paths filtered by `include`/`exclude` |
| shellcheck | `PATH` | none |
| cargo | `PATH` | repo `rustfmt.toml` / `Cargo.toml` |
| dotnet | `PATH` | repo `.editorconfig` |
| Reserved-path inventory | bundled Rust source + `rustc` on Linux x64/ARM64; physical POSIX scan otherwise | external `NUKENUL_BIN` is never executed |

Reserved-path hygiene traverses the full eligible metadata tree, not only a
staged-file delta. Its availability and cost therefore depend on that tree.
Reserved-name directories/symlinks and nonempty matches are preserved. They
block only when the path is tracked or staged (`git ls-files -z` over the
index, which honours a partial commit's `GIT_INDEX_FILE`); untracked and
ignored content and unreadable subtrees only warn. Inspect/rename a blocking
path outside the hook, never bypass it with unsafe chmod or deletion. On Linux the
bundled helper compiles from the neutral physical `/` cwd using absolute
source/output paths and `RUSTUP_AUTO_INSTALL=0`. Repository-local toolchain
files cannot select the compiler; trusted host/user Rustup defaults and explicit
`RUSTUP_TOOLCHAIN` / `RUSTUP_HOME` remain authoritative, but are never
auto-installed. The runtime build uses `--cap-lints warn` (the self-test
compiles with `-D warnings`). A compiler or inventory failure warns
(`WARN_INVENTORY_BUILD` / `WARN_INVENTORY_RUN`), discards any partial output
and falls back to the physical scan; it never blocks the commit.

Files OWNED by this subsystem (all under `~/.git-hooks/common/` unless noted):

| File | Role |
|---|---|
| `qa_gate.sh` | the QA engine (language gating, config, ast-grep, checks) |
| `qa-gate.conf` | GLOBAL DEFAULT config (block/warn/off per check) |
| `qa-sgconfig.yml` | ast-grep root config → points at the validated rule cache |
| `qa-rules/` | VALIDATED rule cache (auto-rebuilt; see §4) |
| `nul-cleanup.sh` | scope, owner, type, identity and zero-byte checks plus qualified removal |
| `reserved_path_inventory.rs` | read-only NUL-delimited inventory with protected-scope pruning |
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
  `unsafe-with-panic`. Precedent: the same three-rule loop in
  `~/.claude/hooks/rust-pre-commit.sh` (cited by rule name, not line number —
  the previous `:44-46` reference silently went stale when that file gained a
  status header and the loop shifted to 66-68). Note that hook is **reference
  material only**: it installs to `.git/hooks/pre-commit`, which a global
  `core.hooksPath` pointing here overrides in every repo, so it never runs.
  It is the *origin* of this trio, not a second enforcement path.
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

**Format:** flat `key=value`, one per line, `#` comments, no sections, no
quotes. Parsed by a **pure-builtin** reader in `qa_gate.sh` (zero subprocess
spawns — this is why docs-only commits are ~200ms, not 4.8s). Dotted keys map
internally (`python.ruff_check` → `qacfg_python_ruff_check`).

**Per-check values:** `block` (refuse commit) | `warn` (print, proceed) | `off`
(skip). A repo can only set keys that exist in the global default — an
**unknown key is now a hard, blocking error** (since the PR-4 follow-up; see
below), not silently accepted.

**Malformed lines are a hard, blocking error (since PR-4).** A non-blank,
non-comment line that has no `=`, has an empty key before the `=`, or whose
value contains a character outside `[A-Za-z0-9_,.:/-]` refuses the commit and
names the exact `file:line`, e.g.:

```
git-guard QA BLOCKED: malformed config line .qa-gate.conf:5 (no '=' — expected key=value).
  >> python.ruff_check   block   # lint errors block the commit
```

This used to be silent (the line was just `continue`d and the override never
took effect, with zero output anywhere). That is precisely how
vigil-friction's `.qa-gate.conf` shipped 4 space-separated `key value`
overrides that did nothing for weeks — see §9. Every malformed line in the
file is reported, not just the first, and the refusal holds even if a *later*,
well-formed line in the same file sets `qa.enabled=off` (the config that
failed to parse cannot be trusted to gate its own bypass).

**An unknown key is ALSO a hard, blocking error (PR-4 follow-up), even when
the line is otherwise syntactically valid `key=value`.** This is the *other*
half of the vigil-friction defect: its `python.pyright=warn` line was
syntactically fine but named a key git-guard doesn't have (the real key is
`python.basedpyright`), so it still did nothing even once the `=` is fixed.
The engine now refuses and lists every valid key:

```
git-guard QA BLOCKED: unknown config key at .qa-gate.conf:8: 'python.pyright'.
  >> python.pyright=warn
Valid keys:
  astgrep astgrep_autofix astgrep_panics csharp.format largefile largefile_kb
  nul_cleanup powershell.astgrep powershell.psscriptanalyzer preserve_exemption
  python.basedpyright python.mypy python.ruff_check python.ruff_format
  qa.enabled rules_dir rust.clippy rust.fmt shell.shellcheck validate.json
  validate.yaml
```

`powershell.astgrep` is a deliberate exception: it is never read via `qa_cfg`
(ast-grep has no PowerShell grammar — see the note under §2) but stays a
*recognized* key so an existing repo conf that sets it does not now start
erroring.

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
powershell.astgrep=warn   powershell.psscriptanalyzer=warn
validate.json=block   validate.yaml=warn
largefile=warn   largefile_kb=5120
preserve_exemption=on     # off: preserve/* commits get the normal gates (§11)
rules_dir=                # unset by default; see §4 (SEVERABLE rule source)
```

This list is the literal `QA_KNOWN_KEYS` schema `qa_gate.sh` validates every
config line against (unknown-key check, above) — the two are meant to be kept
in lockstep; if you add a check with a new key, add it to both.

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
6. Reserved-name normalization includes extensions and trailing spaces/dots.
   Only owned regular single-link zero-byte matches can be removed; meaningful
   or ambiguous matches are retained, and block only when tracked or staged.
   On Windows the shell hook runs under Git Bash/MSYS/Cygwin and is audit-only
   there until Windows qualification; `nul-cleanup.ps1` is not wired into any
   hook. The POSIX stat-to-unlink race remains documented;
   neither inventory nor repeated checks establish an atomic filesystem snapshot.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Commit blocked, "QA BLOCKED: ruff" | real lint error in staged `.py` | `ruff check --fix`, re-stage; or `python.ruff_check=warn` in repo `.qa-gate.conf` |
| Blocked "ast-grep rule 'avoid-static-mut'" | `static mut` in staged rust | use atomics/OnceLock; or `astgrep=off` for the repo |
| Every `.unwrap()` warns | panic-set rules (advisory) | informational only — never blocks |
| Commit very slow (>10s) | cold ast-grep rule cache rebuild | one-time; subsequent commits fast |
| Docs commit slow | accumulated generated outputs, physical fallback scans or downstream gates | prune obsolete owned outputs; inspect inventory/gate timings. Native inventory still scans metadata and compiles per invocation. |
| "shellcheck errors" on a fine script | real SC finding | fix, or `shell.shellcheck=warn` |
| QA not running at all | `LEFTHOOK=0`, `--no-verify`, or `qa.enabled=off` | remove the bypass |
| Commit blocked, "malformed config line FILE:N" | a `.qa-gate.conf` line has no `=`, an empty key, or a value with a disallowed character | fix that exact line (message quotes it); values limited to `[A-Za-z0-9_,.:/-]` |
| Commit blocked, "unknown config key FILE:N" | the key is syntactically fine but isn't one git-guard recognizes (typo, or a name from a different tool) | the message lists every valid key; check filename/location too (`.qa-gate.conf` or `.git-guard/qa-gate.conf` at repo root — a file in the wrong place is never loaded at all, so it produces neither error) |
| `git-guard update --to <tag>` fails with a confusing git error, or "not a git checkout" | ran from an INSTALLED, ARCHIVED release (e.g. `~/.local/share/git-guard/current/bin/git-guard update …`) — it has no `.git` to resolve tags from | run install/update from an actual git-guard clone: `cd ~/dev/repos/git-guard && sh bin/git-guard update --to <tag>` |
| A rule never fires | excluded from cache (failed validate) or not in a `ruleDirs` lang | validate standalone (§4); check `qa-rules/` |
| Wrong/no language detected | gating is by staged file EXTENSION | ensure the file is staged; check `QA_DEBUG=1` types line |

---

## Fleet version minimums

The explicit `git-guard versions` command invokes
`vigil-utils/tools/fleet_versions/check.py` with its own
`policy/fleet-versions.toml`. git-guard does not copy minimums, compare package
versions, invent compatibility lanes, or fetch a newer policy during a check.

```sh
git-guard versions --repo "$TARGET_CHECKOUT" --commit "$TARGET_SHA" \
  --checker-root "$UTILS_CHECKOUT" --checker-commit "$UTILS_SHA" --enforce --json "$EVIDENCE_DIR/versions.json"
```

Use `--report` for initial inventory; review and declare justified lanes through
the canonical registry process, then explicitly select `--enforce` in the
repository's CI or existing hook owner. Neither installing git-guard nor adding
this command enables enforcement elsewhere. Repositories with their own
`core.hooksPath` retain it. A pre-push caller must provide the exact committed
snapshot being pushed, not assume its working directory represents every ref.

The contract is deliberately restrictive:

- Supply full lowercase 40-character commit IDs for the target and checker.
  The checker pin is independent of another repository's QA-tooling cutoff.
  The caller must obtain both pins from reviewed configuration; a matching hash
  proves identity, not approval of an arbitrary checker supplied by the caller.
- Use isolated checkouts with no concurrent writers. The adapter verifies HEAD,
  clean index/worktree status, all tracked Git blob bytes, and absence of
  untracked or ignored inputs before and after the checker runs. This catches
  staged downgrades, `assume-unchanged` edits, and ignored manifests that the
  canonical filesystem scanner could otherwise read. Keep virtual environments,
  generated caches and reports outside these checkouts. CRLF or smudge-filter
  transformations that change committed bytes are refused.
- A tracked symlink must use a relative target, and every hop of its chain must
  itself be a tracked entry, ending at a tracked regular file. So a link into
  Git metadata (`check.py -> ../../.git/evil.py`), through any untracked path,
  to an absolute path, or to a directory is refused before anything runs. A
  tracked file reached through a symlinked directory is refused as well.
  Broken links, escapes, submodule entries, sparse/missing files and non-regular
  file substitutions are refused rather than treated as an incomplete clean
  inventory. This does not
  make a concurrently mutable directory an atomic snapshot.
- Python 3.11+ and Git must already be available. Set
  `GIT_GUARD_VERSIONS_PYTHON` to an existing interpreter path if necessary. The
  canonical checker runs with isolated Python, no site packages or bytecode,
  and only its verified local module directory added for imports. A checker
  revision requiring third-party imports needs a separately reviewed runtime
  contract. No tool is installed. Network lookups are disabled explicitly.

For Linux, macOS or Windows Git Bash CI, prepare fresh checkouts using
`git -c core.autocrlf=false clone --no-checkout ...` and
`git -c core.autocrlf=false checkout --detach <full-sha>`. Disable configured
smudge filters in that disposable clone before checkout; LFS pointers must stay
as committed pointer bytes for this source-inventory check. Materialize LFS
artifacts separately. This is not a universal ordinary developer hook.

The command prints target/checker commits, inventory digests, policy/checker
SHA256 hashes, the adapter helper SHA256, interpreter identity and mode. It preserves checker stdout and
stderr and returns the exact checker exit status; provenance/setup failures
return 2. Git operations have a 60-second timeout and the checker a 120-second
timeout. Invocation does not change source, the index, hooks or host software.
`--json` writes a new receipt outside both snapshots, preserving the full canonical
JSON object under `canonical_report` with provenance and `checker_exit_code`.
It never overwrites a receipt. UNKNOWN/unresolved findings, warnings and lane
errors remain unchanged; exit zero does not establish complete coverage. A
checker setup failure may have no report (recorded as null), while exit 0/1
without a valid report fails closed. Keep the receipt together with stderr.

**Canonical semantics remain authoritative.** At reviewed `vigil-utils`
`a2bea934a08ae594f596a2dbc82e80593096a176`, enforcement rejects minimum violations,
invalid lanes and parse warnings. It still treats floating refs as unresolved
without rejecting them, drops prerelease suffixes when comparing versions, and
treats a low declared floor as advisory while relying on resolved pins. These
are outstanding canonical-checker concerns, not fixes delivered by this adapter.
`--enforce` success is therefore the selected checker's result, not proof of
complete SemVer/PEP440 compliance or installed/loaded fleet version alignment.
Expand adoption only after those semantics and the applicable lanes are reviewed.

The adapter's fixture tests run through `tests/run.sh fleet_versions`; the
normal suite includes them. They prove real CLI delegation, exact exit-code
propagation, clean/provenance refusal and environment isolation. Canonical
policy correctness remains covered by vigil-utils' own tests and ratchet.

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

## 11. preserve/* exemption

A preservation commit snapshots work-in-progress that the hooks did not author,
so a repo's language/lint gates (clarius's lefthook ast-grep/pyright/
rust-no-panic, intublade's `astgrep_panics=strict`) refuse it. That pushed
preservation out of commits and into fragile `git stash create` objects. The
exemption lets such a commit through with **only the structural checks**.

**It applies only when both hold:**

- the branch is `preserve/*` (at pre-push: **every** updated remote ref is
  `refs/heads/preserve/*` or `refs/preserve/*`), and
- the message carries `Preserve-Of: <ref-or-sha>` and the value resolves to a
  commit (`git rev-parse --verify <value>^{commit}`). Only ref names and shas
  are accepted. Revision syntax such as `:/text` or `@{...}` is refused, so a
  trailer naming nothing unlocks nothing.

```
git switch -c preserve/clarius-wip-20261004
git add -A
git commit -m "preserve: WIP from the clarius lane" -m "Preserve-Of: $(git rev-parse --short HEAD)"
```

**What still runs:**

| Check | Where it lives | On an exempted commit / push |
|---|---|---|
| Secret scan (BLOCK) | `pre-commit` step 1, `common/secret_scan.sh` | runs before the exemption is consulted; at pre-push, every new commit being pushed is scanned too (`refs/preserve/*` written by `update-ref` never met a commit hook) |
| NUL / reserved-path cleanup (BLOCK) | `pre-commit` step 2, `common/nul-cleanup.sh` | runs before the exemption is consulted |
| Large-file guard (WARN) | `common/qa_gate.sh` | runs via explicit `qa_gate.sh --only largefile` (listed in `GG_PRESERVE_QA_STRUCTURAL`, `common/preserve.sh`). It is warn-only, as everywhere |

**Scan authority.** Ordinary `pre-commit` invokes the secret scanner and QA gate
without selectors: staged added lines and the full configured gate always run.
Ambient `GIT_GUARD_SECRET_SCAN_COMMITS` and `QA_ONLY_CHECKS` are ignored.
The preserve helper explicitly requests `secret_scan.sh --commits <full-sha> ...`
for pushed history; every argument must name an existing commit using the
repository's full hexadecimal object ID. Its structural-only QA call uses
`qa_gate.sh --only largefile`. Missing or unknown arguments fail closed. These
arguments select a scan, and do not grant a preservation exemption: branch,
trailer and push-ref admission remain in `preserve.sh`.

**What it skips:** the rest of `qa_gate.sh` (the language and lint checks) and
the repo's downstream chain (`GIT_GUARD_DOWNSTREAM_HOOK` /
`GIT_GUARD_DOWNSTREAM_PRE_PUSH`, `.git-guard/pre-commit.local` /
`pre-push.local`, `lefthook run`).

**How it works.** The message does not exist yet at pre-commit, so on a
`preserve/*` branch pre-commit runs the structural checks and writes a deferral
marker (`$(git rev-parse --git-path git-guard/preserve-deferred)`, holding the
index tree and branch). The `commit-msg` hook consumes it. A valid trailer logs
the exemption and passes. A missing or invalid trailer, or a marker that does
not match the commit, re-runs the full `pre-commit` right there, so no QA is
skipped without a valid trailer. pre-commit deletes any marker it did not write
itself.

**Logging.** Every use prints `git-guard: preserve exemption USED (...)` on
stderr and appends a line to
`$(git rev-parse --git-common-dir)/git-guard/preserve-exemptions.log`. That is
one log per repository, shared by its worktrees, with the timestamp, hook,
branch or refs, the index tree or commit count, the resolved `Preserve-Of`
values, and what was skipped.

**Opt-out:** `preserve_exemption=off` in the repo's `.qa-gate.conf` (§5), or
`GIT_GUARD_PRESERVE_EXEMPTION=0` in the environment. The environment can only
disable it. A malformed `.qa-gate.conf` also disables it (fail closed), and the
normal gate then reports the error.

