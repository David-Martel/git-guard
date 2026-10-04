# Per-agent authorship attestation

Every agent on a host (Claude Code, Codex) commits as the same human author, and
today they all sign with one shared host SSH key. The `Agent:` trailer that
`prepare-commit-msg` writes says who made a commit, but nothing checks it. The
signature cannot back it up, because every signature is made with the same key.

`git-guard identity` gives each (agent, host) pair its own SSH signing key. A
versioned `allowed_signers` file maps every key to one **principal**: the agent
id (`claude`, `codex`, ...) for an agent key, or a human principal for the
owner's keys. Git then reports the principal as `%GS`, and git-guard checks that
it agrees with the `Agent:` trailer:

| Signing key's principal | `Agent:` trailer | Verdict |
|---|---|---|
| an agent (`claude`, `codex`, `jules`, `gemini`) | the same agent | ok |
| an agent | another agent, or none | mismatch |
| a human (any other principal) | none | ok |
| a human | any agent | mismatch |
| not in `allowed_signers` (`%G?` = `U`) | anything | unknown key |
| unsigned or unverifiable (`%G?` = `N`, `B`, `E`, ...) | anything | mismatch |

Design and measurements: `agent-identity-attestation-20261002.md` (lane I1,
2026-10-02), which carries the evidence for every claim below that is not
re-tested here.

> **Phase 1 is report-only (TPM #1587).** The hooks WARN and never block unless
> `GIT_GUARD_IDENTITY=enforce` is set. Nothing is deployed, no key is generated
> on a real host and no key is registered on GitHub by this change.

## What this proves, and what it does not

- **It is attribution, not isolation.** All agents run as one Unix user, so any
  of them can read any other agent's key file and sign as that agent. Per-agent
  keys make honest attribution deterministic and catch mistakes such as a wrong
  trailer, a shared key or a missing launcher variable. They do not stop a hostile
  agent. Real isolation needs a separate Unix user per agent, which is an owner
  tradeoff.
- Keys do **not** establish an independent GitHub review, and they do not
  authenticate an agent-bus identity. Those need separate mechanisms, such as
  per-agent GitHub Apps.
- GitHub shows "Verified" for every key registered on the account, and does not
  say which key signed. Locally, `git log --format='%G? %GS'` names the agent.

## Commands

```sh
git-guard identity keygen <agent> [--dir D] [--host H]
git-guard identity env <agent> [--format sh|json|toml] [--allowed-signers F] [--allow-missing]
git-guard identity status
git-guard identity allowed-signers path|show|check|add <principal> <pubkey> [--file F]
git-guard identity verify [--allowed-signers F] [--quiet] [--] <rev-args...>
```

### `keygen`

This command creates `~/.ssh/agent-signing/<agent>@<host>`, an ed25519 key with
no passphrase so that unattended agents can sign. The key file is mode 0600 and
the directory 0700. It never overwrites an existing key. Stdout carries **only**
the public key and the registration command:

```sh
gh api -X POST user/ssh_signing_keys -f title=agent-<agent>@<host> -F key=@<path>.pub
```

`-F` (not `-f`) is required. `gh api -F key=@file` sends the file's contents,
while `-f key=@file` sends the literal string `@file`. Registration needs the
`admin:ssh_signing_key` token scope, and it is an **owner** step.

### `env`

`env` prints the identity block for a launcher:

```sh
export GIT_CONFIG_COUNT='4'
export GIT_CONFIG_KEY_0='user.signingkey'
export GIT_CONFIG_VALUE_0='/home/<user>/.ssh/agent-signing/claude@<host>'
export GIT_CONFIG_KEY_1='gpg.format'
export GIT_CONFIG_VALUE_1='ssh'
export GIT_CONFIG_KEY_2='commit.gpgsign'
export GIT_CONFIG_VALUE_2='true'
export GIT_CONFIG_KEY_3='gpg.ssh.allowedSignersFile'
export GIT_CONFIG_VALUE_3='<allowed_signers>'
export GIT_GUARD_AGENT='claude'
```

Some properties of this block, each of them deliberate and tested:

- **`GIT_CONFIG_COUNT`, not `GIT_CONFIG_GLOBAL`.** `GIT_CONFIG_COUNT` sets
  *command*-scope config. It beats a repo-local `user.signingkey`, while
  `GIT_CONFIG_GLOBAL` loses to one: vigil-spark pins identity in `.git/config`.
  It also layers on top of `~/.gitconfig`, which `GIT_CONFIG_GLOBAL` replaces
  (dropping `core.hooksPath`, which turns git-guard off). Hooks and child
  `git` processes inherit it.
- **`user.signingkey` is the private key path.** Git then signs straight from
  the file, so no `SSH_AUTH_SOCK` is needed. That matters for both launchers
  (see below).
- **`GIT_GUARD_AGENT`** is the explicit selector `prepare-commit-msg` prefers
  over `CODEX_THREAD_ID` / `CLAUDECODE` detection.
- `env` refuses (exit 1) when the key does not exist. A block naming a missing
  key would make **every** commit fail to sign. Pass `--allow-missing` to draft a
  snippet before `keygen`.
- `--allowed-signers` defaults to this release's `identity/allowed_signers`. That
  file is empty until the owner decides to publish keys there (see the next
  section). Until then, point it at the host's own file, for example
  `~/.config/git/allowed_signers`, after adding the agent's key to that file with
  `allowed-signers add ... --file`.
- If a launcher already exports other `GIT_CONFIG_*` entries, merge them by hand:
  the block sets `GIT_CONFIG_COUNT=4`.
- **`commit.gpgsign=true` at command scope reaches every repo the agent
  touches**, including temp repos that test fixtures create with a local
  `commit.gpgsign false`: local config loses to command scope. Inside an agent
  shell, such fixtures in vigil-utils, vigil-spark, clarius and other repos start
  SSH-signing with the agent key. That is slower, and it fails where the fixture
  environment has no `ssh-keygen`. A later `git -c commit.gpgsign=false` still
  wins. git-guard's own `tests/run.sh` unsets `GIT_CONFIG_COUNT` for this reason,
  and other suites may need the same line.

### `verify` (CI and manual)

`verify` checks the **real** signatures of a range:

| Exit | Meaning |
|---|---|
| 0 | every commit is attested |
| 1 | at least one mismatch (wins over 2) |
| 2 | no mismatch, but at least one key is not in `allowed_signers` |
| 3 | usage or configuration error, including **no `allowed_signers` file** |

Exit 3 for a missing file is deliberate. Without `gpg.ssh.allowedSignersFile`,
git reports every SSH-signed commit as `N`, which looks exactly like unsigned,
so a bare CI runner would otherwise produce a false verdict. In CI, pass the
file explicitly and verify the **PR head range**:

```sh
git-guard identity verify --allowed-signers identity/allowed_signers "$BASE_SHA..$HEAD_SHA"
```

Do not verify `main` itself. Squash merges are committed and PGP-signed by
GitHub (`%G?` = `E` locally), which drops the per-agent signature. See
"Merge-train squash trailers" below.

`allowed-signers check` lints the file. Every entry must parse, must carry
`namespaces="git"` and must have a valid principal, and no key may appear twice.

## Hooks (WARN-ONLY by default)

`GIT_GUARD_IDENTITY=off|warn|enforce` controls both hooks. The default is
`warn`. `GIT_GUARD=0` bypasses both, as it does for every git-guard hook.

- **`commit-msg`** (new) checks *intent* before signing. It resolves
  `user.signingkey` to a principal and compares that with the trailer. It is a
  **silent no-op** unless the commit will be SSH-signed (`commit.gpgsign=true`,
  `gpg.format=ssh`, a `user.signingkey` is set) **and** an `allowed_signers` file
  is configured (`GIT_GUARD_ALLOWED_SIGNERS` or `gpg.ssh.allowedSignersFile`).
  So installing it changes nothing on a host without signing. It also chains a
  repo's own commit-msg hook, which `core.hooksPath` otherwise silently shadows:
  `$GIT_GUARD_DOWNSTREAM_COMMIT_MSG` > `.git-guard/commit-msg.local` >
  `lefthook run commit-msg`. The lefthook step runs when the repo has a root
  lefthook config. Configured-but-unrunnable is an error: a
  `$GIT_GUARD_DOWNSTREAM_COMMIT_MSG` that is set but missing or not executable
  blocks the commit, and so does a root lefthook config without the lefthook
  binary, the same lefthook rule `pre-commit` and `pre-push` apply
  (`GIT_GUARD_ALLOW_MISSING_LEFTHOOK=1` opts out; `LEFTHOOK=0` still disables
  lefthook). agent-hub's advisory `conventional`
  commit-msg check starts running under this rule.
- **`pre-push`** checks the *real* signatures of every pushed range. That is
  `remote..local`, or `local --not --remotes=<that remote>` for a new ref or an
  unfetched remote tip. Only the destination's own tracking refs are excluded,
  so pushing the same history to a second remote (a mirror) is still checked.
  A push to a bare URL has no tracking refs, so the whole reachable history
  counts. A range above `GIT_GUARD_IDENTITY_MAX_COMMITS` (default 500) is not
  checked: it is reported as unknown, which blocks under `enforce`.
  It buffers the ref list and replays it, so LFS and downstream hooks still
  receive it. If the buffer cannot be created (an unwritable `TMPDIR`), the
  check is skipped with a warning and the push proceeds; under `enforce` the
  push is refused with that reason.

Repos that set their own `core.hooksPath` (vigil-spark, vigil-utils:
`.githooks`) only get these checks if their hooks delegate to git-guard's.
The CI `verify` step covers them either way.

**What to expect on today's fleet in `warn` mode.** Every agent commit is signed
with the shared host key, whose principal is the owner's email. So it is
reported as "human principal ... but the Agent trailer is 'claude'". That
report is the phase-1 measurement. It goes to zero as each launcher gets its
own key.

## Where `allowed_signers` lives: `identity/allowed_signers` in this repo

`install.sh` materializes a release with `git archive <tag> | tar -x` and swaps
`current` atomically. Any tracked file therefore lands at
`~/.local/share/git-guard/current/identity/allowed_signers` on every host,
**versioned with the signed release tag** and updated in the same atomic step
as the hooks that read it. So:

- one reviewed source of truth, changed only by PR;
- no second deployment mechanism and no per-host drift;
- `env` names the file through the stable `current` path, so a launcher set up
  once follows `git-guard update`;
- old keys are kept with `valid-before=` so that history still verifies.

Two caveats apply:

1. **This repository is public.** Public keys are not secret, but the file would
   also publish host names and the agent roster. The shipped file is
   intentionally empty, and publishing keys in it is an owner decision.
   Until then, each host keeps its own `~/.config/git/allowed_signers`. That is
   what `gpg.ssh.allowedSignersFile` already points at, and the checks prefer it.
   A private companion repo is the alternative if the roster must not be public.
2. `allowed-signers add` refuses to edit an installed release. Edit
   `identity/allowed_signers` in a checkout and open a PR, or pass `--file`.

## Launcher integration (snippets, NOT applied)

Applying any of these to `~/.claude/settings.json`, `~/.codex/config.toml` or a
launcher is a separate step that needs the owner's and codex's approval.

### Claude Code

Two options exist:

- **`settings.json` `env`.** This reaches the Bash tool, hooks, MCP servers and
  subprocesses. Two limits apply. A **shell export of the same variable wins**
  over a non-managed settings value. And values are static strings, while the
  key path differs per host (`claude@asuspro13`, `claude@spark-0060`, ...), so
  one shared `settings.json` (dtm-claude) cannot carry it.
- **A SessionStart hook writing `$CLAUDE_ENV_FILE`** (recommended). It computes
  the host-specific block at session start, and the Bash tool sources it before
  each command:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "[ -n \"$CLAUDE_ENV_FILE\" ] && command -v git-guard >/dev/null && git-guard identity env claude --allowed-signers \"$HOME/.config/git/allowed_signers\" >> \"$CLAUDE_ENV_FILE\" 2>/dev/null || true" } ] }
    ]
  }
}
```

The hook fails open: with no key or no git-guard, the session keeps today's
shared-key behavior. `git-guard identity env claude --format json` prints the
equivalent static `env` object for a single host. Because signing reads the key
file, no `SSH_AUTH_SOCK` is involved; a settings value for that variable would
silently lose to the shell's export anyway.

### Codex

Codex reads `[shell_environment_policy]` in `~/.codex/config.toml` (or
`$CODEX_HOME/<profile>.config.toml`). It applies `inherit`, then the default
`*KEY*`/`*SECRET*`/`*TOKEN*` excludes, then `exclude`, then **`set`**. So the
identity must go in `set`. An *inherited* `GIT_CONFIG_KEY_0` matches `*KEY*` and
is stripped, while `GIT_CONFIG_COUNT` survives, and git then fails on the
missing key. The current `inherit = "core"` also drops `SSH_AUTH_SOCK`, which is
the second reason the private key path is used:

```sh
git-guard identity env codex --format toml \
  --allowed-signers "$HOME/.config/git/allowed_signers"
```

```toml
[shell_environment_policy.set]
GIT_CONFIG_COUNT = "4"
GIT_CONFIG_KEY_0 = "user.signingkey"
GIT_CONFIG_VALUE_0 = "/home/<user>/.ssh/agent-signing/codex@<host>"
# ... KEY_1..3 / VALUE_1..3 as printed ...
GIT_GUARD_AGENT = "codex"
```

The block is host-specific, so generate it on each host. Whether the default
Codex Linux sandbox lets a shell read `~/.ssh/agent-signing/` is untested; the
first commit after rollout shows it (`git log -1 --format='%G? %GS'`).

### Jules

Jules commits as `google-labs-jules[bot]`, **unsigned**, and cannot hold our keys,
so `verify` reports its commits as `N` (exit 1). The `jules` principal is
reserved, and `prepare-commit-msg` cannot write `Agent: jules` yet. Re-commit
Jules output under the reviewing agent's or the owner's key before merge, or
exclude those commits from the verified range. That is an owner policy decision.

### Human

No change. Keep `id_ed25519` in `~/.gitconfig`, and list its public key under a
human principal (today `davidmartel07@gmail.com`, which keeps `%GS` backward
compatible). Do not export `GIT_GUARD_AGENT`. A human key with an `Agent:`
trailer is a mismatch.

## Merge-train squash trailers (proposal for vigil-utils)

Squash merges are committed by GitHub, so the agent's signature does not reach
`main`. On vigil-utils only 15 of the last 200 `main` commits kept an `Agent:`
trailer. `tools/merge-train/merge_train.sh` calls
`gh pr merge "$pr" -R "$R" --squash --match-head-commit "${H[$pr]}"` with no
body (about line 1050), so GitHub writes its default body: the concatenated
head commit messages. The proposal is to pass `--body-file` instead, built from
the PR **at the matched head**:

```sh
head="${H[$pr]}"
base="$(gh api "repos/$R/pulls/$pr" --jq .base.sha)"   # REST, not GraphQL
git fetch -q origin "$head" "$base"
body_file="$(mktemp)"
{
  # Keep GitHub's default content: one line per head commit.
  git log --reverse --format='* %s' "$base..$head"
  printf '\n'
  # Union of the head commits' Agent and Co-authored-by trailers, de-duplicated.
  git log --format='%(trailers:key=Agent)%(trailers:key=Co-authored-by)' "$base..$head" |
    sed '/^$/d' | sort -u
  # Every review is posted by the one account, so the reviewing LANE comes from
  # a `Reviewed-by-lane:` line in a review body, counted only when the review
  # was made at exactly this head.
  gh api "repos/$R/pulls/$pr/reviews" --jq \
    ".[] | select(.commit_id == \"$head\") | .body | capture(\"(?m)^Reviewed-by-lane: *(?<l>[^\\\\r\\\\n]+)\") | \"Reviewed-by-lane: \\(.l)\"" |
    sort -u
  printf 'PR-Head: %s\n' "$head"
} > "$body_file"
gh pr merge "$pr" -R "$R" --squash --match-head-commit "$head" --body-file "$body_file"
```

Rules for the trailer block (it must be the message's LAST paragraph, so
`git interpret-trailers --parse` finds it):

- `Agent:` lists every distinct agent among the head commits, one line each.
  It is the trailer, not a key, because GitHub signs the squash commit.
- `Co-authored-by:` is the de-duplicated union, so GitHub's co-author display
  survives the squash.
- `Reviewed-by-lane: <agent>/<lane>` is copied only from review bodies whose
  `commit_id` is the merged head. It is never typed into the squash by hand.
  Reviewers adopt the convention of putting that line in their review body.
- `PR-Head: <sha>` pins the signed head that GitHub keeps at
  `refs/pull/<n>/head`. Later, `git-guard identity verify <base>..<PR-Head>`
  re-checks the original per-agent signatures behind any squash on `main`.
- With `--match-head-commit`, the trailers describe exactly the commits that
  merged. If the head moves, the merge is refused, as it is today.

This is a proposal for a different repository (vigil-utils). It is not
implemented here.

## Rollout (owner and codex actions)

1. The owner approves `admin:ssh_signing_key` for the gh token (a pending
   device-flow refresh), or registers keys in the web UI.
2. On each host, for each agent, run `git-guard identity keygen <agent>`, and
   have the owner run the printed `gh api` command. No agent registers keys.
3. Add each public key to `~/.config/git/allowed_signers` (or, if the owner
   approves publishing, to `identity/allowed_signers` by PR) with
   `allowed-signers add`.
4. Apply the launcher snippets above: Claude Code SessionStart, and Codex
   `shell_environment_policy.set`. This needs owner and codex approval.
5. Watch `warn` output and `git-guard identity verify` for a week. Then make a
   non-required CI `verify` step required, and later consider
   `GIT_GUARD_IDENTITY=enforce`.
