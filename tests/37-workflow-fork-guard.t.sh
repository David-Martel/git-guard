#!/bin/sh
# Category 37 — fork code never reaches a self-hosted runner or a secret.
#
# Protects: git-guard's persistent self-hosted runners and its secrets.
#   git-guard is a public repository. Its self-hosted runners (the dtm-work Docker carrier and
#   the native runner) are persistent, not --ephemeral: see vigil-utils
#   ci-runners/dtm-work/gitguard-carrier/README.md, "Who may run jobs here".
#   Their safety rests on these workflow rules:
#   - no `pull_request_target` trigger;
#   - no `issue_comment` or `workflow_run` trigger with a self-hosted job or reusable call. Those
#     events run on the base repository with fork-controlled input, the classic route for fork
#     code onto a self-hosted runner;
#   - in a workflow that runs on pull_request or workflow_call, every self-hosted job,
#     secret-reading job, and reusable-workflow call carries the job-level guard:
#       if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
# Detects:
#   - a self-hosted or secret-reading job added or edited without that exact job-level guard;
#   - a guard moved from the job to a step, where it no longer stops the job from being
#     scheduled;
#   - any of the forbidden triggers above.
#   Self-hosted means a `runs-on` that names any label other than a GitHub-hosted image label
#   (ubuntu-*, windows-*, macos-*), compared case-insensitively, in any form GitHub accepts: a
#   string, a list, or a mapping's `labels`. A custom label alone (`runs-on: git-guard-docker`)
#   selects a self-hosted runner, so it counts without `self-hosted` beside it (codex review of
#   #105 at eb48e68). A mapping `group:` and an expression also count, because both can
#   resolve to a self-hosted runner. Reading a secret means any `secrets`
#   inside `${{ }}` (`secrets.X`, `secrets['X']`, `toJSON(secrets)`), or a job-level `secrets:`
#   passed to a reusable workflow. Workflow-level env expressions count for the jobs that
#   inherit them too. Reusable calls count conservatively even without runs-on or secrets:
#   this checker does not fetch or resolve their descendants. Local callees are checked
#   independently because GitHub's github context retains the caller's event. A caller's
#   workflow env is not propagated to a callee; each workflow's own env is checked here.
#   Both findings and the review bindings are recorded in
#   ../docs/WORKFLOW_FORK_GUARD_REVIEW.json. GitHub's contract:
#   https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
#   https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#env
# Needs: python with PyYAML (skips without it); no network or runner.
# Breadcrumb: .github/workflows/qa.yml (self-test-docker, self-test-native);
#   vigil-utils PR #1352 review, finding 2.
#
# Controls: the checker must pass the real workflows, and must fail one fixture per rule,
# so it cannot pass vacuously.
# shellcheck shell=sh

wfg_check() {
  # wfg_check DIR — exit 0 if every workflow under DIR keeps the rules; print each breach.
  "$(gg_python)" - "$1" <<'PY'
import json
import pathlib
import re
import sys

import yaml

GUARD = ("github.event_name != 'pull_request' || "
         "github.event.pull_request.head.repo.full_name == github.repository")
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
SECRETS = re.compile(r"\bsecrets\b")
root = pathlib.Path(sys.argv[1])
bad = []
files = sorted([*root.glob("*.yml"), *root.glob("*.yaml")])
if not files:
    print(f"no workflows under {root}")
    sys.exit(2)


# GitHub-hosted image labels (standard and larger runners). Anything else in
# runs-on can only be satisfied by a self-hosted runner: GitHub-hosted runners
# carry no custom labels, and git-guard's own runners answer to custom labels
# such as git-guard-docker and git-guard-local with or without `self-hosted`.
HOSTED = re.compile(
    r"(ubuntu|windows|macos)-(latest|slim|\d+(\.\d+)?)"
    r"(-(arm|arm64|intel|large|xlarge|\d+-cores?|\d+core))*")


def self_hosted(job):
    if "runs-on" not in job:
        return False  # reusable calls have their own conservative guard below
    runs_on = job["runs-on"]
    if isinstance(runs_on, dict):
        if "group" in runs_on:
            return True  # a runner group can hold self-hosted runners
        runs_on = runs_on.get("labels", [])
    labels = runs_on if isinstance(runs_on, list) else [runs_on]
    if not labels:
        return True  # nothing GitHub-hosted was named; fail closed
    # GitHub matches labels case-insensitively. An expression can resolve to
    # any label, and any non-hosted label selects a self-hosted runner.
    return any("${{" in str(lab) or not HOSTED.fullmatch(str(lab).strip().lower())
               for lab in labels)


def secret_expressions(value):
    return any(SECRETS.search(e) for e in EXPR.findall(json.dumps(value)))


def reads_secrets(job):
    if "secrets" in job:  # a reusable-workflow call passing secrets, or `inherit`
        return True
    return secret_expressions(job)


def guarded(job):
    cond = str(job.get("if", "")).strip()
    if cond.startswith("${{") and cond.endswith("}}"):
        cond = cond[3:-2].strip()
    return cond == GUARD


for path in files:
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    on = doc.get("on", doc.get(True, {}))  # PyYAML reads a bare `on:` key as True
    triggers = set(on) if isinstance(on, (dict, list)) else {on}
    jobs = doc.get("jobs") or {}

    if "pull_request_target" in triggers:
        bad.append(f"{path.name}: uses pull_request_target")
    if any(self_hosted(j) or "uses" in j for j in jobs.values()):
        for trig in sorted(triggers & {"issue_comment", "workflow_run"}):
            bad.append(f"{path.name}: {trig} trigger in a workflow with a self-hosted job or reusable call")
    if not triggers & {"pull_request", "workflow_call"}:
        continue
    workflow_secrets = secret_expressions(doc.get("env") or {})
    for name, job in jobs.items():
        if "uses" in job and not guarded(job):
            bad.append(f"{path.name}: job {name} calls a reusable workflow without the fork guard")
        elif self_hosted(job) and not guarded(job):
            bad.append(f"{path.name}: job {name} runs on self-hosted without the fork guard")
        elif (reads_secrets(job) or workflow_secrets) and not guarded(job):
            bad.append(f"{path.name}: job {name} reads a secret without the fork guard")
for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY
}

# wfg_fixture DIR BODY — write BODY as DIR/qa.yml.
wfg_fixture() {
  mkdir -p "$1" && printf '%s\n' "$2" > "$1/qa.yml"
}

# Require the actual checker to reject for the named policy reason, not a YAML
# parse error or a missing dependency. Used only by the new boundary controls.
wfg_refused() {
  _wfg_result="$(wfg_check "$1" 2>&1)"
  _wfg_rc=$?
  t_expect_rc 1 "$_wfg_rc" "control: $3"
  case "$_wfg_result" in
    *"$2"*) t_ok "control: $3 names the policy breach" ;;
    *) t_fail "control: $3 lacks expected diagnostic: $_wfg_result" ;;
  esac
}

t_case_workflow_fork_guard() {
  t_begin "workflow fork guard (37)"
  if ! gg_has_pyyaml; then
    t_skip "python with PyYAML not available"
    return 0
  fi
  _wfg_tmp="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg.wfg.XXXXXX")" || { t_fail "mktemp"; return 0; }

  _wfg_out="$(wfg_check "$GG_ROOT/.github/workflows" 2>&1)"
  t_assert "$?" "every self-hosted and secret-reading job in .github/workflows keeps the fork guard ${_wfg_out}"

  wfg_fixture "$_wfg_tmp/stepguard" 'on:
  pull_request:
jobs:
  docker:
    runs-on: [self-hosted, Linux, X64, git-guard-docker]
    steps:
      - if: github.event.pull_request.head.repo.full_name == github.repository
        run: true'
  wfg_check "$_wfg_tmp/stepguard" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: a self-hosted job guarded only at step level is refused"

  wfg_fixture "$_wfg_tmp/target" 'on:
  pull_request_target:
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/target" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: a pull_request_target trigger is refused"

  # shellcheck disable=SC2016  # literal ${{ }} expressions in the YAML fixture
  wfg_fixture "$_wfg_tmp/secret" 'on:
  pull_request:
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: echo "$T"
        env:
          T: ${{ secrets.SOME_TOKEN }}'
  wfg_check "$_wfg_tmp/secret" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: an unguarded pull_request job reading secrets.* is refused"

  # shellcheck disable=SC2016  # literal ${{ }} expressions in the YAML fixture
  wfg_fixture "$_wfg_tmp/secretindex" 'on:
  pull_request:
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: echo "$T"
        env:
          T: ${{ secrets['"'"'SOME_TOKEN'"'"'] }}'
  wfg_check "$_wfg_tmp/secretindex" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: an unguarded job reading secrets['X'] is refused"

  # shellcheck disable=SC2016  # literal ${{ }} expressions in the YAML fixture
  wfg_fixture "$_wfg_tmp/secretall" 'on:
  pull_request:
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: echo "$ALL" > /dev/null
        env:
          ALL: ${{ toJSON(secrets) }}'
  wfg_check "$_wfg_tmp/secretall" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: an unguarded job reading toJSON(secrets) is refused"

  wfg_fixture "$_wfg_tmp/labels" 'on:
  pull_request:
jobs:
  docker:
    runs-on:
      labels: [self-hosted, Linux, X64, git-guard-docker]
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/labels" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: an unguarded job on a mapping-form self-hosted runs-on is refused"

  # A custom label alone selects a self-hosted runner: GitHub-hosted runners
  # carry only GitHub's own image labels. git-guard's runners answer to
  # git-guard-docker and git-guard-local, so each must count without
  # `self-hosted` beside it, in string, list and mapping form, and labels match
  # case-insensitively (`Self-Hosted`).
  for _wfg_sel in 'git-guard-docker' 'git-guard-local' '[git-guard-docker]' '[Linux, X64, git-guard-local]' \
    '[Self-Hosted, Linux]' '{labels: git-guard-docker}' '{labels: [ubuntu-latest, git-guard-local]}'; do
    rm -rf "$_wfg_tmp/custom"
    wfg_fixture "$_wfg_tmp/custom" "on:
  pull_request:
jobs:
  docker:
    runs-on: $_wfg_sel
    steps:
      - run: true"
    wfg_check "$_wfg_tmp/custom" >/dev/null 2>&1
    t_expect_rc 1 "$?" "control: an unguarded job on runs-on: $_wfg_sel is refused"
  done

  # The real workflow with BOTH persistent runners selected by their custom
  # label only and both job guards removed must be refused (codex's probe on
  # #105). Both are rewritten so neither job still names self-hosted.
  mkdir -p "$_wfg_tmp/real"
  sed -e 's/runs-on: \[self-hosted, Linux, X64, \(git-guard-[a-z]*\)\]/runs-on: \1/' \
    -e "/^    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository\$/d" \
    "$GG_ROOT/.github/workflows/qa.yml" > "$_wfg_tmp/real/qa.yml"
  if grep -q 'runs-on: git-guard-docker$' "$_wfg_tmp/real/qa.yml" &&
     grep -q 'runs-on: git-guard-local$' "$_wfg_tmp/real/qa.yml" &&
     ! grep -q 'runs-on:.*self-hosted\|^ *if: .*head.repo.full_name == github.repository$' "$_wfg_tmp/real/qa.yml"; then
    wfg_check "$_wfg_tmp/real" >/dev/null 2>&1
    t_expect_rc 1 "$?" "control: qa.yml on custom labels only, with no guards, is refused"
  else
    t_fail "control fixture: qa.yml no longer has the expected runs-on/guard lines; update this test"
  fi

  # GitHub-hosted image labels stay hosted, in any case, so an unprivileged
  # hosted job needs no guard.
  for _wfg_sel in ubuntu-latest Ubuntu-24.04 '[windows-2022]' 'macos-15-xlarge' '{labels: [ubuntu-24.04-arm]}'; do
    rm -rf "$_wfg_tmp/hosted"
    wfg_fixture "$_wfg_tmp/hosted" "on:
  pull_request:
jobs:
  hosted:
    runs-on: $_wfg_sel
    steps:
      - run: true"
    wfg_check "$_wfg_tmp/hosted" >/dev/null 2>&1
    t_expect_rc 0 "$?" "control: an unprivileged job on GitHub-hosted runs-on: $_wfg_sel passes"
  done

  wfg_fixture "$_wfg_tmp/group" 'on:
  pull_request:
jobs:
  docker:
    runs-on:
      group: git-guard-carriers
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/group" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: an unguarded job on a runner group is refused"

  # shellcheck disable=SC2016  # literal ${{ }} expressions in the YAML fixture
  wfg_fixture "$_wfg_tmp/comment" 'on:
  issue_comment:
jobs:
  docker:
    if: github.event_name != '"'"'pull_request'"'"' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, Linux, X64, git-guard-docker]
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/comment" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: issue_comment reaching a self-hosted job is refused (the guard does not help there)"

  wfg_fixture "$_wfg_tmp/wfrun" 'on:
  workflow_run:
    workflows: [qa]
    types: [completed]
jobs:
  docker:
    runs-on: [self-hosted, Linux, X64, git-guard-docker]
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/wfrun" >/dev/null 2>&1
  t_expect_rc 1 "$?" "control: workflow_run reaching a self-hosted job is refused"

  # shellcheck disable=SC2016  # literal ${{ }} expressions in the YAML fixture
  wfg_fixture "$_wfg_tmp/ok" 'on:
  pull_request:
  push:
jobs:
  docker:
    if: github.event_name != '"'"'pull_request'"'"' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, Linux, X64, git-guard-docker]
    steps:
      - run: echo "${{ secrets.SOME_TOKEN }}" > /dev/null
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: echo "the word secrets outside an expression reads nothing"'
  wfg_check "$_wfg_tmp/ok" >/dev/null 2>&1
  t_expect_rc 0 "$?" "control: a guarded self-hosted job and an unprivileged hosted job pass"

  # Protects: reusable calls cannot hide a privileged job, and called workflows
  # inherit the caller's PR context. Detects: treating missing runs-on or an
  # on: workflow_call callee as outside the guard policy. Needs: only the local
  # checker/PyYAML; no workflow is dispatched or fetched. Breadcrumb: wfg_check.
  wfg_fixture "$_wfg_tmp/reusecaller" 'on: pull_request
jobs:
  call:
    uses: David-Martel/git-guard/.github/workflows/reusable.yml@main'
  wfg_refused "$_wfg_tmp/reusecaller" 'calls a reusable workflow without the fork guard' \
    'an unguarded PR reusable-workflow caller is refused'

  wfg_fixture "$_wfg_tmp/reusecallee" 'on: workflow_call
jobs:
  docker:
    runs-on: git-guard-docker
    steps:
      - run: true'
  wfg_refused "$_wfg_tmp/reusecallee" 'runs on self-hosted without the fork guard' \
    'an unguarded self-hosted reusable-workflow callee is refused'

  # shellcheck disable=SC2016  # literal ${{ }} in the YAML fixture
  wfg_fixture "$_wfg_tmp/reusecalleesecret" 'on: workflow_call
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: true
        env:
          TOKEN: ${{ secrets.SOME_TOKEN }}'
  wfg_refused "$_wfg_tmp/reusecalleesecret" 'reads a secret without the fork guard' \
    'an unguarded secret-reading reusable-workflow callee is refused'

  wfg_fixture "$_wfg_tmp/reusenested" 'on: workflow_call
jobs:
  call:
    uses: David-Martel/git-guard/.github/workflows/reusable.yml@main'
  wfg_refused "$_wfg_tmp/reusenested" 'calls a reusable workflow without the fork guard' \
    'an unguarded nested reusable-workflow caller is refused'

  # The PR guard is always true for these events, so even a guarded reusable
  # caller cannot make their potentially self-hosted descendants safe.
  for _wfg_trigger in issue_comment workflow_run; do
    wfg_fixture "$_wfg_tmp/reuseevent" "on: $_wfg_trigger
jobs:
  call:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    uses: David-Martel/git-guard/.github/workflows/reusable.yml@main"
    wfg_refused "$_wfg_tmp/reuseevent" "$_wfg_trigger trigger" \
      "$_wfg_trigger reaching a reusable caller is refused"
  done

  # Protects: workflow env secrets inherited by hosted jobs also require the
  # job guard. Detects: scanning only the job mapping or just secrets.X syntax.
  # Needs: local checker/PyYAML. Breadcrumb: wfg_check / reads_secrets.
  # shellcheck disable=SC2016  # literal ${{ }} expressions, never evaluated by sh
  for _wfg_secret in '${{ secrets.SOME_TOKEN }}' '${{ secrets['"'"'SOME_TOKEN'"'"'] }}' '${{ toJSON(secrets) }}'; do
    wfg_fixture "$_wfg_tmp/workflowenv" "on: pull_request
env:
  TOKEN: $_wfg_secret
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: true"
    wfg_refused "$_wfg_tmp/workflowenv" 'reads a secret without the fork guard' \
      "an unguarded hosted job inheriting workflow env $_wfg_secret is refused"
  done

  # Protects: the conservative rules still admit guarded callers/callees and
  # unprivileged hosted callees; non-PR-only callers remain unchanged.
  # Detects: unconditional rejection or demanding guards on every hosted job.
  # Needs: local checker/PyYAML. Breadcrumb: wfg_check / guarded.
  wfg_fixture "$_wfg_tmp/reuseok" 'on: pull_request
jobs:
  call:
    if: github.event_name != '"'"'pull_request'"'"' || github.event.pull_request.head.repo.full_name == github.repository
    uses: ./.github/workflows/callee.yml
    secrets: inherit'
  printf '%s\n' 'on: workflow_call
jobs:
  docker:
    if: github.event_name != '"'"'pull_request'"'"' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: git-guard-docker
    steps:
      - run: true' > "$_wfg_tmp/reuseok/callee.yml"
  wfg_check "$_wfg_tmp/reuseok" >/dev/null 2>&1
  t_expect_rc 0 "$?" "control: a guarded reusable caller and self-hosted callee pass"

  wfg_fixture "$_wfg_tmp/reusehostedok" 'on: workflow_call
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/reusehostedok" >/dev/null 2>&1
  t_expect_rc 0 "$?" "control: an unprivileged hosted reusable callee needs no guard"

  # shellcheck disable=SC2016  # literal ${{ }} in the YAML fixture
  wfg_fixture "$_wfg_tmp/workflowenvok" 'on: pull_request
env:
  TOKEN: ${{ secrets.SOME_TOKEN }}
jobs:
  hosted:
    if: github.event_name != '"'"'pull_request'"'"' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/workflowenvok" >/dev/null 2>&1
  t_expect_rc 0 "$?" "control: a guarded hosted job inheriting workflow env secrets passes"

  wfg_fixture "$_wfg_tmp/workflowenvplain" 'on: pull_request
env:
  TEXT: the word secrets outside an expression reads nothing
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: true'
  wfg_check "$_wfg_tmp/workflowenvplain" >/dev/null 2>&1
  t_expect_rc 0 "$?" "control: non-secret workflow env does not require a hosted job guard"

  wfg_fixture "$_wfg_tmp/reusepushok" 'on: push
jobs:
  call:
    uses: David-Martel/git-guard/.github/workflows/reusable.yml@main'
  wfg_check "$_wfg_tmp/reusepushok" >/dev/null 2>&1
  t_expect_rc 0 "$?" "control: a push-only reusable caller needs no PR guard"

  rm -rf "$_wfg_tmp"
}
