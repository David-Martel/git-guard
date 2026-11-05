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
| `hooks-path` | global/system `core.hooksPath` is unset (with `--require-installed`), dangling, or has no executable `pre-commit` |
| `hooks-version` | the hooks dir has no git-guard `VERSION` beside it: a stale legacy copy (FAIL with `--require-installed`, warning otherwise) |
| `repo-hooks` (`--repo`) | the repo's effective hooks dir is not git-guard's and its `pre-commit`/`pre-push` do not call git-guard |
| `provider` (`--repo`) | the repo declares `.pre-commit-config.yaml` or a lefthook config and that tool is not on `PATH` (pre-push would refuse every push) |
| `pyyaml` (`--repo`) | no `python`/`python3` imports `yaml` (warning; FAIL with `--strict`) |
| `wsl` (`--wsl`) | a running distro has no global `core.hooksPath`, or it has no executable `pre-commit` |

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
pushed refs but not from the refs' old values or from the remote's tracking
refs (`--remotes=<name>`, or every tracking ref when the push names a URL). It
scans at most the newest 500 and says so when there are more. A hit blocks the
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
