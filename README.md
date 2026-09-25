# git-guard

**Account-wide git-safety + language-gated commit QA — one engine, every repo, never bricks a commit.**

git-guard is a small, dependency-light set of POSIX-`sh` git hooks that compose a
*safety* layer (secret scanning, reserved-filename hygiene, landed-commit
feedback, branch & partial-staging warnings) with a *language-gated quality* gate
(ast-grep structural rules, `ruff`, `shellcheck`, JSON validation, …). It is
designed to run **globally across dozens of repos at once** without blocking
work-in-progress, by following a strict anti-brick policy: **block only on real,
fast, near-zero-false-positive errors; warn on everything else.**

It works on Git-Bash (Windows), WSL, Linux, and macOS, and is **severable**: it
ships standalone with a bundled example rule set, and optionally overlays a
larger private rule corpus on machines that have one.

---

## Why

Two recurring failure modes motivated this:

1. **Lost work from unsafe git recovery.** Chaining `git reset --hard` after a
   commit that *silently failed a pre-commit hook* permanently destroys
   `git add`-ed-but-uncommitted work. git-guard makes commit success/failure
   **un-missable** (post-commit prints the landed SHA; a blocked commit prints an
   explicit "STAGED but UNCOMMITTED — do NOT reset --hard" message). See
   [`docs/GIT_COMMIT_SAFETY.md`](docs/GIT_COMMIT_SAFETY.md).
2. **No QA on "naked" repos.** Most repos have no pre-commit tooling at all. A
   single global hook path gives every repo a baseline of secret-scanning and
   fast structural linting — *without* forcing a heavy, slow, false-positive-prone
   gate onto work-in-progress.

## The anti-brick policy

A check may **BLOCK** a commit only if **(a)** its tool is present, **and**
**(b)** the repo is actually configured for it *or* the check is
near-zero-false-positive, **and** **(c)** it is fast. Otherwise it **WARNs** and
the commit proceeds. This is what makes it safe to enable account-wide. Any repo
can soften or disable any check with a per-repo `.qa-gate.conf`.

| Layer | Default | Notes |
| --- | --- | --- |
| Secret scan (added lines) | **block** | generic high-entropy / known-token patterns |
| Reserved-filename (NUL/CON/…) cleanup | **block** | filesystem hygiene, PII-safe |
| ast-grep BLOCK trio (`avoid-static-mut`, `no-glob-reexport`, `unsafe-with-panic`) | **block** | narrow, high-signal |
| `shellcheck` (staged `*.sh`) | **block** | fast, high-signal |
| `ruff check` (staged `*.py`) | **block** | repo config if present, else minimal `E,F` |
| JSON parse (staged `*.json`) | **block** | cheap, real |
| ast-grep (everything else), `ruff format`, `cargo fmt`, `clippy`, `mypy`, panic-set, large-file | **warn** / opt-in | never blocks WIP by default; Python type checks honor configured project scope |

Full schema, precedence, and the rule catalog: [`docs/QA_TOOLING.md`](docs/QA_TOOLING.md).

## Quick start

```sh
git clone https://github.com/<owner>/git-guard ~/git-guard
sh ~/git-guard/install.sh                 # materializes v<VERSION> into
                                           #   ~/.local/share/git-guard/, symlinks
                                           #   ~/.git-hooks -> .../current/hooks,
                                           #   sets core.hooksPath
sh ~/git-guard/bin/git-guard status       # confirm (shows the installed version)
sh ~/git-guard/bin/git-guard verify       # self-test: trio blocks, clean commit passes
```

**Hooks are installed from an immutable, versioned copy, not the live
checkout.** `install.sh` (with no `--to`) materializes `v<VERSION>` (the tag
matching this checkout's own `VERSION` file — it must exist; cut it with
`git tag v<VERSION>` first if it doesn't) via `git archive` into
`~/.local/share/git-guard/<tag>/`, then atomically points
`~/.local/share/git-guard/current` at it and `~/.git-hooks` through `current`.
Because the archive is a snapshot of the TAGGED commit, **a later `git
checkout`/`git pull`/WIP edit in this checkout has no effect on any installed
hook** — that used to be the failure mode (`~/.git-hooks` was a symlink
straight into the live working tree). To move every consuming repo onto a new
release at once, cut a new tag and run:

```sh
sh ~/git-guard/bin/git-guard update --to v<NEW-VERSION>
```

which materializes the new tag and flips `current` in one atomic rename — no
commit, anywhere, ever observes a half-installed hook set (`hooks/pre-commit`
resolves its own directory physically, once, at entry, so an in-flight commit
stays pinned to whichever version it started with even if `update` runs while
it's paused mid-invocation). `update --to <tag>` must be run from an actual
git-guard git checkout (e.g. `~/dev/repos/git-guard`), not from an already-
installed archive — running it from `~/.local/share/git-guard/current/bin/
git-guard` fails with a clear error explaining why and how to fix it.

`install.sh` is **idempotent and reversible** (`install.sh --uninstall` restores
the prior state from an automatic backup; materialized versions under the store
are left in place). It is intentionally *not* auto-run on clone — the
global-hooks change is deliberate.

For git-guard's OWN development loop (iterating on `hooks/`/`qa_gate.sh` and
wanting immediate effect without a tag+install round-trip), opt back into the
pre-versioned behavior explicitly: `sh ~/git-guard/install.sh --dev-symlink`
symlinks `~/.git-hooks` straight at this checkout, same as before. Never use
this on a host whose other repos you don't want re-hooked on every branch
switch here — that is exactly the footgun the default now closes.

An emergency human bypass is unchanged: `GIT_GUARD=0 git commit …` skips the
hooks for one commit, regardless of install mode.

### Use a private rule overlay

git-guard ships a curated **example** rule set in `rules-examples/`. To overlay a
larger private corpus on this machine (without touching the public-safe committed
config):

```sh
sh ~/git-guard/install.sh --rules-dir /path/to/private/rules
```

In the default (versioned) mode this writes `rules_dir=…` into a **persistent**
overlay at `~/.local/share/git-guard/qa-gate.conf.local` (outside any version
dir, so it survives every future `update --to`) and copies it into the
just-installed version immediately. Under `--dev-symlink` it writes straight
into the live checkout's **gitignored** `hooks/common/qa-gate.conf.local`, as
before. Resolution precedence: `$GIT_GUARD_RULES_DIR` env → `rules_dir` conf
key → bundled `rules-examples/`.

## CLI

```
git-guard status     install state (this checkout AND what's actually installed), resolved rules dir
git-guard doctor     prerequisite check (git, ast-grep, shellcheck, ruff, cygpath…) + installed version
git-guard rules      rule manifest (categories, counts, the BLOCK trio)
git-guard verify     self-test (BLOCK trio fires, clean commit passes)
git-guard install    materialize + install a versioned release (delegates to install.sh;
                      default --to v$(cat VERSION); accepts --to/--store/--rules-dir/--dev-symlink)
git-guard update      --to <tag>  re-point the installed `current` release at another tag (atomic)
git-guard uninstall   remove hooks (delegates to install.sh --uninstall)
```

## Per-repo overrides

Drop a `.qa-gate.conf` (or `.git-guard/qa-gate.conf`) at a repo root to override
any default — e.g. a sensitive repo that wants only NUL + secret scanning:

```ini
astgrep=off
python.ruff_check=off
shell.shellcheck=off
# secret scan + nul cleanup still run (they live in the hook, not the gate)
```

A malformed line (no `=`, an empty key) or an unrecognized key (a typo, or a
name from a different tool) **blocks the commit**, naming the exact
`file:line` and, for an unrecognized key, every valid key — see
[`docs/QA_TOOLING.md`](docs/QA_TOOLING.md) §5. Both used to be silently
ignored, which is how a repo can carry an override that has done nothing for
weeks with no output anywhere.

## Layout

```
git-guard/
├── hooks/                 drop-in for a global core.hooksPath
│   ├── pre-commit         compose: secret-scan → nul → qa_gate → warnings → downstream
│   ├── prepare-commit-msg deterministic Codex attribution trailers
│   ├── post-commit        landed-SHA feedback (verify before any reset)
│   ├── pre-push           optional downstream chaining
│   └── common/            the engine
│       ├── qa_gate.sh         language-gated, configurable QA gate
│       ├── secret_scan.sh     added-lines secret scanner
│       ├── nul-cleanup.{sh,ps1}  reserved-filename hygiene
│       ├── qa-gate.conf       global defaults (block|warn|off per check)
│       └── qa-sgconfig.yml    ast-grep rule-category reference
├── rules-examples/        curated, public example ast-grep rules (incl. the BLOCK trio)
├── bin/git-guard          the CLI
├── install.sh             idempotent, reversible installer (symlinks + overlay)
├── branch-protection.sh   optional GitHub ruleset applier
├── docs/                  QA_TOOLING.md, GIT_COMMIT_SAFETY.md
└── .github/workflows/qa.yml   Manual self-hosted QA: git-guard self-tests itself
```

## Requirements

`git` and a POSIX `sh`. Everything else is **optional** and self-skips when
absent: [`ast-grep`](https://ast-grep.github.io/) (structural rules),
`shellcheck`, `ruff`, `python`, `pwsh`, `dotnet`, `cargo`. On Git-Bash/MSYS,
`cygpath` is used to hand native paths to ast-grep.

## Containerized / cross-backend runs

`bin/git-guard-run` runs the gate or self-test through the best available
backend, falling through automatically: **Docker → WSL → native shell**. This
lets a "naked" machine (or CI) run the QA toolchain without installing
`ast-grep`/`shellcheck`/`ruff` locally — the Docker image (`docker/Dockerfile`)
carries the pinned toolchain.

```sh
sh bin/git-guard-run verify              # self-test via best backend
sh bin/git-guard-run gate /path/to/repo  # run the gate against a repo's staged files
```

**Backend knobs** (env vars):

| Var | Effect |
| --- | --- |
| `GIT_GUARD_BACKEND` | force `docker` \| `wsl` \| `native` (skips auto-detection) |
| `GIT_GUARD_RULES_DIR` | overlay a private rules dir (mounted `:ro` at `/rules` for Docker) |
| `GIT_GUARD_IMAGE` | Docker image tag to build/use (default `git-guard:local`) |
| `GIT_GUARD_AGENT` | explicit commit agent (`codex` enables Codex attribution) |

The `prepare-commit-msg` hook also detects Codex through `CODEX_THREAD_ID` and
adds `Agent: codex` plus Codex's stable `noreply` co-author trailer. Existing
matching trailers are not duplicated, and a conflicting `Agent:` trailer blocks
the commit. `GIT_GUARD=0` is the hook's explicit emergency-human bypass; routine
agent work must not use it.

Post-commit chaining selects the first runnable hook from
`GIT_GUARD_DOWNSTREAM_POST_COMMIT`, repository `.git-guard/post-commit.local`,
then the Git path setting `gitGuard.downstreamPostCommit`. The setting can be
repository-local or global; use an absolute executable path. Arguments are
forwarded unchanged, and downstream failures remain non-fatal.

Auto-detection: Docker is used when `docker info` succeeds; otherwise on Windows
WSL is tried (`wsl.exe bash …`); otherwise the local POSIX shell runs it. The
chosen backend is printed to stderr. Build the image directly with
`docker build -t git-guard:local -f docker/Dockerfile .`.

Manual self-hosted QA (`.github/workflows/qa.yml`) runs the SAME image in `self-test-docker` and
keeps a `self-test-native` fallback job with the identical assertions.

## License

MIT — see [`LICENSE`](LICENSE).
