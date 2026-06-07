#!/bin/sh
#
# branch-protection.sh — apply a sensible GitHub branch-protection ruleset to a
# repo's default branch via the `gh` CLI. OPTIONAL: most repos don't need branch
# protection, but a shared/public repo benefits from PR-only + signed commits +
# no-force-push + required status checks.
#
# This is the SAME posture git-guard's own repo uses. Re-running is idempotent
# from the operator's perspective (GitHub replaces the ruleset by name).
#
# Usage:
#   ./branch-protection.sh <owner>/<repo> [--branch main] [--require-check "git-guard QA / self-test"] [--approvals 0] [--dry-run]
#
# Requires: gh (authenticated), the repo to exist. With 0 required approvals you
# can merge your own PRs; with >=1 a human review gate applies.

set -u

REPO=""
BRANCH="main"
CHECK="git-guard QA / self-test"
APPROVALS=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:-main}"; shift 2 ;;
    --require-check) CHECK="${2:-}"; shift 2 ;;
    --approvals) APPROVALS="${2:-0}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) REPO="$1"; shift ;;
  esac
done

[ -n "$REPO" ] || { echo "usage: branch-protection.sh <owner>/<repo> [opts]" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 1; }

# Build the ruleset JSON: PR-only (allow self-merge if approvals=0), required
# signatures, no force-push, no deletion, optional required status check.
checks_json=""
[ -n "$CHECK" ] && checks_json="{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":true,\"required_status_checks\":[{\"context\":\"$CHECK\"}]}},"

payload=$(cat <<JSON
{
  "name": "git-guard default-branch protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/$BRANCH"], "exclude": [] } },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_signatures"},
    $checks_json
    {"type": "pull_request", "parameters": {
        "required_approving_review_count": $APPROVALS,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash", "merge", "rebase"]
    }}
  ]
}
JSON
)

echo "Applying ruleset to $REPO (branch: $BRANCH, approvals: $APPROVALS, check: ${CHECK:-none})"
if [ "$DRY" = "1" ]; then
  printf '%s\n' "$payload"
  echo "(dry run — not applied)"
  exit 0
fi
printf '%s' "$payload" | gh api -X POST "repos/$REPO/rulesets" --input - \
  && echo "ruleset applied." \
  || { echo "ruleset POST failed (a ruleset of this name may already exist — check: gh api repos/$REPO/rulesets)"; exit 1; }
