# Fleet rollout: proving a host is covered

git-guard only protects a push when its hooks run on the host and in the repo
that pushes. This page is the per-host procedure, how to prove the result, and
what no client-side check can do.

Why this page exists (2026-11-05):

- A branch was pushed from a WSL distro (dtm-work, Ubuntu-22.04) that had no
  git-guard and no `core.hooksPath`. It merged without any hook having run
  (vigil-utils #1403).
- Carbon's `~/.git-hooks` was a stale real directory from an old release, and
  `install.sh` refused to replace it because a backup already existed.
- Pushes from a bare scratch repository failed with a misleading provider
  message.

## 1. Install

From a git-guard clone on the host (any platform):

```sh
git fetch --tags
sh install.sh --to v<version>          # or: sh bin/git-guard update --to v<version>
```

- On Git Bash for Windows the installer needs native symlinks (Developer Mode or
  the symlink privilege) and PowerShell 7. It refuses rather than copy.
- A real (non-link) `~/.git-hooks` is moved aside, never deleted. It goes to
  `~/.git-hooks.pre-git-guard-backup`, or, when that already exists, to
  `~/.git-hooks.pre-git-guard-backup.<UTC timestamp>`. If a Windows install
  fails after the move, the same copy is moved back. `--uninstall` restores only
  the plain `.pre-git-guard-backup`; timestamped backups stay for you to review.

## 2. Check the host

```sh
git-guard doctor --require-installed --repo <repo> [--repo <repo> ...]
git-guard doctor --require-installed --wsl            # Windows hosts with WSL
```

The last line is the verdict: `git-guard doctor: COVERED`, or
`git-guard doctor: NOT COVERED (n failures)` with a non-zero exit. Without
`--require-installed`, an unset hooks path is reported but is not a failure,
so CI can run `doctor` on an uninstalled checkout.

| Check | Fails when |
|---|---|
| `hooks-path` | global/system `core.hooksPath` is unset (with `--require-installed`), dangling, or lacks an executable `pre-commit`, `pre-push`, `common/secret_scan.sh`, `common/nul-cleanup.sh` or `common/qa_gate.sh` (the hooks skip an engine that is not executable); a shipped `commit-msg`/`prepare-commit-msg` must be executable too |
| `hooks-bypass` | `GIT_GUARD=0` or `LEFTHOOK=0` is set in the environment doctor runs in: every hook exits at once |
| `timeout` | `timeout -k 1 5 sh -c :` fails, because `timeout(1)` is missing or rejects `-k` (stock macOS has none). The pre-push mandate (every platform) and the POSIX identity query (#119) need it, and each push would be refused with a TOOL ERROR. Fix: GNU or uutils coreutils, or on macOS `brew install coreutils` with its `timeout` on PATH. This is checked with and without `--require-installed`, so run doctor on each host before rolling out a release |
| `hooks-version` | the hooks dir has no git-guard `VERSION` beside it: a stale legacy copy (FAIL with `--require-installed`, warning otherwise) |
| `repo-hooks` (`--repo`) | the repo's effective hooks dir is not git-guard's and its `pre-commit`/`pre-push` are not executable hooks that call git-guard (git ignores a hook that is not executable) |
| `provider` (`--repo`) | the provider each hook would select is not runnable. Selection follows the hooks: `GIT_GUARD_DOWNSTREAM_HOOK` / `GIT_GUARD_DOWNSTREAM_PRE_PUSH`, then an executable `.git-guard/<hook>.local`, then a lefthook config, then `.pre-commit-config.yaml` (a regular file; at pre-push not a symlink; `pre-commit` a runnable file). Providers later in that order never run and are not required |
| `pyyaml` (`--repo`) | the interpreter the gate selects (`hooks/common/qa_python.sh`: `python`, else `python3`) cannot import `yaml` (warning; FAIL with `--strict`) |
| `wsl` (`--wsl`) | a running distro has no global `core.hooksPath`, or its hooks dir fails the same check as `hooks-path` (one shared probe); no `VERSION` beside it is a warning (FAIL with `--require-installed`) |

`--strict` turns every coverage warning into a failure.

### Repo-local hooks paths

A repo-local `core.hooksPath` (vigil-utils and eight repos on Gen7 use
`.githooks`) overrides the global one, so git-guard runs there only if that
repo's own hooks call it. `doctor --repo` prints the effective value and where
it comes from (`git config --show-scope --show-origin`). A local hooks dir whose
`pre-commit` and `pre-push` mention `git-guard` or `.git-hooks` is a warning
(the delegation is not run to prove it); one that does not is a failure.

### WSL distros

- `--wsl` lists distros with `wsl.exe -l -q` and checks each RUNNING one with
  `wsl.exe -d <distro> -e sh -c ...`. Running a command in a stopped distro
  starts it, so stopped distros are reported as not checked. `--wsl-start`
  checks them too, and starts them.
- Each distro needs its own git-guard install (`sh install.sh` inside the
  distro). A Windows install does not cover WSL.
- git-guard's hooks run on git older than 2.36 (Ubuntu 22.04 ships 2.34.1).
  Until this release, the pre-commit provider's push checks used
  `git ls-tree --format`, which needs 2.36, so every push from such a host in a
  repo declaring `.pre-commit-config.yaml` was refused with "submodule listing
  ... failed". Install this release or newer there.
- git older than 2.36 has no `includeIf "hasconfig:remote.*.url:..."`. `--wsl`
  flags those versions. Any config you scope with `hasconfig:` does not apply
  there, so set `core.hooksPath` unconditionally in that distro's global config.

## 3. Prove it with a throwaway private repo

`doctor` reads config. Proof is a push. On the host, in a scratch PRIVATE
repository you own:

1. Push a branch with an ordinary commit. It must pass, and the push output must
   contain `git-guard pre-push <version>: 1 ref(s) checked`.
2. Build a commit that never met a commit hook and contains a fake
   secret-shaped string assembled at run time (for example `AKIA` followed by
   16 uppercase letters or digits). Use plumbing (`git hash-object -w`,
   `git mktree`, `git commit-tree`, `git update-ref`). Push it on a second
   branch. It must be refused with `git-guard BLOCKED: possible secret in
   <file>:<line> ... in commit <sha>`, and the remote must not have the branch.

Delete the scratch repo afterwards. Never use a real credential for this.

## 4. Supported push routes

- **From a worktree.** Pushes from a bare repository are refused, with no
  override: there is no worktree to run the repo's declared checks in. From a
  bare repo, `git worktree add <dir> <branch>` gives a worktree that shares its
  objects; push from there.
- **Custody of unreviewed work** goes to `preserve/<name>` or
  `refs/preserve/<name>` with a `Preserve-Of: <ref-or-sha>` trailer on every new
  commit. That route is secret-scanned and allowed from bare repositories too.

## 5. What pre-push re-checks

pre-commit scans the lines each commit adds. A commit made on an uncovered
host, written by plumbing, made in a web editor, or rebased onto unscanned
history reaches the remote through a covered host without that scan. So
pre-push also scans every commit the push publishes: commits reachable from the
pushed refs but not from what the destination is known to hold: the old values
it reported for the pushed refs and, when the push names a configured remote
whose push URL is its fetch URL, that remote's tracking refs
(`--remotes=<name>`). With a separate `pushurl` or a `pushInsteadOf` rewrite
the tracking refs describe another repository, so they are not used. Another remote's history is
never excluded, so a commit fetched from one remote and pushed by URL to an
empty destination is scanned. A new branch pushed by URL therefore scans its
history; the scan covers at most the newest 500 commits and says so when there
are more. A hit blocks the
push and names the commit, file and line. If the line is genuinely not a
secret, tag it `# pragma: allowlist secret` in a new commit that rewrites it.

Every push the hook lets through prints one receipt line on stderr:
`git-guard pre-push <version>: <n> ref(s) checked`. A push without that line
ran no git-guard pre-push.

## 6. The limit

No client-side check can detect its own absence. A host without git-guard runs
no hook, prints no receipt, and refuses nothing. `doctor` makes coverage
checkable, and the pre-push content scan stops unscanned commits that pass
through a covered host. A push made only from an uncovered host still reaches
the remote. Catching that belongs on the admission side: the merge autopilot in
vigil-utils must verify pushed content (for example by running the secret scan
over the PR range) before it merges. That is a separate issue in vigil-utils.
