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
