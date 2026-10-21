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

The active `core.hooksPath` chooses the entry point. A repository override
(`.githooks`, for example) remains its own authority; the global chain does not
replace it or automatically dispatch a separate `.pre-commit-config.yaml`.

```text
GLOBAL ~/.git-hooks/pre-commit
  secret scan -> reserved paths -> preserve exemption -> qa_gate
  -> branch/staging warnings -> one downstream provider

GLOBAL ~/.git-hooks/pre-push
  LFS upload -> identity -> preserve exemption -> backlog hygiene
  -> one downstream provider with original remote arguments/ref stdin

Provider precedence
  explicit downstream -> executable .git-guard/<hook>.local
  -> declared lefthook configuration -> declared pre-commit configuration
```

A PATH-only lefthook does not replace a declared pre-commit framework. A repo
with no downstream declaration stays unaffected. Missing configured tools refuse
loudly; provider errors propagate. Repositories with their own hooks keep their
QA semantics (including intentional git-guard QA disabling), and this change does
not enable or rewrite them. Post-commit identity and Agent trailer handling stay
separate from software QA provider selection.

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
| `GIT_GUARD_HYGIENE` | `hooks/common/hygiene.sh` (via `pre-push`, `post-checkout`) | Backlog-limit mode for this invocation: `off`, `warn` or `enforce`. Beats `git config hygiene.mode`; an unknown value means `warn`. See §12. |
| `GIT_GUARD_HYGIENE_GH` | `hooks/common/hygiene.sh` | `gh` executable for the open-PR count (tests stub it). |
| `GIT_GUARD_TEST_PAUSE_AFTER_RESOLVE` | `hooks/pre-commit` | **Test-only** seam (seconds to sleep after the version resolve). Never set it in real use. |

Declared repository providers run after the explicit downstream and executable
`.git-guard/*.local` providers: a declared lefthook configuration keeps priority;
otherwise `.pre-commit-config.yaml` (or `.yml`, when `.yaml` is absent) dispatches
the pre-commit framework. A
lefthook binary on PATH without a repository configuration does not claim this
role. Missing configured providers fail loudly. Repositories with their own
`core.hooksPath` remain authoritative; this does not enable git-guard there.
An explicitly allowed missing declared lefthook remains a skip of that provider,
and does not fall through to the pre-commit framework. The framework executable
must resolve to an executable file; a shell lookup alone is insufficient.
Existing entries and symlinks count as declarations even when broken or not
regular files. A broken `.yaml` declaration keeps priority and refuses instead
of substituting `.yml`. Valid linked configs keep framework semantics at commit
time; the new pre-push route requires a regular, non-symlink config in both the
working checkout and the pushed HEAD, since a linked target is not sealed here.

The framework route uses `pre-commit hook-impl`, preserving the hook stage,
remote arguments and original pre-push stdin. Because the framework selects one
update and runs tools in the working checkout, this route admits only one changed
update whose commit is current HEAD, with a clean tracked workspace and a config
belonging to that HEAD. Annotated tags are compared by their commit. Delete-only
and unchanged-source pushes do not run software QA. Other heads, dirty tracked
sources and multiple changed updates refuse before execution; publish them
separately from their corresponding checkout or use an explicit repository gate
that qualifies immutable snapshots. This route does not seal untracked files,
environments or dependencies and is not a remote/offload qualification receipt.
The new declared pre-commit pre-push route also refuses any gitlink in the pushed
HEAD: submodule-backed source is unsupported until recursively validated. This
includes clean and uninitialized submodules; parent comparisons cannot seal a
submodule's own index and tracked bytes. Use an explicit repository gate that
qualifies immutable snapshots for these repositories. Commit-time framework
dispatch and the other providers retain their existing semantics.
The explicit/local/lefthook providers retain their own semantics, and the
documented emergency bypass remains available.

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
| `--no-git-defaults` | Skips setting the recommended global git config (§12). By default the installer sets each listed key only when it is unset. |
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
| quality mandate | `*.py`/`*.rs` | `mandate_scan.sh` (ruff + ast-grep + text) | **BLOCK on changed lines** | per-rule `mandate.<rule>`; old debt in a touched file does not block; see §13 |

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

**Where the rules come from.** `qa_gate.sh` resolves one rules directory, first
hit wins: `$GIT_GUARD_RULES_DIR` (env) → the `rules_dir` key in `qa-gate.conf` /
`qa-gate.conf.local` (written only by `install.sh --rules-dir DIR`) → the bundled
`rules-examples/` two levels above `qa_gate.sh`. **No overlay is configured by
default, so an installed git-guard enforces the bundled `rules-examples/` set.**
Measured on asuspro13 2026-10-14: the installed v0.2.10 cache's stamp
(`qa-rules/.built-from`) reads `…/v0.2.10/hooks/common/../../rules-examples`, there
is no `qa-gate.conf.local`, and no `rules_dir` is set, so the 78 rules in
`~/.claude/rules` are not used by git-guard on that host. (An earlier version of
this section said the installer always points `rules_dir` at `~/.claude/rules`;
that is true only when `--rules-dir` is passed.)

The bundled set the cache loop reads is `core` 3, `security` 3, `rust` 15,
`rust/panics` 16, `csharp` 6, `powershell` 2, `python` 6, `typescript` 5 rule
files (counted 2026-10-14). `rules-examples/mandate/` is **not** read by this
cache: those rules belong to the quality mandate scanner (see "Quality mandate"
below), which loads them itself so that they are never double-reported here.

ast-grep's multi-rule loader (`sg scan -c sgconfig.yml`) is ~20× faster than one
`sg scan --rule` per file, but a rule that fails its strict parse would poison the
whole batch. So `qa_gate.sh` maintains a **validated cache** at
`<install>/hooks/common/qa-rules/` (or `$GIT_GUARD_RULE_CACHE`): each source rule
is checked with `sg scan --rule <f>` and only copied if it parses. The cache is
rebuilt automatically when a source `.yml` is newer than the stamp
`qa-rules/.built-from`, or when the stamp names a different source directory.
First build costs ~15-30 s once; steady-state commits pay nothing for it.

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
1. Drop/edit the `.yml` in the resolved rules directory (by default the
   bundled `rules-examples/<lang>/`; the cache is derived from it). Validate it
   standalone: `ast-grep scan --rule rules-examples/<lang>/<id>.yml --json=compact <somefile>`,
   and add its failing/passing row to `tests/27-rule-behaviour.t.sh`.
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
mandate.enabled=on        # quality mandate master switch (independent of qa.enabled); §13
mandate.<rule>=…          # off|warn|changed|block per rule; the 20 rules and defaults are in §13
mandate.vendored=         # comma-separated repo-relative dirs exempt from the mandate; §13
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

## 12. Backlog hygiene limits

Owner rule (2026-10-09): clear your merged worktrees, branches and PRs before
starting new work. `hooks/common/hygiene.sh` enforces it per repository, on
each host, at the one point where it cannot strand work: **a push that creates
a NEW branch on the remote is refused while the repo is over a limit.**
Commits, pushes of existing branches, deletes, tags, `preserve/*` pushes and
the first publish of the default branch (`main`, `master` or the base's own
name) are never blocked. Only the check's refusal code refuses a push; any
other failure of the check prints a warning and the push proceeds. (The check
signals a refusal with exit 77, so a crash is never mistaken for one.) `post-checkout` prints a warning after `git worktree add`
when the repo is over a limit, and never fails.

| Key (`git config`) | Default | Counts |
|---|---|---|
| `hygiene.mode` | `enforce` | `enforce`, `warn` or `off` (`GIT_GUARD_HYGIENE` beats it) |
| `hygiene.maxWorktrees` | 3 | linked worktrees, primary excluded; `0` turns the check off |
| `hygiene.maxStaleBranches` | 5 | local branches whose upstream is gone or whose tip is merged into `<remote>/HEAD`; `main`, `master`, `preserve/*` and branches a worktree uses (checked out, or under an in-progress rebase, `rebase --update-refs` or bisect) are excluded; `0` is off |
| `hygiene.maxOpenPRs` | unset (off) | open non-bot PRs on the GitHub remote, through `gh api` REST; set it to enable |
| `hygiene.exemptLockPrefix` | `vigil.operator-release/`, `vigil.fleet-build/` (set by `defaults` when none is configured) | multi-valued; a worktree locked with a reason that starts with one of these is infrastructure (for example `vigil.operator-release/`, `vigil.fleet-build/`) and is never counted or drained |
| `hygiene.baseRef` | unset | integration ref used when `refs/remotes/<remote>/HEAD` is not set; without either, `refs/remotes/<remote>/main` or `/master` is tried, and if none exists the merged test is skipped |
| `hygiene.drainMinAgeMinutes` | 1440 | `drain` keeps a worktree whose HEAD moved (worktree add, checkout, commit) within this many minutes, because a fresh worktree is clean and "merged" but may be another agent's live checkout; `0` disables |
| `hygiene.preserveDir` | `${XDG_STATE_HOME:-~/.local/state}/git-guard/preserve` | where `drain` writes bundles |

Repo-local values beat global ones (git's own precedence), so a repo with a
legitimate need sets `git config hygiene.maxWorktrees 6` locally. Anything
that cannot be measured (no base ref, no `gh`, offline, not GitHub) is
skipped, never blocked.

**Escape hatches.** `GIT_GUARD_HYGIENE=warn git push …` for one push,
`GIT_GUARD_HYGIENE=off` to skip, `GIT_GUARD=0` for all hooks. Never the
hook-skip flag.

**Draining.** The CLI is not on PATH by default; run it as
`sh ~/.local/share/git-guard/current/bin/git-guard hygiene …` (hook messages
print the exact path). `git-guard hygiene report` prints counts against limits;
`check` exits 1 when over. `git-guard hygiene drain` is a dry run; `--apply`
removes only what passes every check:

- its HEAD has not moved within `hygiene.drainMinAgeMinutes` (default a day);
- the worktree is not locked (or exempt), has no staged, unstaged or untracked
  changes, and no merge, rebase, cherry-pick, revert or bisect in progress;
- it has no ignored files, unless `--allow-ignored` (`git worktree remove`
  deletes ignored files);
- its tip is an ancestor of the base, or every commit is patch-equivalent, or
  every file it touched has the same content on the base (squash merge);
- no stash was made on the branch, and its upstream, if still present, did not
  move after the merge (LEARNED_RULES 48).

Merge state is judged from your remote-tracking refs, so run
`git fetch --prune` first; drain does not fetch. drain is not owner-aware:
read the dry-run list and use `--apply` only when every item is yours or is
covered by an explicit custody transfer.

Before anything else, drain reads which branches the worktrees are using:
each git dir's HEAD and its rebase and bisect state. If it cannot list or
search `.git/worktrees`, a worktree's git dir or rebase state directory, or
cannot read a HEAD or state file that exists, it cannot tell which branches
are in use, so it treats every branch as in use: the dry run and `--apply`
both exit non-zero, remove nothing and name the path that could not be read.

A tip that is not an ancestor is preserved before anything is removed: it is
pinned to a temporary ref, bundled, verified with `git bundle verify`, a
`.sha256` file is written beside the bundle, and only then is the temporary ref
deleted. If any of those steps fails, nothing is removed. Every branch is
deleted with an atomic compare-and-delete of the exact tip that was checked
(`git update-ref -d <ref> <tip>`), never `git branch -d`, which deletes whatever
the branch points at now. An ancestor of the base needs no bundle; squash-merged
work is deleted only after its bundle exists. Because a same-tip checkout does
not move the ref, every worktree's use of the branch is read again right before
the delete, and the branch is kept if any worktree has it checked out or is
rebasing or bisecting it (a worktree in that state is listed as detached; drain
reads its rebase and bisect state files, as `git branch -d` does), or if that
scan fails. Right before a worktree is removed, its HEAD, branch, status
(including ignored files, unless `--allow-ignored`) and in-progress operations
are read again, and it is kept if anything changed since inspection. A branch
whose upstream is gone but whose commits are not on the base is bundled and
kept for its owner. Removal uses plain
`git worktree remove`, never force. Remote branches are left to GitHub's
`delete_branch_on_merge`. Missing worktree registrations (`prunable`) are only
reported, because the drive may simply be offline.

**Global defaults.** `install.sh` (and `git-guard hygiene defaults`) sets these
global keys only when they are unset: `fetch.prune=true`,
`worktree.guessRemote=true`, `rerere.enabled=true`, `hygiene.maxWorktrees=3`,
`hygiene.maxStaleBranches=5`, and the two infrastructure lock prefixes above
(seeded only when no `hygiene.exemptLockPrefix` is set globally, so removing
one of them is respected).
Two keys are deliberately left alone. Shortening `gc.worktreePruneExpire` would
prune the registration of a worktree whose drive is merely offline.
`fetch.pruneTags` would delete local-only tags on every fetch.
`install.sh --uninstall` does not remove these keys.

**Relation to vigil-utils.** `tools/backlog_caps/report.py` with
`policy/backlog-caps.toml` is the fleet-wide, lane-attributed GitHub report
(per-lane PR and worktree caps, remote stale branches). git-guard is the
local, per-host enforcement half. The units differ: `hygiene.maxWorktrees`
counts every linked worktree of one repo on one host;
`agent_worktrees_per_repo` and `active_worktrees_per_lane` are lane-attributed.

---

## 13. Quality mandate

**What it is.** The owner's commit-time quality mandate (2026-10-14): pydantic v2
only, no strings as enumerations, no explicit `Any`, no error path that turns a
failure into `None`/`False`/an empty value, clearly typed and informative errors,
no silent failures. The canonical policy text is vigil-ai-tpm
`templates/strict-python-module/RULES.md` at commit `ecbedf353d4a`; each rule
below also cites the repo line it comes from. Enforcement lives in
[`hooks/common/mandate_scan.sh`](../hooks/common/mandate_scan.sh) (a POSIX entry
point) and [`mandate_scan.py`](../hooks/common/mandate_scan.py) (standard library
only, run with `python3 -I`). Its ast-grep rules are in
[`rules-examples/mandate/`](../rules-examples/mandate/), which the §4 rule cache
does not read, so nothing is reported twice.

**Where it runs.**
- **pre-commit**, through `qa_gate.sh` (`qa_check_mandate`), on staged `*.py` and
  `*.rs`. The staged content is exported with `git checkout-index` into a
  temporary tree; the working tree is never read.
- **pre-push**, through `hooks/pre-push`, only for a pushed commit that carries
  `.git-guard/mandate-baseline.json` (the debt register below). A repo without
  one pushes exactly as before and the scanner prints nothing.
- **Directly**, from a repo whose own hooks replace git-guard's (vigil-utils,
  vigil-spark): `sh <git-guard>/hooks/common/mandate_scan.sh --staged`, or
  `--range origin/main..HEAD` in CI. `qa.enabled=off` does not switch it off;
  `mandate.enabled=off` does. A direct caller owns the preserve/* decision:
  the exemption in §11 covers only the hook path.

**Policy comes from the snapshot being checked.** The repo layer of the
config (`.qa-gate.conf`, else `.git-guard/qa-gate.conf`) is read from the same
snapshot as the code: from the **index** at pre-commit (`git cat-file blob
:.qa-gate.conf`), and from **each pushed commit** at pre-push. A multi-ref push
therefore judges every ref by its own committed policy, a checkout with
`mandate.enabled=off` cannot switch off a pushed branch whose own conf is on, and
an unstaged conf edit has no effect on the commit (stage it). The global
defaults and the machine overlay (`qa-gate.conf.local` beside `qa_gate.sh`)
still apply on top; every summary line ends with `policy: <snapshot> <file>`,
naming the overlay when one is present, so the governing policy is never an
invisible input. (git-guard #72 review; `qa_gate.sh --get-prefix mandate.
--repo-conf FILE` is the interface.)

**Severities.** One key per rule, `mandate.<rule>=off|warn|changed|block`:

| value | effect |
|---|---|
| `off` | the rule does not run |
| `warn` | findings on added/modified lines are printed; the commit proceeds |
| `changed` | findings on added/modified lines **block**; old debt in a touched file does not |
| `block` | any finding anywhere in a staged file blocks |

Changed lines come from `git diff --cached -U0 -M --diff-filter=AMR`, with rename
detection on so that moving a file does not turn its existing debt into "new"
lines. A finding counts as changed when any line of its span is an added line.

**The rules.**

| Rule (`mandate.<rule>`) | Policy | Protects against | Tool / code | Default | Source | Fix |
|---|---|---|---|---|---|---|
| `pydantic_v1` | PY-01 | v1 APIs in a v2-only fleet | ast-grep `mandate-pydantic-v1` (`pydantic.v1`, `@validator`, `@root_validator`, `class Config:` in a BaseModel, `parse_obj`/`parse_raw`/`parse_file`/`from_orm`) | block | vigil-spark AGENTS.md:188-190; vigil-ai-tpm CLAUDE.md:76 | `field_validator`/`model_validator`, `model_config = ConfigDict(...)`, `model_validate` |
| `pydantic_v1_ambiguous` | PY-01 | `.dict()` / `.copy(update=)` | ast-grep `mandate-pydantic-v1-ambiguous` | warn | as above | `model_dump()` / `model_copy(update=)` |
| `bare_except` | PY-06 | Ctrl-C and `sys.exit()` swallowed | ruff `E722` | block | clarius AGENTS.md:653-655 | catch a named exception |
| `blind_except` | PY-06 | every failure handled alike | ruff `BLE001` | changed | clarius AGENTS.md:653-655; vigil-ai-tpm pyproject.toml:80-87 | catch what you can recover from |
| `except_pass` | PY-06 | a failure discarded (logging does not count as handling) | ruff `S110` + ast-grep `mandate-except-pass` | changed | clarius AGENTS.md:653-655 | re-raise typed, or `contextlib.suppress(Specific)` |
| `except_continue` | PY-06 | a skipped item with no record | ruff `S112` + ast-grep `mandate-except-continue` | changed | clarius AGENTS.md:653-655 | record it (`failures.append`) and surface it |
| `except_sentinel` | PY-05 | failure returned as `None`/`False`/`""`/`[]`/`{}` | ast-grep `mandate-except-sentinel` | changed | clarius CLAUDE.md:422-423 | raise typed, or return a typed outcome |
| `broad_suppress` | PY-06 | `contextlib.suppress(Exception)` | ast-grep `mandate-broad-suppress` | changed | clarius AGENTS.md:653-655 | name the expected exceptions |
| `no_any` | PY-03 | the type checker switched off | ruff `ANN401` + ast-grep `mandate-explicit-any` (annotations, generics, aliases, the import) | changed | clarius AGENTS.md:657-658; vigil-ai-tpm RULES.md:10-11; vigil-oto CLAUDE.md:117 | `object`, a Protocol/TypeVar, a JSON alias, a model |
| `raise_from` | PY-07 | a lost exception chain | ruff `B904` | changed | vigil-ai-tpm RULES.md:48-52 | `raise X(...) from exc` |
| `bare_exception_raise` | PY-08 | `raise Exception(...)` | ruff `TRY002` | changed | clarius README.md:123-125 | a specific exception class |
| `raise_without_message` | PY-08 | `raise X()` / `raise XError` with no reason | ast-grep `mandate-raise-without-message` | changed | clarius README.md:123-125 | say what failed and how to fix it |
| `unchecked_subprocess` | PY-13 | a failing child ignored | ruff `PLW1510` | changed | vigil-ai-tpm RULES.md:123-125 | `check=True`, or `check=False` and branch |
| `suppression_code` | PY-09 | blanket `# noqa` / `# type: ignore` | ruff `PGH004`, `PGH003` | changed | vigil-ai-tpm RULES.md:83-86 | name the code |
| `suppression_reason` | PY-09 | a mandate suppression with no reason | text check | changed | vigil-ai-tpm RULES.md:83-86 | add `# SAFETY: <reason>` on the line |
| `str_enum_param` | PY-04 | `mode: str`, `kind: int` and similar | ast-grep `mandate-str-enum-param` | changed | clarius CLAUDE.md:420-422; vigil-spark AGENTS.md:200 | an Enum, parsed at the boundary |
| `literal_enum` | PY-04 | `Literal["a", "b"]` as an enum | ast-grep `mandate-literal-enum` | warn | vigil-spark rule (vigil-ai-tpm RULES.md:11 recommends `Literal`) | an Enum |
| `magic_number` | PY-04 | unexplained numbers in comparisons | ruff `PLR2004` | warn | clarius CLAUDE.md:420-422 | a named constant or IntEnum |
| `python_syntax` | PY-10 | a file nothing could check | ruff parse errors | changed | git-guard | fix the syntax error |
| `rust_panic` | RS-01 | `unwrap`/`expect`/`panic!`/`todo!`/`unimplemented!` in non-test Rust | ast-grep `mandate-rust-panic` | changed | clarius CLAUDE.md:57; vigil-audio AGENTS.md:31-38; agent-hub CLAUDE.md:253 | a typed error with `?` |

The whole-file panic set of §4 (`astgrep_panics`, default warn) is unchanged and
independent of `rust_panic`.

**Exemptions.**
- Test code (`tests/`/`test/` dirs, `test_*.py`, `*_test.py`, `conftest.py`;
  Rust `tests/`, `benches/`, `examples/`, `*_test.rs`, `tests.rs`, `build.rs`,
  and inline `#[cfg(test)]` modules and `#[test]` functions) is exempt from
  `no_any`, the silent-failure rules (`bare_except`, `blind_except`,
  `except_*`, `broad_suppress`), `str_enum_param`, `literal_enum`,
  `magic_number` and `rust_panic`. It is **not** exempt from `pydantic_v1`,
  `raise_*`, `unchecked_subprocess` or the suppression rules.
- Vendored trees are exempt from everything: any path with a `vendor`,
  `_vendor`, `third_party`, `external*`, `node_modules`, `.venv` or
  `site-packages` directory component, plus any repo-relative directory the
  repo declares with `mandate.vendored=dir/a,dir/b` (vigil-spark needs
  `qobi/chumpy`, a vendored copy of chumpy that holds the only whole-file
  `bare_except` hit measured across four fleet repos). An entry that is absolute
  or contains `..` is a config TOOL ERROR. `*.pyi` stubs are not scanned.

**Recording justified debt (on the line).** Every finding prints the rule, the
`file:line`, the offending line, why the rule exists (with its source), how to
fix it, and the exact suppression to use if the code is right as written:
```python
except Exception as exc:  # noqa: BLE001  # SAFETY: collected and re-raised by the caller
except OSError:  # ast-grep-ignore: mandate-except-pass  # SAFETY: optional probe; absence is the answer
```
```rust
let first = v.first().expect("non-empty");  // ast-grep-ignore: mandate-rust-panic  // SAFETY: len checked above
```
A ruff-backed rule accepts its ruff code in `# noqa:` (`S110` also covers
`mandate-except-pass`, `S112` covers `mandate-except-continue`, `ANN401` covers
`mandate-explicit-any`); every rule accepts `ast-grep-ignore: <rule-id>` on the
line or on a comment line directly above it. git-guard applies this
suppression model itself rather than relying on ast-grep's: ast-grep 0.39.5 (the
CI pin) ignores a same-line `ast-grep-ignore: id  # SAFETY: ...` that 0.45.3
honours, so the result would otherwise depend on the installed version. On an
added line, a mandate suppression without `SAFETY:` or `best-effort:` is itself a
`suppression_reason` finding. A blanket `# noqa` never suppresses a mandate
ast-grep rule.

**Outcomes.** The scanner always ends with one determined line:
`BLOCKED — n finding(s) …: rule (count), …` (exit 1), `PASSED — 0 blocking
findings …` (exit 0, with warnings and any unevaluated rules counted), or
`TOOL ERROR` (exit 2). A TOOL ERROR is never read as a clean scan, and it refuses
the commit:
- ruff exiting with anything but 0/1, output that is not a JSON list, or an exit
  code that disagrees with the number of diagnostics;
- ast-grep exiting non-zero (all mandate rules are `severity: warning`, so a
  finding never makes it exit non-zero) or printing a line that is not a finding;
- the rule files under `rules-examples/mandate/` not matching the scanner's table;
- an executable named `ast-grep` whose `--version` exits non-zero or does not
  name ast-grep (a broken install is not a missing tool). An `sg` that is not
  ast-grep, such as util-linux set-group, still just means ast-grep is absent;
- an invalid `mandate.<rule>` value, or a `.qa-gate.conf` that does not parse;
- any child process still running after `GIT_GUARD_MANDATE_TIMEOUT` seconds
  (default 300). It is killed. Measured 2026-10-14: ast-grep 0.39.5 (the CI pin)
  deadlocked in a futex wait on a one-file `scan --rule` while the host was busy,
  so a hang would otherwise hold a commit forever.

A scanner that is **not installed** (or a `python3` that cannot start, such as an
unconfigured version-manager shim) is a WARN that names every rule it left
unevaluated, then exit 0: the anti-brick rule of §2. ruff is resolved like the
ruff check in §2 (repo `.venv`, then `$VIRTUAL_ENV`, then `PATH`), ast-grep only
when the binary identifies itself as ast-grep. ruff runs with `--isolated` and an
explicit `--select`, so a repo's ruff config cannot turn a mandate rule off; only
`mandate.<rule>` can. ruff's "syntax added in Python 3.x" version advisories are
ignored; a real parse failure is `python_syntax`.

**Debt register (pre-push ratchet).** A repo with a backlog it cannot fix at once
records it per rule **per file** in `.git-guard/mandate-baseline.json`:
```json
{
  "version": 1,
  "policy_revision": "git-guard-mandate-1",
  "measured_at_commit": "<sha>",
  "rules": {
    "except_pass": {"src/legacy.py": 3},
    "no_any": {}
  }
}
```
`--write-baseline` writes it from the index (or `--rev REV`) for every enforced
(`changed`/`block`) rule, and refuses when a rule could not be evaluated rather
than record a zero for it. `--check-baseline [--rev REV]` (pre-push runs it for
each pushed commit carrying the file) counts that commit's tree and blocks on:

| Problem | Meaning | Fix the message gives |
|---|---|---|
| MALFORMED | not JSON, wrong `version`, a missing field, a non-positive count | fix the file or regenerate it |
| REGRESSION | a file's count rose above its ceiling | fix the new finding, or raise that ceiling in the same diff with a reason |
| UNRATCHETED | a count fell but the ceiling did not | the exact edit: `set rules.<rule>["<path>"] to N` or `delete …` |
| UNDECLARED | an enforced rule has findings and no entry | fix them, or declare the backlog with `--write-baseline` |
| STALE | an entry for a rule that is unknown or not enforced | delete the entry |

Ceilings are per file so that fixing a finding in one file cannot pay for a new
one in another. A `policy_revision` different from the scanner's prints a note
and the counts are still compared. Whole-tree counts (`--all [--rev REV]`, JSON
on stdout) are how a repo measures its backlog before adopting the register.

**Not enforced, by decision.** A general ban on `Optional`/`None` (about 16.7k
fleet lines; no source asks for it): only the error-path reading above
(`except_sentinel`) is enforced, and returning `None` for a genuinely absent value
remains fine. Dataclasses and TypedDict are allowed (vigil-oto CLAUDE.md:116-117).
`Literal[...]` stays at `warn` because vigil-ai-tpm recommends it. vigil-spark's
`py-no-except-empty-sentinel` exempts `return False` in predicates; the mandate
does not, so such a predicate records a `SAFETY:` suppression on the except line.

## Optional Windows Git SSH adapter

Install/build/test/run: first install a reviewed git-guard release using the
[normal versioned installer](../README.md#quick-start); no adapter build is needed.
Run `sh tests/run.sh windows_ssh_adapter windows_ssh_adapter_install` from a clone
to test the adapter. Then invoke the installed
[migration script](../tools/windows/install-git-ssh-wrapper.ps1) with PowerShell 7.1 or later:

```powershell
$adapter = Join-Path $HOME '.local/share/git-guard/current/tools/windows/install-git-ssh-wrapper.ps1'
& $adapter         # Read-only plan against the existing ~/bin wrapper pair
& $adapter -Apply  # Apply only after reviewing that installed release
```

This is an optional migration for existing wrapper consumers. It never writes
Git configuration, enables an unset `core.sshCommand`, changes the global hook
installer, registers a service, or starts an SSH connection. The source must be
an already-materialized release carrying `VERSION` and a full commit marker;
the marker identifies the release, and is not a cryptographic authenticity check.
The operator still obtains that release through the normal reviewed/tagged path.
The script refuses missing wrappers, links, an altered launcher, or JavaScript
other than the exact known legacy bytes or its own installed source bytes.
There is no general replacement of custom or older unrelated wrappers.

The [CMD launcher](../tools/windows/git-ssh-wrapper.cmd) is byte-identical to the
observed legacy launcher (SHA256
`A7C81A417092D46D2F4F56F57E36B679B15A451F6C0A44F973A66DAA96ED542B`).
The accepted legacy JavaScript SHA256 is
`46D2615192CB8EBAADBF2FA43DAB8B1C93FEFE79260F61FB8571FDBAFE7A2EF1`.
The script checks source syntax in a hidden, shell-free Node child with a 10s
execution limit, at most 1s for post-kill reaping and at most 1s for output drain,
before opening targets. Cleanup and pipe reads never use an unbounded wait.
It locks both existing wrapper files
against concurrent writers while validating the legacy pins, writes only the
existing JavaScript file and verifies readback. Its ACL survives an in-place
write. A caught write/readback failure restores known bytes from memory; there
are no redundant backup files. This does not claim atomic recovery from a host
power loss during that in-place write.

The [JavaScript adapter](../tools/windows/git-ssh-wrapper.js) preserves Git's
already encoded remote-shell command. A combined command passes through
unchanged; a split pack verb and encoded path fragment are joined verbatim with
one space. Quotes are never stripped or interpreted as local path decoration:
doing so splits spaced paths and can expose shell metacharacters. Other arguments,
inherited terminal streams and exit-code handling retain their existing behavior.
Its SSH child always requests `windowsHide:true`. This closes
a missing child-launch option; it does not establish that this wrapper caused
the fleet's reported Git Bash popups or hide a console created by its caller.
The option follows Node's
[child-process contract](https://nodejs.org/api/child_process.html#child_processspawnsynccommand-args-options).
Interactive calls retain prompts and have no added timeout or SSH options.
`CI` alone does not change this behavior.

Only the explicit value `GIT_TERMINAL_PROMPT=0` opts into `BatchMode=yes`,
`ConnectTimeout=15`, `ServerAliveInterval=30`, `ServerAliveCountMax=3`, and a
300000ms child timeout. Connect/keepalive values match the existing fleet SSH
[qualification](https://github.com/David-Martel/vigil-utils/blob/main/docs/fleet-ssh-performance-2026-07-30.md);
the 5min lifetime matches the existing automation budgets in
[clone_git](https://github.com/David-Martel/vigil-utils/blob/main/tools/merge-autopilot/autopilot.py)
and the explicit fetch in
[hygiene_report](https://github.com/David-Martel/vigil-utils/blob/main/tools/merge-autopilot/hygiene_report.py).
A caller can end the whole operation sooner as before. Unusually long
noninteractive transfers now fail after 5min, even if actively transferring;
this is a finite automation lifetime, not a claim that every repository fits it.
BatchMode suppresses authentication prompts. GUI callers that combine this
explicit trigger with an askpass dependency can fail fast and need assessment
before migration, even though interactive calls without the trigger are unchanged.
The installer adds no environment or timeout configuration steps.

The [category 33 tests](../tests/33-windows-ssh-adapter.t.sh) run through the
[canonical suite runner](../tests/run.sh), including its orphan guard. The Node
group executes real inert children for exact argument/exit propagation and a
finite timeout. It asserts the production 300000ms value, then shortens only the
test executable boundary to 80ms; a 1s self-exiting child bounds the RED control.
This qualifies timeout wiring without waiting 5min or opening an SSH session.
Two remote-command selectors also run real hidden POSIX shell probes, each
bounded to 2s. They replace only the fixed pack executable with the `set` builtin
and use inert `printf` to observe argument count and bytes. Six literal fixtures
cover spaces, semicolons, command substitutions, backticks, apostrophes and
backslashes/double quotes across all three pack verbs and both transport forms.
These probes parse the adapter's actual output; no SSH or Git server is started.
The installer group uses a temporary release and wrapper pair on native Windows,
with actual writes, ACL/readback/config preservation, idempotency, and rejection
controls. The exact private production lifecycle helper also runs a short
inert Node child: its timeout must terminate that child. The production drain
helper consumes real pending StreamReader tasks from a held local named pipe;
a 1.2s writer closure bounds the old unbounded-read RED control using .NET APIs
available on the installer's supported PowerShell versions.
The tests pass internal short wait budgets to these helpers; public installer
parameters and environment configuration are unchanged. Linux runs the Node group
and reports the Windows installer as skipped.
Neither group qualifies a physical SSH connection or an installed fleet rollout.
The tests do not inject a write/readback failure into the rollback path or qualify
all lock-acquisition ordering; those source paths are reviewed, not executed
fault qualifications.

### Adapter test review register

The two explicit selector groups below cover only category 33. Existing tests are
outside this new review scope. Independent reviewer `/root` (Codex; did not author
these tests) recorded KEEP on 2026-10-21 for the exact source snapshot committed as
[`c0123722dde76bcd9e77ec70ed0333e29c4c13b9`](https://github.com/David-Martel/git-guard/commit/c0123722dde76bcd9e77ec70ed0333e29c4c13b9).
The metadata author is `codex-gen9-runner-reliability`. Root's historical replay
`5ae4f5` covered installer SHA256
`BD25FEB9824A1859D42C648310D89FE86A4FAC5D6C58CB1636FEE4B133683A1F`.
Root then independently reviewed KEEP for the compatibility-only successor
[`eba7172d01d1f6fc598e826149bf391820cc5570`](https://github.com/David-Martel/git-guard/commit/eba7172d01d1f6fc598e826149bf391820cc5570):
disposable `SHA256.Create().ComputeHash(Stream)` replaces three stream calls,
because the official [.NET5 SHA256 source](https://github.com/dotnet/runtime/blob/v5.0.0/src/libraries/System.Security.Cryptography.Algorithms/src/System/Security/Cryptography/SHA256.cs)
has no `HashData(Stream)` overload. The [.NET5 HashAlgorithm source](https://github.com/dotnet/runtime/blob/v5.0.0/src/libraries/System.Security.Cryptography.Primitives/src/System/Security/Cryptography/HashAlgorithm.cs)
provides `ComputeHash(Stream)`. Historical replay `766663` covered installer
`9E01AC345BF4EFC0D1A8CC2704F10A79EC75874EF0BDD0BBC2FDB5C7FD214969`:
2 passed, 0 failed, 0 skipped in 2949ms on Windows with PowerShell 7.6.7.
This is an API compatibility correction, not an executed PowerShell 7.1 qualification.

The genuine outside-Claude review at `235e4848` returned
[REQUEST_CHANGES](https://github.com/David-Martel/git-guard/pull/80#issuecomment-6310319307)
for two test gaps: an inherited-only ACL fixture could miss recreate drift, and
a generic timeout-message match could accept failure to terminate the child.
That actual verdict remains historical; it is not converted into an approval.
The successor source
[`05c39b5181e4cdcfec0b512f3a9d35e8b39e9d06`](https://github.com/David-Martel/git-guard/commit/05c39b5181e4cdcfec0b512f3a9d35e8b39e9d06)
gives only the temporary fixture a protected explicit ACL and matches the exact
successful child-termination disposition. It also uses three-argument stream
writes and resolves native `node.exe` explicitly. Root independently reviewed
KEEP and actually replayed both groups in receipt `810cab`: 2 passed, 0 failed,
0 skipped in 3301ms, PowerShell 7.6.7. That historical replay covered JavaScript
`5A1E7889C812F38E409F15AB4166AE5607ABA42B8ACCAF293C9943E169CA6500`
and test file `64553C1BF70C5057E52213AAADB8C9855AB0EADFAFA0146E9D828468581516DE`.
The installer selector group and production installer remain byte-identical;
the quoting successor below needs its own review binding.

The autopilot's actual [current-head P1 review](https://github.com/David-Martel/git-guard/pull/80#issuecomment-6310497619)
at `f1c6d5ce` correctly identified unsafe apostrophe removal inherited from the
external legacy wrapper. It supersedes the earlier instruction to retain that
normalization. Two actual failing-first runs against unchanged `f1c6` production
source recorded four named failures and five passing controls: spaced paths split
into two arguments, and a quoted semicolon executed an inert `printf` in both
combined and split forms. Logs are `git-ssh-adapter-quoting-red.log` (SHA256
`BA57191C6EDB71B1016FB69ABC7F1898FA2689AB3CAB47A574409F386F53DAD7`)
and `git-ssh-adapter-quoting-metachar-red.log`
(`A1F2173843AD0D7E9DCBDF3A7BB347C9D2D2952CB45571025B6DDBD24A32BBFE`)
in the preparer's Windows TEMP directory.
The minimal successor removes combined-command rewriting and preserves the
encoded fragment when joining split commands. Preparer replay `ed8f9c` passed
both groups, 2 passed/0 failed/0 skipped on PowerShell 7.6.7; its log SHA256 is
`DF0EAC321E95A64858C9E23B6C8FD565C552B686388CCEFE2CC2382315BD56F3`.
The canonical Windows runner also emitted a post-suite temporary-directory
cleanup lock warning; this is disclosed separately from its test assertions and
exit code. The old head's now-green Linux CI does not qualify this successor.
Root independently reviewed the exact JavaScript/test delta and recorded KEEP
for the changed Node selectors. Actual independent replay `79ef3b` ran both
canonical groups through a hidden native shell on PowerShell 7.6.7: 2 passed,
0 failed, 0 skipped in 4581ms, exit 0, with all three production/test pins below
stable before and after. That independent run emitted no cleanup warning.
The metadata author is the preparer; Root did not author these tests.
Genuine outside-family review and current-head CI remain separate gates.

| Selectors | Protects / weakening permits | Reviewer / disposition |
| --- | --- | --- |
| `interactive_hides_without_restricting_prompt_or_lifetime`, `ci_alone_retains_interactive_options`, `explicit_noninteractive_has_existing_fleet_bounds`, `real_child_roundtrips_arguments_and_exit_status`, `split_pack_command_preserves_git_encoded_fragment`, `combined_remote_shell_paths_are_literal`, `split_remote_shell_paths_are_literal`, `real_child_timeout_is_finite_and_reports_failure`, `spawn_error_and_signal_do_not_become_success` | Child launch/argument/exit and remote-shell contract; weakening admits visible children, split paths, shell execution, broken interactive convenience or unbounded headless children. | Root independent review: KEEP; actual replay `79ef3b`; group SHA256 `7E9ECE45F8158E6B796F25E918C194E98FAFCCF809A5DD2C9B50D3A1524A7646`. Historical `810cab` covered the prior seven-selector group only. |
| `plan_only_retains_legacy_bytes`, `apply_promotes_validated_source_without_config_or_acl_change`, `idempotent_install_has_no_redundant_backup`, `unknown_launcher_is_preserved_and_refused`, `invalid_javascript_fails_before_target_writes`, `unknown_work_is_preserved_and_refused`, `invalid_release_marker_does_not_touch_targets`, `timeout_cleanup_terminates_real_owned_child`, `held_pipe_drain_is_bounded` | Opt-in migration and target preservation; weakening permits unknown-content replacement, configuration/ACL drift or unbounded validation cleanup. | Root independent review: KEEP; final replay `810cab`; group SHA256 `F2C84516919DC57C980A8CB05D7789AB6846C2530598F1DDF14C27FEA7A471FB`. |

Group hashes cover the exact UTF-8 source from each group's `Protects` comment
through the byte preceding the next group's comment (or EOF for the final group).
The full test file SHA256 is
`E6E340CC46ECDAC28587FE48DD90E0E1D5F6DEE7F68C648FCA306389C905660D`.
Raw and LF-normalized production SHA256 values are identical:

| Code under test | SHA256 |
| --- | --- |
| [JavaScript](../tools/windows/git-ssh-wrapper.js) | `27758C691F894F76EEFCFC59ED2939E90D15993682C872F1F464B0195B678183` |
| [Installer](../tools/windows/install-git-ssh-wrapper.ps1) | `65D496BED7B17A5C4FF25CA6F4170CF82AC3D391B70540634A4B545B7C20412E` |
| [Legacy launcher](../tools/windows/git-ssh-wrapper.cmd) | `A7C81A417092D46D2F4F56F57E36B679B15A451F6C0A44F973A66DAA96ED542B` |

The actual original-wrapper RED had four named Node failures and three passing
compatibility controls; an initial malformed legacy fixture was corrected before
counting that result. The final compatible held-pipe fixture also rejected an
isolated mutation removing only the finite drain: the old read waited 1218ms for
the writer closure and failed the expected finite-drain disposition. The earlier
Node-descendant inheritance experiment did not retain pipes on this Windows host
and is not counted as a valid RED control.
Two actual private follow-up controls qualify the new assertions: deleting and
recreating the installed fixture fails its protected SDDL comparison (receipt
SHA256 `A5D37C4577BE95FAB86B04A86CA1942C62C8FFDF327E1E38D85AF6E2097537F9`);
removing the child-kill call fails the exact successful-termination assertion
(`51C1552F833D611C9F1F219B372288EE509646D3C5905C545D93550CBB192C44`).
These controls change only private fixture/mutant files, never live ACLs or
canonical production source. The canonical successor passes both groups.

The broad Windows run reported 1040 passed, 43 failed and 39 skipped. A clean
baseline at `bf6258594973a404e93ad21b91cce66f715dd564` reran the three failing
groups: 241 passed, 43 failed and 4 skipped. Both have 16 quality-mandate failures,
24 native-link installer failures and 3 provider-dispatch failures. After fixture
path normalization, 42 failure labels match; one native installer failure appears
at a different cascading seed/reproduction stage. These are unresolved Windows
baseline failures, not a full-suite pass or a waiver. The broad run loaded the
earlier adapter test body; the final adapter snapshot is qualified by the focused
replays above and its own current-head CI. This register does not certify legacy
selectors, an SSH connection, or fleet deployment.

## Windows global configuration

The [native installer](../install.sh) uses
[set-hooks-config.ps1](../tools/windows/set-hooks-config.ps1) for Windows global
`core.hooksPath` publication. Windows installation requires PowerShell 7.1+,
Git Bash `cygpath`, and the existing symlink capability described in the
[README](../README.md). The helper does not require elevation; it refuses before
publication if the caller cannot preserve the existing owner, group and DACL.
The security fixture needs an elevated token only to create deliberately distinct
owner/group values. A missing fixture prerequisite produces an explicit skip.

An equivalent absolute hooks path with no missing requested defaults leaves the
config bytes, timestamp and security untouched. Otherwise native Git serializes
the payload inside a private staging
directory. The helper acquires Git's ordinary exclusive `.lock`, qualifies the
stage's owner/group/DACL, checks the captured preimage, and atomically replaces the
config. Its unpredictable sibling original stays in the original inheritance
context: moving that original into the private staging directory changes legacy
inheritance flags on Windows. Actual displaced bytes and descriptor must match
the captured preimage exactly before cleanup, including a second check immediately
before deletion. Unexpected displaced data is retained and the operation fails.
Validated successful transactions retain no original or staging copy.
The intended hooks value is recomputed from the captured serialized preimage
under the lock; an earlier global read cannot suppress a required update.

Windows can add `SE_DACL_AUTO_INHERITED` when assigning a stage descriptor or
publishing a replacement. At those copy boundaries only, the full returned binary
descriptor must be identical or differ solely by forward addition of that bit.
Owner, group, ACE order, opaque data, null versus empty DACL and all other flags
remain significant. The captured scope is owner/group/DACL from ordinary
`Get-Acl`; no privileged audit/SACL inspection is claimed or required. In-memory
represented-SACL controls protect the generic comparer from discarding fields
that are present. The displaced-original check permits no normalization.

Run the maintained controls through the [canonical suite](../tests/run.sh):

```sh
sh tests/run.sh install_native_links install_native_config_acl
```

The [category 27 fixture](../tests/27-install-native-links.t.sh) performs real
native Git serialization and actual temporary Windows file operations. The
legacy fixture clears AI only on its temporary parent with a test-only native
API; production has no obsolete API or post-publication ACL rewrite. Two exact
private source copies inject a real noncooperating edit immediately before the
actual replacement. This bounds and reproduces the race without a production
test switch, mock filesystem, timing sleeps or a live configuration write.
Hidden native children have finite execution and output-drain bounds. Normal
Windows installation runs the existing `hygiene.sh defaults` against the private
serialized global file in the same transaction; it does not duplicate the
defaults or write them individually to the live config. Only that child's
`GIT_CONFIG_GLOBAL` and native-tool PATH binding change. Choices read by the
unchanged defaults command remain authoritative; its native Git global-file
selection is preserved, rather than redefined by this publisher.
`--no-git-defaults` omits that call; Linux and dry-run behavior stay
unchanged. Uninstall configuration behavior is outside this review scope.

### Config publication review register

Metadata author: `codex-gen9-runner-reliability`. Independent reviewer
`rootcodex-gen9-fleet` (Codex; did not author this source or metadata) reviewed
the initial frozen source/test snapshot below and recorded APPROVE. The register
covers the two named category 27 groups;
other legacy suite selectors and fleet deployment are outside this review scope.

| Selectors / controls | Protects; weakening permits | Hash-bound review |
| --- | --- | --- |
| `t_case_install_native_links` | Existing native links, failure rollback and immutable releases; weakening can hide copied directories or loss of the previous installation. The only production-integration fixture change copies the maintained helper into the historical clone. | Root APPROVE; group `606085F527BEC0C006F746EFB65C4CF5577DC6E6C647E9A1B7E5ABFAC0976284`. |
| `unchanged-protected`, `unchanged-inherited` | Exact config bytes, modification time and owner/group/DACL; weakening permits gratuitous Git rewrites or descriptor loss on an already equivalent value. | Root APPROVE; config group binding below. |
| `changed-protected`, `changed-inherited`, `changed-legacy-no-ai` | Intended Git value, unrelated content, original security and successful transaction removal; weakening permits custom ACL loss or false refusal on a real legacy descriptor. | Root APPROVE; config group binding below. |
| `changed-xdg-only`, `absent-default`, `foreign-lock` | Supported global config routing, first creation and another writer's lock; weakening permits writes to the wrong file or deletion of foreign work. | Root APPROVE; config group binding below. |
| `default-missing`, `default-kept`, opt-out and private binding | Normal/default and repeated installation retain security and unchanged bytes/mtime; existing boolean, numeric and multi-value choices win; an actual child observation proves the maintained defaults use only the private global file. Weakening permits live defaults writes to recreate the same ACL bug. | Root APPROVE; config group binding below. |
| Binary descriptor controls | Exact/forward-AI positives; reverse AI, another flag, owner, group, ordered ACEs, opaque bytes, represented SACL and null-to-empty DACL negatives. Weakening permits unrelated security changes under an AI exception. | Root APPROVE; config group binding below. |
| Trailing-space/dot destinations | Refusal before normalization with canonical bytes/security and no stage/lock; weakening permits an ambiguous path to modify its canonical neighbor. | Root APPROVE; config group binding below. |
| Actual displaced bytes/descriptor races | Exact-source instrumented real replacement preserves unique displaced data and fails explicitly; weakening permits concurrent work to be deleted after a stale precheck. | Root APPROVE; config group binding below. |
| Cooperative pre-lock hooks change | A real native Git writer between the early read and lock acquisition cannot cause successful publication of stale hooksPath; weakening trusts an obsolete equality decision. | Root APPROVE; config group binding below. |
| Relative-include baseline equivalence | An actual `--includes` positive proves the relative fixture resolves; ordinary global reads at the original/private locations must agree, and included bytes stay untouched. Weakening can change the maintained defaults policy or hide a future Git include-default change. | Root APPROVE; config group binding below. |

Group hashes cover each complete function body, UTF-8/LF, trailing whitespace
removed followed by one LF. The config group SHA256 is
`C44390B031DE77541F1AF755824052C3F344760F2CFA21FA04177FB92142E8BB`.
Initial raw and LF-normalized production/test SHA256 values are identical;
the later dual-global test-only successor is bound separately below:

| Source | SHA256 |
| --- | --- |
| `install.sh` | `4F5EAAF555E4C59B34A010DC62DC397159FBEF504B517BE8CE3DC5B1719A6B8D` |
| `tools/windows/set-hooks-config.ps1` | `F2BFAC4EB591A58C073BE6459F8EEA7B14FC68AD196F45E9792B50F6FA408731` |
| `tests/27-install-native-links.t.sh` | `01A6575C8F8CF442A37461A711FA5743A2C4202F070D436D9EB4A047790F2053` |
| `tests/run.sh` | `EFB5FD149DDD59C89D66F3413D6C04ECC8A7384A8EE91B6A1D805581DC4E1627` |
| Unchanged `hooks/common/hygiene.sh` | `572362FE1B254A11FFA23F3A09A1C307B076C9BE60337379C8E0879EF7BCC848` |

The actual initial RED against the unchanged installer produced four descriptor
losses and two equivalent-path rewrite failures. Receipt SHA256:
`576BB9848CCD8C06D86E06306DB90E5E1B24DD24CE1AECC717A24B890762E337`.
The later controls were validated by an actual source mutation removing the
new displaced, ambiguous-path and AI defenses: 11 named failures, exit 1 in
18056ms, production restored byte-exact in `finally`; receipt
`20E334082FF82BAB98E832FDBB13BED38CC6031ECC57198481FA02A9AE165679`.
That is a mutation RED, not a claim that those controls preceded all new code.
The historical hooks-path-only snapshot passed 44 suite checks, 0 failed, 0 skipped in 40055ms
on Windows/PowerShell 7.6.7/.NET 10.0.13, source pins stable before/after, no
cleanup warning; receipt
`EDB0F0CC258B4E958E78DDA3180E01DF77073B4209615FA4B23AE02CF71DDE04`.
The later normal-default controls then reproduced two genuine descriptor losses
against that unchanged source, including already-canonical hooksPath; receipt
`45B88FB467E39464D8F15CBE731693D918DE3C89BF115DA84DA0148C66588759`.
The historical first integrated default-path successor passed both groups: 44 suite checks,
0 failed, 0 skipped in 43868ms, including 116 internal native assertions;
receipt `A3865692E94676A957D3B5A4DBA96972950AC93643F8099EB0E0CD7BE65CA3A8`.
Its source pins above were measured after that run, not retroactively recorded
as before/after pins. An initial direct-shell run inherited home tool shadows
and skipped; it is not counted as a RED or qualification. The qualified run uses
native Git tool directories before inherited PATH, matching the production
defaults child's binding. PowerShell parsing/PSScriptAnalyzer and ShellCheck
reported no findings.

Independent review then identified the pre-lock stale equality race. The new
actual cooperative-writer control reproduced one named failure before the fix,
receipt `F999984B23279AD46DFB10821D3C471CEFA09A3AEE30E14C2E1136FC561FF9E1`.
The pre-lock successor recomputes hooksPath from the captured file under lock and
names the actual sibling original in failure diagnostics. Both canonical groups
pass: 44 suite checks, 0 failed, 0 skipped in 49328ms, including 128 internal
native assertions and absent-config normal-default installation. All five source
pins above are stable before and after; no cleanup warning was emitted. Receipt:
`2E556F4430517E47CF624F81EADAEC17DF0769A33D0A1A6743564ACD2D7ACE86`.
PSScriptAnalyzer, ShellCheck and whitespace checks are clean for this snapshot.
This is not an executed PowerShell 7.1 qualification.

A subsequent relative-include concern was withdrawn after actual native Git
2.55.0.windows.5 controls showed ordinary `--global` and `--file` reads both
exclude includes, while explicit `--includes` resolves the fixture. The installed
Git manual documents this specific-file default. Production semantics and the
private directory remain unchanged. The final maintained control compares actual
original/private ordinary-read exit codes and output instead of making includes
OFF a future policy. Final exact-source replay passed 44 suite checks, 0 failed,
0 skipped in 49889ms, including 131 internal assertions; all five pins were stable
before/after and no cleanup warning was emitted. Receipt:
`A028DC7F19803E6B54FE221FC692BF3757CB06C83F90F08ED1C1C09B185B4FD8`.

The hooks-path-only broad Windows attempt reached its 600000ms harness bound
before completion. The owned test tree was terminated; the original harness did
not retain partial stdout/stderr. Timeout receipt:
`6D0ECA864C6D54D6683EBF51536313E6C1CEC396026252E70AB9973676301814`.
The prior full Windows log took approximately 930s, so that incomplete run
cannot classify current baseline failures or establish a full-suite pass.
The shared Markdown link check examined seven files with zero broken links or
anchor warnings. Its test-rationale scanner discovered zero `t_case_*` selectors
and failed its zero-files guard; no automated rationale coverage is claimed.
The named controls above require actual independent review against their hash.

The first combined run's 24 native-link failures came from absent historical
objects in this partial clone, before the unchanged v0.2.7 seed installer could
run. Bounded hydration of only v0.2.7/v0.2.8 restored the missing tree/blob;
the clone configuration was byte-identical afterward. Hydration receipt:
`32FFE1B2425DF216D91A4DF66012CA2269557C4934C07C08E89C21B38DB37039`.
The successor actually passes the 43 legacy checks plus the new aggregate group.
The earlier adapter register's Windows baseline is historical, not a current
classification of these resolved historical-object failures.

Root independently replayed the two maintained groups at these exact five pins
in actual run `d2fabc`: 44 passed, 0 failed, 0 skipped, including 131 internal
assertions, 48862ms, no cleanup warning. Source pins were stable and the real
global config bytes and SDDL were unchanged. Independent receipt SHA256:
`784B18228272934CD4379FF8F8A87688ED201654CDF33F03ABD3C9E6996B5D30`.
The outside-family review, current-head CI, full Windows suite disposition and
supported tagged fleet rollout remain separate gates; this source/selector
approval does not certify them.

The final full Windows run completed in 909048ms: 1056 passed, 28 failed,
39 skipped, exit 1, no timeout. Receipt SHA256:
`642A3B92092FA9DD35BB75ACBAF7D6F81B16373D028D114A40AC92EB99D66B66`.
Nineteen failure labels match the original baseline log byte-for-byte, without
normalization: 16 quality-mandate and three provider-dispatch failures. The
original log SHA256 is
`25A6FAD22F527F3CB641E7D848F5E2A6D6C1F0C653703491DD5B080A9E2CE9DB`;
the exact comparison receipt is
`A1F31B57CBD0207D02D3D726A52BA51137A73C77760C080E1FB9204178FCE269`.
The old 24 native-link failures no longer occur.

Nine additional labels occurred in the direct native-shell caller: seven
configured-lefthook and two stale-branch controls. Under the original Git
`bin/sh.exe` launcher with identical inherited environments, selected downstream
and hygiene tests passed 109/0/6 on both baseline and current source. All 145
baseline archive files were authenticated against the original
`bf6258594973a404e93ad21b91cce66f715dd564` Git blobs, with no extra overlay files;
the archive is not described as a clean Git checkout. Binding receipt:
`66B67F4F308103F04C4DB9AFB9843B45ABEE28F373309C8C69AF300C94B5C761`.
Paired replay receipt:
`A69E252418DC05800A7E91B6AC440786652BE45C4307CABEF1EBAD80B9A1D9AC`.
All 145 archive files were unchanged afterward; postcheck:
`D3CA7FF3E055DF06FCB9238B1452F17693A0C51FFDBB6C48E284B0E29CAA662C`.

One bounded real precommit/stale-branch fixture varied only `MSYSTEM`. The inert
precommit hook ran and refused in both contexts, and its unhooked positive
committed in both. With `MSYSTEM` unset, the stale-branch push succeeded and
reached the remote; with `MINGW64`, it was correctly refused. This establishes
the two stale labels' caller dependence, not a general hook-dispatch failure or
the cause of all seven lefthook labels. Receipt:
`C2329E77670267A80F7C0140091DF41777B185CF6CAEAD1E7A10BAE4BEFA57F5`.
These are disclosed local limitations, not a full Windows pass or weakened
assertions. The installer source and selected tests remained frozen throughout
the full run and paired controls; both required current-head CI jobs passed.
The stale-branch fail-open can matter to native PowerShell callers, where
`MSYSTEM` is commonly unset. It is a separate real reliability follow-up; this
ACL qualification is not general acceptance of Windows fleet hygiene.

### Dual-global review successor

The genuine autopilot Claude review of `ceb1148bbc104b467b2042f74638e7b114df6469`
requested changes because it inferred that staging only the home file newly
ignored XDG choices. The finding was verified against actual native Git before
changing production. The qualified runtime is Git `2.55.0.windows.5`, PowerShell
7.6.7 and .NET 10.0.13. With both real global files present, native
`git config --global --get fetch.prune` returned 1 when the home file lacked the
key, and `--global --show-origin --list` showed only the home file. In the same
inert directory/environment, `git config --show-origin --get fetch.prune`
returned the XDG choice. Home precedence and explicit-global isolation also
passed their positive controls. This distinction matters because the unchanged
maintained defaults use `--global`; a normal all-scope read is not their baseline.
The [Git documentation](https://git-scm.com/docs/git-config) describes both global
files, so the test records actual command equivalence rather than declaring the
observed one-file selection a permanent policy.

The first new controls used a POSIX HOME for native Git launched directly from
PowerShell, overlooking MSYS's child-environment translation. That fixture error
was corrected before interpreting the result. The subsequent scope capture is
receipt `E0E9F76CB4F3AC9A6034D5A7DD4548DFDD4D543C8F708EACBBF5D91E020C81FC`.
Its failed expectations assumed both files participated in `--global`; they are
not an installer-regression RED. No production source changed in this successor.

The maintained dual-file controls now execute the unchanged `hygiene.sh defaults`
directly against a private duplicate with the original HOME/XDG/global binding.
They compare its actual exit codes, all six default-key outputs and ordered Git
serialization with the publisher's result. Real all-scope origins prove that
both files are functional; multi-value order, a literal `~/` value, home choice,
explicit override and explicit empty-override refusal are detecting controls.
The XDG bytes and descriptor must remain unchanged, and repeated installation
must not rewrite the resulting home config. A runtime whose global selection
differs must still produce equivalent original/publisher results; the test does
not hardcode that XDG is always excluded. This preserves baseline behavior and
does not certify all global-file semantics or resolve a pre-existing Git/defaults
policy concern.

The actual maintained config group passed 1 aggregate check, 0 failed, 0 skipped,
including 190 inner native assertions, in 41534ms. All five source pins stayed
unchanged, with no cleanup warning. Receipt SHA256:
`56226BC8BBB259EADFC9E9125300CDE630F9768E9CFAAAC482B79D31A89F7FCC`.
The successor test-file raw/LF SHA256 is
`203750E10C332A8660135E1BC6032C467856864D38EB74DE7FD7B81525264002`;
config-group SHA256 is
`E4098BA785DBC92885097B1E9DD07E780CE3468CAAE50D51D74583F24575B5B1`.
The legacy group and all production/runner pins above are unchanged.

| Successor controls | Protects; weakening permits | Hash-bound review |
| --- | --- | --- |
| `default-dual-xdg`, `default-dual-home-wins`, `default-explicit-over-xdg`, `empty-global-refused` | Original defaults read/write semantics, functional XDG/home origins, ordered multi-values, literal tilde, explicit override isolation/refusal and repeat-install identity. Requires actual native Git, Windows and the fixture token described above. Weakening can invent a regression from a different Git scope, hide an actual selection regression or mutate operator XDG data. | Root component APPROVE; test `203750E10C332A8660135E1BC6032C467856864D38EB74DE7FD7B81525264002`, config group `E4098BA785DBC92885097B1E9DD07E780CE3468CAAE50D51D74583F24575B5B1`. |

Independent reviewer `rootcodex-gen9-fleet` read the complete test-only diff and
successor documentation, then actually replayed the canonical config group in
41505ms: 1 aggregate passed, 0 failed, 0 skipped and 190 inner native assertions
passed. All five source pins were stable, and the real global config bytes and
SDDL stayed unchanged. Root recorded component APPROVE for this exact test/group
binding; no production source changed. Independent receipt SHA256:
`42CE2E0084A0DBDFABE1D56F575AA08A54679E3D97A4E0E5C774D0D6848D34A4`.
Normal new-head CI and full-PR autopilot disposition remain pending. Neither
component approval is relabeled as an outside-family or full-PR approval, and
the broader Windows run above remains 1056/28/39 with its stated limitations.
