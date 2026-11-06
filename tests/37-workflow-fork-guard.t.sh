#!/bin/sh
# Category 37 — fork code never reaches a self-hosted runner or a secret.
#
# Protects: git-guard's persistent self-hosted runners and its secrets.
#   git-guard is a public repository. Its self-hosted runners (the dtm-work Docker carrier and
#   the native runner) are persistent, not --ephemeral: see vigil-utils
#   ci-runners/dtm-work/gitguard-carrier/README.md, "Who may run jobs here".
#   Their safety rests on these workflow rules:
#   - no `pull_request_target` trigger;
#   - no `issue_comment` or `workflow_run` trigger in a workflow with a self-hosted job. Those
#     events run on the base repository with fork-controlled input, the classic route for fork
#     code onto a self-hosted runner;
#   - in a workflow that runs on pull_request, every self-hosted job, and every job that reads
#     a secret, carries the job-level guard:
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
#   passed to a reusable workflow. Both forms were found to evade the first version (codex
#   review of git-guard #105).
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
        return False  # a reusable-workflow call; its own jobs are checked where they live
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


def reads_secrets(job):
    if "secrets" in job:  # a reusable-workflow call passing secrets, or `inherit`
        return True
    return any(SECRETS.search(e) for e in EXPR.findall(json.dumps(job)))


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
    if any(self_hosted(j) for j in jobs.values()):
        for trig in sorted(triggers & {"issue_comment", "workflow_run"}):
            bad.append(f"{path.name}: {trig} trigger in a workflow with a self-hosted job")
    if "pull_request" not in triggers:
        continue
    for name, job in jobs.items():
        if self_hosted(job) and not guarded(job):
            bad.append(f"{path.name}: job {name} runs on self-hosted without the fork guard")
        elif reads_secrets(job) and not guarded(job):
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

  rm -rf "$_wfg_tmp"
}
