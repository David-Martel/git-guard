# git-guard — Severable, Publicly-Shareable Architecture & Rollout Plan

> Status: **interim-versioned inside dtm-claude**, structured for clean extraction
> to a standalone public repo. The live machine's global hooks are **untouched**
> by this pass (the real→symlink flip is a deliberate, deferred install step).
>
> Supersedes the migration direction in `~/.agents/VIGIL_PARTITION_PLAN.md` §3
> ("git-guard as a dtm-claude subtree"). The subsystem-A/B partition framing in
> that document still stands; only the *home* of the engine changed: from "a
> subtree coupled to dtm-claude" to "a severable unit extractable to a public
> repo, referenced by dtm-claude via symlinks."

## 1. Rationale — why severable + public

The QA/git-safety engine began life embedded in the private `dtm-claude` agent
configuration, hard-wired to `~/.claude/rules`. Three problems with leaving it
there:

1. **Reusability.** The engine is generally useful (any developer, any repo) but
   was trapped behind a private, identity-specific config repo. A standalone repo
   lets it be cloned and used without pulling in unrelated agent infrastructure.
2. **Reviewability.** Git-safety + commit-blocking tooling earns more trust when
   it is *independently visible* — readable hooks, example rules, a CI that
   self-tests, and a clear anti-brick policy — rather than buried in a personal
   dotfiles monorepo.
3. **Clean separation of public vs private.** The *engine* and a *curated example
   rule set* are public-safe. The *full private rule corpus* (identity- and
   project-specific guidance) should stay private. Coupling them in one tree
   forces an all-or-nothing visibility decision.

**Design answer:** make the engine **severable** — zero hard dependency on
dtm-claude internals — and have the private machine overlay its corpus via
configuration, not code. The public repo ships bundled examples; private machines
point `rules_dir` at their corpus. dtm-claude (and other machines) keep their
local config by **symlinking** into the versioned source, so nothing is lost.

## 2. The severability mechanism (what makes it standalone)

| Coupling removed | Before | After (severable) |
| --- | --- | --- |
| Rules directory | `QA_RULES_DIR="${HOME}/.claude/rules"` hardcoded in `qa_gate.sh` | `$GIT_GUARD_RULES_DIR` env → `rules_dir` conf key → **bundled `rules-examples/`**. No private path in the engine. |
| ast-grep config | static sgconfig with machine-absolute `C:/Users/.../qa-rules` paths | **generated at runtime** with `cygpath`-converted absolute ruleDirs from the local cache — portable + CWD-correct. |
| NUL accelerator | a hardcoded personal `NukeNul.exe` path | `$NUKENUL_BIN` (optional); pure-POSIX shell fallback is the universal default. |
| Downstream hooks | David's npx-lefthook path baked into `pre-commit` | generic `lefthook`-in-PATH detection + `GIT_GUARD_DOWNSTREAM_*` / `.git-guard/*.local` chaining. |
| Docs | `~/.agents/*.md` | live in `docs/`; `~/.agents/*` become **symlinks** back into the repo. |
| Private corpus overlay | implicit | explicit, gitignored `qa-gate.conf.local` written by `install.sh --rules-dir`. The committed `qa-gate.conf` stays public-safe. |

**Behavior-preservation contract:** on a machine that points `rules_dir` at the
full private corpus, the gate behaves exactly as the embedded engine did (same
rules → same validated cache → same block/warn decisions). On a fresh public
clone with no overlay, it falls back to the curated `rules-examples/`.

## 3. Symlink topology (original config preserved)

`install.sh` makes the versioned repo the single source of truth while preserving
every machine's existing setup (each original is backed up once, reversibly):

```
~/.git-hooks                 ->  <git-guard>/hooks
core.hooksPath (global)      ->  ~/.git-hooks
~/.agents/QA_TOOLING.md      ->  <git-guard>/docs/QA_TOOLING.md
~/.agents/GIT_COMMIT_SAFETY.md -> <git-guard>/docs/GIT_COMMIT_SAFETY.md
qa-gate.conf.local (gitignored, per-machine)  ->  rules_dir = <private corpus>
```

Reverting is `install.sh --uninstall` (restores the `*.pre-git-guard-backup`).

## 4. Staged rollout — the exercise

### Stage 0 — Versioned inside dtm-claude (THIS pass) ✅
- `git-guard/` lives in dtm-claude, **self-contained** and extraction-ready.
- Engine decoupled (§2); curated `rules-examples/` (20 rules incl. the BLOCK
  trio); README/LICENSE/.gitignore/CLI/install.sh/CI/branch-protection.sh; docs.
- **Verified:** decoupled rules-dir resolves to bundled examples; the BLOCK trio
  fires (exit 1) and a clean commit passes (exit 0) against `rules-examples/`.
- **Deferred:** the live `~/.git-hooks` real→symlink flip (sensitive; needs
  explicit go). The live engine keeps running unchanged until then.
- Committed via verified branch→PR (dtm-claude is branch-protected).

### Stage 1 — Extract to a public repo `David-Martel/git-guard`
- `git subtree split -P git-guard -b git-guard-split` → push to a fresh public
  repo (preserves the git-guard commit history only). Alternatively a clean
  `git init` import if history isn't needed.
- dtm-claude then references it as a **submodule** (or a bootstrap-time clone),
  and `~/.git-hooks` symlinks into that checkout. Decision recorded at extraction
  time (submodule = pinned + explicit; bootstrap-clone = looser + simpler).

### Stage 2 — Branch protection + CI on the public repo
- Run `branch-protection.sh David-Martel/git-guard --require-check "git-guard QA / self-test"`:
  PR-only, required signatures, no force-push, required CI check, 0 approvals
  (self-merge) initially.
- `.github/workflows/qa.yml` already self-tests the gate on every PR.

### Stage 3 — Private-rules overlay on each machine
- `install.sh --rules-dir ~/.claude/rules` (or wherever the corpus lives) →
  writes the gitignored `qa-gate.conf.local`. Public clone stays example-only.

### Stage 4 — Multi-machine deploy via bootstrap
- dtm-claude's `bootstrap.sh` gains an **opt-in** step: if `git-guard/` is present
  (submodule/clone), offer `git-guard/install.sh`. Kept opt-in because it mutates
  global git config (no silent account-wide hook changes on bootstrap).

### Stage 5 — Backfill local-`hooksPath`-override repos
- Repos that set `core.hooksPath=.githooks` (e.g. intublade) bypass the global
  chain. Each gets a one-line `.githooks/pre-commit` that calls
  `~/.git-hooks/common/qa_gate.sh` — a per-repo PR, not part of this rollout.

### Stage 6 — Subsystem B (heavy, opt-in) — future
- Per `VIGIL_PARTITION_PLAN.md`: the heavy language test runner / 6-phase
  pipeline stays a *separate, opt-in* concern gated behind a per-repo marker.
  git-guard (subsystem A) is the always-on, low-friction layer; B is not part of
  the public severable core unless explicitly added later.

## 5. Risks & mitigations

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Real→symlink flip of live `~/.git-hooks` bricks git across repos | HIGH | Deferred to a deliberate `install.sh` run; automatic backup; `--uninstall` restores; the flip is the *only* sensitive step and is isolated. |
| Public clone behaves differently than the embedded engine | MEDIUM | Behavior-preservation contract (§2): overlay `rules_dir` → identical decisions; CI self-test proves the trio + clean-pass. |
| Private rule corpus leaks into the public repo | MEDIUM | Only a **curated** `rules-examples/` is committed; the full corpus stays a gitignored/overlay concern; `qa-gate.conf.local` is gitignored. |
| Lost host-specific hooks (lefthook tail) after symlinking | MEDIUM | git-guard chains downstream hooks (`GIT_GUARD_DOWNSTREAM_*` / `.git-guard/*.local` / `lefthook` in PATH); the backup preserves the originals. |
| Generated ast-grep paths wrong on a platform | MEDIUM | `cygpath -m` on MSYS, pass-through on Linux/macOS; CI runs the self-test on Linux. |

## 6. Reference

- Engine: `hooks/common/qa_gate.sh` · `secret_scan.sh` · `nul-cleanup.{sh,ps1}`
- Config schema + rule catalog: `docs/QA_TOOLING.md`
- Git-safety doctrine: `docs/GIT_COMMIT_SAFETY.md`
- A/B partition history: `~/.agents/VIGIL_PARTITION_PLAN.md` (subsystem B + governance)
