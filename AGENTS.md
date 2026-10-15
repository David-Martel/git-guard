# Agent instructions

## Merging: the merge autopilot

The fleet's merge autopilot merges PRs here; do not merge by hand, start a second scheduler, or use `--admin` without a
written reason.

- **Open the PR and let it land.** The autopilot reviews each new head, updates `behind` branches, and squash-merges
  when the required checks pass at the exact head and its review gate admits the PR.
- **One concern per PR.** A review covers one diff and carries over to later heads with a byte-identical PR diff, so
  small PRs review and merge fastest.
- **Read your PR's route.** The `merge-autopilot/admission` commit status description names who must do what next. The
  `autopilot-escalated` label marks an overdue route. The autopilot's `decisions.jsonl` and `state.json` (the state
  directory is printed by `autopilot.py config`) and the telemetry endpoints hold the detail.
- **Independence.** A claude-authored PR needs a codex approval, and a codex-authored PR needs a claude approval.
  HIGH-risk paths (CI, deploy, hooks, hardware and release code) need two approvals, one from outside the codex family.
- **Blockers** go on agent-bus thread `machine-hygiene`, tagged `repo:<name>`.
- Operation, onboarding and troubleshooting: [merge-autopilot README](https://github.com/David-Martel/vigil-utils/blob/main/tools/merge-autopilot/README.md).
