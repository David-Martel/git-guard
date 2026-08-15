# Git Commit / Branch-Protection / Hook Safety Protocol (MANDATORY)

> Why this exists: in a single session an orchestrator destroyed two agents' work by
> chaining `git reset --hard origin/main` immediately after a `git commit` that had
> **silently failed a pre-commit hook** (ruff-format / clippy / lefthook). The commit
> never landed, the push pushed an empty branch, and the chained `reset --hard`
> permanently discarded the uncommitted changes. Branch-protected repos + format/lint/
> test hooks make commits and pushes fail mid-sequence; destructive git ops chained
> behind them destroy work. These rules make that class of error impossible.

## IRON RULES (non-negotiable)

1. **VERIFY EVERY COMMIT LANDED before any push / PR / reset.**
   Immediately after `git commit`, run `git log -1 --pretty='%h %G? %s'`. It MUST show
   the **new** commit (new SHA + your subject). If it shows the **parent** SHA, the
   commit FAILED (a pre-commit hook rejected it) — fix the cause and re-commit. DO NOT
   proceed to push/PR/reset.

2. **NEVER chain `git reset --hard` after a commit in the same command/sequence.**
   `reset --hard origin/main` discards ALL uncommitted changes — including
   `git add`-ed-but-uncommitted NEW files. Only **pure-untracked, never-`git add`-ed**
   files survive it. If the commit silently failed, a chained reset destroys the work.

3. **NEVER `git reset --hard` (or `checkout -- .`, `clean -fd`) a working tree that a
   background agent is editing.** It reverts the agent's tracked-file changes. Confirm
   no agent is active on that repo first.

4. **Run the formatter, not just `--check`, before committing.** `uv run ruff format` /
   `cargo fmt --all` (then `--check` to confirm). A passing `--check` inside a subagent
   does NOT guarantee the hook's formatter agrees (version/scope/auto-fix differences).

5. **NEVER bypass hooks** (`--no-verify`, `--no-gpg-sign`) unless the user explicitly
   asks. A failing hook is a real problem — fix the cause.

## Hooks: what failure looks like

- **pre-commit / lefthook**: runs format+lint (and sometimes a workspace check). On
  failure the commit does NOT happen; staged changes remain staged. An auto-fix step
  (ruff-safe-fix, ruff format) MODIFIES files but does NOT complete the commit — you
  must re-stage + re-commit.
- **pre-push**: runs the heavy gate (tests/clippy/typecheck/build). On failure the push
  is rejected; the branch is not updated. Look for `! [remote rejected]` or
  `failed to push`. (Note: this repo family's pre-push runs on EVERY push incl. branches.)
- **prepare-commit-msg**: adds deterministic Codex attribution when
  `CODEX_THREAD_ID` is present or `GIT_GUARD_AGENT=codex`. Git does not skip this
  hook with `--no-verify`. A conflicting `Agent:` trailer blocks the commit; the
  deliberate human-emergency escape hatch is `GIT_GUARD=0`.
- A chained PowerShell/bash command does **not** stop on a hook failure unless you check
  exit codes / output between steps. Always inspect the commit/push result.

## SAFE SEQUENCE — branch-protected repo (PR-only + signed)

```
git checkout -b feat/x
<format>                              # uv run ruff format  /  cargo fmt --all
git add <specific files>              # NOT -A if a background agent is active on this repo
git commit -S -F msg                  # signed
git log -1 --pretty='%h %G? %s'       # GATE 1: new SHA + subject? else fix+retry, STOP
git push -u origin feat/x             # GATE 2: "new branch"/updated, NOT "up-to-date"/"rejected"
gh pr create ...                      # GATE 3: returns a PR URL
gh pr merge --squash --delete-branch  # GATE 4: "merged"
# sync local main ONLY after the merge is confirmed AND the tree has no uncommitted/agent work:
git checkout main; git fetch origin; git reset --hard origin/main
```

If any GATE fails, STOP and remediate — never run the next destructive step.

## Branch protection (GitHub rulesets)

- Repos may add a ruleset mid-work (PR-only + required signatures + no force-push,
  `required_approving_review_count` often 0). A direct `git push origin main` then fails
  with `Changes must be made through a pull request`. Switch to branch→PR→squash-merge.
- Check with `gh api repos/<owner>/<repo>/rules/branches/main`. With 0 required approvals
  you may merge your own PR (no human gate); with >=1, leave it for review.
- Squash-merge commits are signed by GitHub's web-flow key → local `git log` shows `E`
  (cannot verify) not `G`; that is expected, not a failure.

## Account-wide QA gate (subsystem A)

The GLOBAL `~/.git-hooks` pre-commit now composes a broad, language-gated,
configurable QA layer (secret-scan + NUL cleanup + ast-grep + per-language
lint/format) that BLOCKS on real fast errors and WARNs otherwise. Full reference,
the per-repo `.qa-gate.conf` override schema, the ast-grep rule catalog, DEBUG
mode (`QA_DEBUG=1`), and troubleshooting live in
[`~/.agents/QA_TOOLING.md`](QA_TOOLING.md). A blocked commit prints the IRON
RULE 1 message (STAGED-but-UNCOMMITTED, do NOT `reset --hard`). To soften/disable
a check for one repo, drop a `.qa-gate.conf` at its root (see QA_TOOLING §5).

## Recovery if work is lost

- `git add`-ed-but-uncommitted changes discarded by `reset --hard` are GONE (never
  committed → not in reflog). Pure-untracked (never-`git add`-ed) files survive.
- An agent's task transcript (the JSONL output file) records every Write/Edit. The clean
  recovery is to re-dispatch the agent with its prior completion report as the exact spec
  (the report fully specifies the work → deterministic redo).
