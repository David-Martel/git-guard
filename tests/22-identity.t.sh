#!/bin/sh
# Per-agent signing identity + authorship attestation (hooks/common/identity.sh,
# hooks/commit-msg, the identity step of hooks/pre-push).
#
# Every key here is a THROWAWAY generated inside the suite's temp root; nothing
# touches ~/.ssh, global git config or GitHub. The verifier's controls:
#   negative  clean range (agent key + matching trailer, human key + no trailer)
#             -> exit 0
#   positive  agent key + other agent's trailer      -> exit 1
#             unsigned                               -> exit 1
#             human key + Agent trailer              -> exit 1
#             key not in allowed_signers             -> exit 2
#             unknown key AND a mismatch in one range -> exit 1 (1 wins)
#             no allowed_signers file                -> exit 3
#
# ssh-keygen with -Y signing support is required. Outside CI the cases SKIP
# without it; under CI (CI=true) its absence is a FAILURE, because a suite that
# quietly skips its own controls proves nothing.

GG_ID_SH=""

# gg_id_ready — ssh-keygen present and able to make an SSH signature.
gg_id_ready() {
  have ssh-keygen || return 1
  d="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg-id-probe.XXXXXX")" || return 1
  ssh-keygen -q -t ed25519 -N '' -C probe -f "$d/k" </dev/null >/dev/null 2>&1 &&
    printf 'probe\n' > "$d/f" &&
    ssh-keygen -Y sign -n git -f "$d/k" "$d/f" >/dev/null 2>&1
  rc=$?
  rm -rf "$d"
  return "$rc"
}

gg_id_skip_or_fail() {
  if [ "${CI:-}" = "true" ]; then
    t_fail "$1: ssh-keygen with -Y signing is REQUIRED in CI (install openssh-client)"
  else
    t_skip "$1: no ssh-keygen with -Y signing support"
  fi
}

# gg_id_lab DIR — throwaway keys + an allowed_signers file:
#   claude, codex  (made by `identity keygen`, host "testhost")
#   david          (human)       rogue (never listed)
gg_id_lab() {
  lab="$1"
  mkdir -p "$lab/nohooks"
  GG_ID_SH="$GG_ROOT/hooks/common/identity.sh"
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" keygen claude --host testhost >/dev/null 2>&1 || return 1
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" keygen codex --host testhost >/dev/null 2>&1 || return 1
  ssh-keygen -q -t ed25519 -N '' -C human -f "$lab/keys/david" </dev/null >/dev/null 2>&1 || return 1
  ssh-keygen -q -t ed25519 -N '' -C rogue -f "$lab/keys/rogue" </dev/null >/dev/null 2>&1 || return 1
  : > "$lab/allowed_signers"
  sh "$GG_ID_SH" allowed-signers add claude "$lab/keys/claude@testhost.pub" --file "$lab/allowed_signers" 2>/dev/null &&
    sh "$GG_ID_SH" allowed-signers add codex "$lab/keys/codex@testhost.pub" --file "$lab/allowed_signers" 2>/dev/null &&
    sh "$GG_ID_SH" allowed-signers add david "$lab/keys/david.pub" --file "$lab/allowed_signers" 2>/dev/null
}

GG_ID_N=0
# gg_id_commit REPO KEY|- TRAILER|- SUBJECT — commit with hooks OFF (an empty
# hooks dir), signed with KEY straight from the private key file ("-" =
# unsigned), carrying `Agent: TRAILER` ("-" = no trailer).
gg_id_commit() {
  gg_id_repo="$1" gg_id_key="$2" gg_id_agent="$3"
  GG_ID_N=$((GG_ID_N + 1))
  printf '%s\n' "$GG_ID_N" > "$gg_id_repo/f$GG_ID_N.txt"
  git -C "$gg_id_repo" add "f$GG_ID_N.txt"
  set -- -m "$4"
  [ "$gg_id_agent" = "-" ] || set -- "$@" -m "Agent: $gg_id_agent"
  if [ "$gg_id_key" = "-" ]; then
    git -C "$gg_id_repo" -c core.hooksPath="$lab/nohooks" -c commit.gpgsign=false commit -q "$@"
  else
    git -C "$gg_id_repo" -c core.hooksPath="$lab/nohooks" -c gpg.format=ssh \
      -c user.signingkey="$gg_id_key" -c commit.gpgsign=true commit -q "$@"
  fi
}

# gg_id_eq EXPECTED ACTUAL MSG — string equality assertion.
gg_id_eq() {
  if [ "$1" = "$2" ]; then t_ok "$3"; else t_fail "$3 (expected '$1', got '$2')"; fi
}

t_case_identity_cli() {
  t_begin "identity CLI: keygen / env / allowed-signers"
  if ! gg_id_ready; then gg_id_skip_or_fail "identity CLI"; return; fi
  lab="$(mktemp -d "$GG_T_TMPROOT/gg-id.XXXXXX")" || { t_fail "lab dir"; return; }
  GG_ID_SH="$GG_ROOT/hooks/common/identity.sh"

  # keygen: 0700 dir, 0600 key, stdout is ONLY the public key + gh command.
  out="$lab/keygen.out"
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ROOT/bin/git-guard" identity keygen claude --host testhost >"$out" 2>"$lab/keygen.err"
  t_expect_rc 0 "$?" "keygen creates a key"
  if [ -f "$lab/keys/claude@testhost" ] && [ -f "$lab/keys/claude@testhost.pub" ]; then
    t_ok "key pair is named <agent>@<host>"
  else
    t_fail "key pair is named <agent>@<host>"
  fi
  gg_id_eq "drwx------" "$(ls -ld "$lab/keys" | cut -c1-10)" "key directory is 0700"
  gg_id_eq "-rw-------" "$(ls -ld "$lab/keys/claude@testhost" | cut -c1-10)" "private key is 0600"
  gg_id_eq 2 "$(wc -l < "$out" | tr -d ' ')" "keygen stdout is exactly two lines"
  head -n 1 "$out" | cmp -s - "$lab/keys/claude@testhost.pub"
  t_assert "$?" "keygen stdout line 1 is the public key"
  grep -qx "gh api -X POST user/ssh_signing_keys -f title=agent-claude@testhost -F key=@$lab/keys/claude@testhost.pub" "$out"
  t_assert "$?" "keygen prints the registration command (-F reads the file)"
  if grep -q 'PRIVATE' "$out" "$lab/keygen.err"; then t_fail "keygen never prints private key material"; else t_ok "keygen never prints private key material"; fi
  # Idempotent: an existing key is never regenerated.
  cp "$lab/keys/claude@testhost.pub" "$lab/before.pub"
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" keygen claude --host testhost >/dev/null 2>&1
  t_expect_rc 0 "$?" "second keygen succeeds"
  cmp -s "$lab/before.pub" "$lab/keys/claude@testhost.pub"
  t_assert "$?" "second keygen does not regenerate the key"
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" keygen 'Bad/Agent' --host testhost >/dev/null 2>&1
  t_expect_rc 3 "$?" "keygen rejects an invalid agent id"

  # env: command-scope config that git and its hooks actually see.
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" env claude --host testhost --allowed-signers "$lab/as" >"$lab/env.sh" 2>/dev/null
  t_expect_rc 0 "$?" "env prints an identity block"
  r="$(gg_mktemp_repo)" || { t_fail "env repo"; return; }
  git -C "$r" config user.signingkey /repo/local/key.pub   # repo-local value the agent must beat
  scope_line="$( . "$lab/env.sh"; cd "$r" && git config --show-scope --get user.signingkey )"
  gg_id_eq "$(printf 'command\t%s' "$lab/keys/claude@testhost")" "$scope_line" "env beats repo-local user.signingkey at command scope"
  agent_line="$( . "$lab/env.sh"; printf '%s|%s|%s' "$GIT_GUARD_AGENT" "$(cd "$r" && git config --get gpg.ssh.allowedSignersFile)" "$(cd "$r" && git config --bool --get commit.gpgsign)" )"
  gg_id_eq "claude|$lab/as|true" "$agent_line" "env sets GIT_GUARD_AGENT, allowedSignersFile and gpgsign"
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" env codex --host testhost >/dev/null 2>&1
  t_expect_rc 1 "$?" "env refuses an identity whose key does not exist"
  GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" env codex --host testhost --allow-missing >/dev/null 2>&1
  t_expect_rc 0 "$?" "env --allow-missing prints a snippet before keygen"
  if gg_has_python; then
    GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" env claude --host testhost --format json 2>/dev/null |
      "$(gg_python)" -c 'import json,sys; d=json.load(sys.stdin); assert d["GIT_CONFIG_COUNT"]=="4" and d["GIT_GUARD_AGENT"]=="claude"'
    t_assert "$?" "env --format json is a valid settings.json env object"
    if "$(gg_python)" -c 'import tomllib' >/dev/null 2>&1; then
      GIT_GUARD_IDENTITY_KEYDIR="$lab/keys" sh "$GG_ID_SH" env claude --host testhost --format toml 2>/dev/null |
        "$(gg_python)" -c 'import sys, tomllib; d = tomllib.loads(sys.stdin.read()); assert d["shell_environment_policy"]["set"]["GIT_CONFIG_KEY_0"] == "user.signingkey"'
      t_assert "$?" "env --format toml is a valid Codex [shell_environment_policy.set] table"
    else
      t_skip "env --format toml parse check: python has no tomllib (<3.11)"
    fi
  else
    t_skip "env json/toml parse checks: no python"
  fi

  # allowed-signers: add / idempotent re-add / one key one principal / check.
  ssh-keygen -q -t ed25519 -N '' -C human -f "$lab/keys/david" </dev/null >/dev/null 2>&1
  f="$lab/as"; : > "$f"
  sh "$GG_ID_SH" allowed-signers add claude "$lab/keys/claude@testhost.pub" --file "$f" 2>/dev/null
  t_expect_rc 0 "$?" "allowed-signers add claude"
  sh "$GG_ID_SH" allowed-signers add david "$lab/keys/david.pub" --file "$f" 2>/dev/null
  t_expect_rc 0 "$?" "allowed-signers add a human principal"
  sh "$GG_ID_SH" allowed-signers add claude "$lab/keys/claude@testhost.pub" --file "$f" 2>/dev/null
  t_expect_rc 0 "$?" "re-adding the same key+principal is a no-op"
  t_expect_rc 2 "$(grep -c 'namespaces="git"' "$f")" "file has exactly two namespace-restricted entries"
  sh "$GG_ID_SH" allowed-signers add codex "$lab/keys/claude@testhost.pub" --file "$f" 2>/dev/null
  t_expect_rc 3 "$?" "one key cannot be listed for a second principal"
  sh "$GG_ID_SH" allowed-signers add claude "$lab/keys/claude@testhost" --file "$f" 2>/dev/null
  t_expect_rc 3 "$?" "add refuses a PRIVATE key file"
  sh "$GG_ID_SH" allowed-signers check --file "$f" >/dev/null 2>&1
  t_expect_rc 0 "$?" "check passes on a well-formed file (negative control)"
  sh "$GG_ID_SH" allowed-signers check --file "$GG_ROOT/identity/allowed_signers" >/dev/null 2>&1
  t_expect_rc 0 "$?" "the shipped identity/allowed_signers passes check"
  cp "$f" "$lab/bad"
  sed -n 1p "$f" | sed 's/ namespaces="git"//' >> "$lab/bad"
  printf 'codex namespaces="git" ssh-ed25519 not-a-key\n' >> "$lab/bad"
  sh "$GG_ID_SH" allowed-signers check --file "$lab/bad" >"$lab/check.out" 2>&1
  t_expect_rc 1 "$?" "check fails on a broken file (positive control)"
  grep -q 'missing namespaces="git"' "$lab/check.out" && grep -q 'listed twice' "$lab/check.out" &&
    grep -q 'does not parse' "$lab/check.out"
  t_assert "$?" "check names each problem (namespace, duplicate, unparseable)"
  # namespaces="git" in the trailing COMMENT restricts nothing (ssh-keygen
  # ignores comments), so check must not accept it.
  printf 'claude %s misleading-namespaces="git"\n' "$(cut -d' ' -f1,2 "$lab/keys/claude@testhost.pub")" > "$lab/comment-ns"
  sh "$GG_ID_SH" allowed-signers check --file "$lab/comment-ns" >"$lab/check.out" 2>&1
  t_expect_rc 1 "$?" "check rejects namespaces=\"git\" that appears only in the comment"

  gg_rmrepo "$r"; rm -rf "$lab"
}

t_case_identity_verify() {
  t_begin "identity verify: real signatures vs Agent trailer (exit 0/1/2/3)"
  if ! gg_id_ready; then gg_id_skip_or_fail "identity verify"; return; fi
  lab="$(mktemp -d "$GG_T_TMPROOT/gg-id.XXXXXX")" || { t_fail "lab dir"; return; }
  gg_id_lab "$lab" || { t_fail "build identity lab"; rm -rf "$lab"; return; }
  as="$lab/allowed_signers"; K="$lab/keys"
  r="$(gg_mktemp_repo)" || { t_fail "verify repo"; return; }
  v() { (cd "$r" && sh "$GG_ID_SH" verify --allowed-signers "$as" "$@" >"$lab/v.out" 2>&1); }

  gg_id_commit "$r" "$K/claude@testhost" claude "feat: claude"
  gg_id_commit "$r" "$K/codex@testhost" codex "feat: codex"
  gg_id_commit "$r" "$K/david" - "docs: human"
  clean="$(git -C "$r" rev-parse HEAD)"
  v "$clean"
  t_expect_rc 0 "$?" "NEGATIVE control: matching agents + trailer-less human -> exit 0"
  grep -q '3 commit(s), 0 mismatch, 0 unknown-key' "$lab/v.out"
  t_assert "$?" "clean range reports 3 commits, 0 findings"
  grep -q "^ok   .* G claude Agent=claude" "$lab/v.out"
  t_assert "$?" "%GS names the agent principal (claude), not the shared email"

  gg_id_commit "$r" "$K/claude@testhost" codex "feat: mislabeled"
  v HEAD~1..HEAD
  t_expect_rc 1 "$?" "POSITIVE: claude key + Agent: codex -> exit 1"
  grep -q "signed by 'claude' but Agent trailer is 'codex'" "$lab/v.out"
  t_assert "$?" "mismatch message names both sides"

  gg_id_commit "$r" - claude "chore: unsigned"
  v HEAD~1..HEAD
  t_expect_rc 1 "$?" "POSITIVE: unsigned commit -> exit 1"

  gg_id_commit "$r" "$K/david" claude "fix: human key, agent trailer"
  v HEAD~1..HEAD
  t_expect_rc 1 "$?" "POSITIVE: human key + Agent: claude -> exit 1"
  grep -q "signed by human 'david'" "$lab/v.out"
  t_assert "$?" "human-key message names the human principal"

  gg_id_commit "$r" "$K/claude@testhost" - "feat: claude without trailer"
  v HEAD~1..HEAD
  t_expect_rc 1 "$?" "POSITIVE: agent key with no Agent trailer -> exit 1"

  gg_id_commit "$r" "$K/rogue" claude "chore: rogue key"
  v HEAD~1..HEAD
  t_expect_rc 2 "$?" "POSITIVE: key not in allowed_signers -> exit 2"
  grep -q '^UNKN ' "$lab/v.out"
  t_assert "$?" "unknown key is reported as UNKN"

  v "$clean"..HEAD
  t_expect_rc 1 "$?" "range with mismatches AND an unknown key -> exit 1 (1 wins)"
  grep -q '5 commit(s), 4 mismatch, 1 unknown-key' "$lab/v.out"
  t_assert "$?" "mixed range counts every finding"

  (cd "$r" && sh "$GG_ID_SH" verify --allowed-signers "$lab/does-not-exist" HEAD >/dev/null 2>&1)
  t_expect_rc 3 "$?" "missing allowed_signers file -> exit 3 (never an all-N verdict)"
  (cd "$r" && sh "$GG_ID_SH" verify --allowed-signers "$as" >/dev/null 2>&1)
  t_expect_rc 3 "$?" "no range -> exit 3"

  # Through the CLI front-end, as CI calls it; log.showSignature must not
  # corrupt the parse.
  (cd "$r" && git config log.showSignature true &&
    sh "$GG_ROOT/bin/git-guard" identity verify --allowed-signers "$as" "$clean" >/dev/null 2>&1)
  t_expect_rc 0 "$?" "git-guard identity verify works with log.showSignature=true"

  gg_rmrepo "$r"; rm -rf "$lab"
}

t_case_identity_hooks() {
  t_begin "identity hooks: commit-msg (intent) + pre-push (real signatures)"
  if ! gg_id_ready; then gg_id_skip_or_fail "identity hooks"; return; fi
  lab="$(mktemp -d "$GG_T_TMPROOT/gg-id.XXXXXX")" || { t_fail "lab dir"; return; }
  gg_id_lab "$lab" || { t_fail "build identity lab"; rm -rf "$lab"; return; }
  as="$lab/allowed_signers"; K="$lab/keys"
  r="$(gg_mktemp_repo)" || { t_fail "hooks repo"; return; }
  mkdir -p "$r/test-hooks/common" "$r/.git-guard"
  for h in prepare-commit-msg commit-msg pre-push; do cp "$GG_ROOT/hooks/$h" "$r/test-hooks/$h"; chmod +x "$r/test-hooks/$h"; done
  cp "$GG_ROOT/hooks/common/identity.sh" "$r/test-hooks/common/identity.sh"
  git -C "$r" config core.hooksPath "$r/test-hooks"
  git -C "$r" config gpg.ssh.allowedSignersFile "$as"
  git -C "$r" config gpg.format ssh
  git -C "$r" config commit.gpgsign true
  git -C "$r" config user.signingkey "$K/david"
  # Downstream pre-push records the ref list it receives (stdin replay control).
  printf '#!/bin/sh\ncat > "%s/downstream-stdin"\n' "$lab" > "$r/.git-guard/pre-push.local"
  chmod +x "$r/.git-guard/pre-push.local"
  # Identity env for an agent, exactly as a launcher would export it.
  GIT_GUARD_IDENTITY_KEYDIR="$K" sh "$GG_ROOT/hooks/common/identity.sh" env claude --host testhost --allowed-signers "$as" >"$lab/claude.env" 2>/dev/null
  n=0
  c() { # c ENVFILE|- [VAR=VAL...] -- commit; returns git's rc, stderr in $lab/c.err
    n=$((n + 1)); printf '%s\n' "$n" > "$r/h$n.txt"; git -C "$r" add "h$n.txt"
    ef="$1"; shift
    (
      # shellcheck disable=SC1090  # the env file is generated by `identity env` above
      [ "$ef" = "-" ] || . "$ef"
      cd "$r" && env "$@" git commit -q -m "change $n"
    ) 2>"$lab/c.err"
  }

  c "$lab/claude.env" GIT_GUARD_IDENTITY=warn
  t_expect_rc 0 "$?" "matching agent commit lands"
  if grep -q 'git-guard identity' "$lab/c.err"; then t_fail "matching agent commit is silent"; else t_ok "matching agent commit is silent"; fi
  gg_id_eq "G claude claude" "$(git -C "$r" log -1 --format='%G? %GS %(trailers:key=Agent,valueonly)' | tr -d '\n')" "landed commit: %G?=G, %GS=claude, Agent=claude"

  c - GIT_GUARD_IDENTITY=warn
  t_expect_rc 0 "$?" "human commit (human key, no agent env) lands"
  if grep -q 'git-guard identity' "$lab/c.err"; then t_fail "human commit is silent"; else t_ok "human commit is silent"; fi

  before="$(git -C "$r" rev-parse HEAD)"
  c "$lab/claude.env" GIT_GUARD_AGENT=codex GIT_GUARD_IDENTITY=warn
  t_expect_rc 0 "$?" "WARN mode: claude key + Agent: codex still lands"
  grep -q "belongs to agent 'claude' but the Agent trailer is 'codex'" "$lab/c.err"
  t_assert "$?" "WARN mode: the mismatch is reported"
  if [ "$(git -C "$r" rev-parse HEAD)" != "$before" ]; then t_ok "WARN mode: HEAD advanced"; else t_fail "WARN mode: HEAD advanced"; fi
  mismatch_tip="$(git -C "$r" rev-parse HEAD)"

  before="$(git -C "$r" rev-parse HEAD)"
  c "$lab/claude.env" GIT_GUARD_AGENT=codex GIT_GUARD_IDENTITY=enforce
  t_expect_rc 1 "$?" "ENFORCE mode: claude key + Agent: codex is refused"
  gg_id_eq "$before" "$(git -C "$r" rev-parse HEAD)" "ENFORCE mode: refused commit does not land"
  git -C "$r" reset -q

  c - GIT_GUARD_AGENT=claude GIT_GUARD_IDENTITY=warn
  grep -q "human principal 'david' but the Agent trailer is 'claude'" "$lab/c.err"
  t_assert "$?" "human key + Agent: claude is reported (the shared-key case)"

  before="$(git -C "$r" rev-parse HEAD)"
  c - GIT_GUARD_IDENTITY=enforce GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.signingkey "GIT_CONFIG_VALUE_0=$K/rogue"
  t_expect_rc 1 "$?" "ENFORCE mode: unknown signing key is refused"
  gg_id_eq "$before" "$(git -C "$r" rev-parse HEAD)" "ENFORCE mode: unknown-key commit does not land"
  git -C "$r" reset -q

  # claude key and no trailer (prepare-commit-msg is bypassed too) would be a
  # mismatch; GIT_GUARD=0 must still let it through.
  c "$lab/claude.env" GIT_GUARD=0 GIT_GUARD_IDENTITY=enforce
  t_expect_rc 0 "$?" "GIT_GUARD=0 bypasses the identity check (even under enforce)"
  c "$lab/claude.env" GIT_GUARD_AGENT=codex GIT_GUARD_IDENTITY=off
  t_expect_rc 0 "$?" "GIT_GUARD_IDENTITY=off disables the check"
  if grep -q 'git-guard identity' "$lab/c.err"; then t_fail "off mode is silent"; else t_ok "off mode is silent"; fi

  # A host with no SSH signing configured: silent no-op, even in enforce mode.
  u="$(gg_mktemp_repo)" || { t_fail "unconfigured repo"; return; }
  git -C "$u" config core.hooksPath "$r/test-hooks"
  printf 'x\n' > "$u/x.txt"; git -C "$u" add x.txt
  (cd "$u" && GIT_GUARD_AGENT=claude GIT_GUARD_IDENTITY=enforce git commit -q -m "unsigned host") 2>"$lab/u.err"
  t_expect_rc 0 "$?" "unconfigured host: commit lands even under enforce"
  if grep -q 'git-guard identity' "$lab/u.err"; then t_fail "unconfigured host: no identity output"; else t_ok "unconfigured host: no identity output"; fi
  gg_rmrepo "$u"

  # Downstream commit-msg chaining (a repo's own hook is not shadowed).
  printf '#!/bin/sh\necho downstream-ran >&2\nexit 7\n' > "$r/.git-guard/commit-msg.local"
  chmod +x "$r/.git-guard/commit-msg.local"
  c - GIT_GUARD_IDENTITY=warn
  t_expect_rc 1 "$?" "a failing .git-guard/commit-msg.local blocks the commit"
  grep -q downstream-ran "$lab/c.err"
  t_assert "$?" "downstream commit-msg hook ran"
  rm -f "$r/.git-guard/commit-msg.local"; git -C "$r" reset -q

  # pre-push: clean branch silent; mismatching branch warns (lands) or is
  # refused under enforce; the downstream hook still receives the ref list.
  remote="$lab/remote.git"; git init -q --bare "$remote"
  git -C "$r" remote add origin "$remote"
  git -C "$r" branch -f clean "$(git -C "$r" rev-list --reverse HEAD | sed -n 2p)"
  (cd "$r" && GIT_GUARD_IDENTITY=warn git push -q origin clean) 2>"$lab/p.err"
  t_expect_rc 0 "$?" "pre-push: clean branch is accepted"
  if grep -q 'git-guard identity' "$lab/p.err"; then t_fail "pre-push: clean branch is silent"; else t_ok "pre-push: clean branch is silent"; fi
  grep -q 'refs/heads/clean' "$lab/downstream-stdin"
  t_assert "$?" "pre-push: downstream hook still receives the ref list"

  git -C "$r" branch -f mixed "$mismatch_tip"
  (cd "$r" && GIT_GUARD_IDENTITY=enforce git push -q origin mixed) 2>"$lab/p.err"
  t_expect_rc 1 "$?" "pre-push ENFORCE: mismatching branch is refused"
  if git --git-dir="$remote" rev-parse -q --verify refs/heads/mixed >/dev/null; then
    t_fail "pre-push ENFORCE: refused branch did not reach the remote"
  else
    t_ok "pre-push ENFORCE: refused branch did not reach the remote"
  fi
  grep -q "signed by 'claude' but Agent trailer is 'codex'" "$lab/p.err"
  t_assert "$?" "pre-push names the offending commit"
  (cd "$r" && GIT_GUARD_IDENTITY=warn git push -q origin mixed) 2>"$lab/p.err"
  t_expect_rc 0 "$?" "pre-push WARN: mismatching branch is pushed"
  grep -q 'WARN only, the push proceeds' "$lab/p.err"
  t_assert "$?" "pre-push WARN: the mismatch is reported"
  grep -q 'refs/heads/mixed' "$lab/downstream-stdin"
  t_assert "$?" "pre-push WARN: downstream hook still receives the ref list"

  # The same history pushed to a SECOND remote (a mirror) must still be
  # verified: origin/mixed already holds it, but the mirror does not.
  mirror="$lab/mirror.git"; git init -q --bare "$mirror"
  git -C "$r" remote add mirror "$mirror"
  (cd "$r" && GIT_GUARD_IDENTITY=enforce git push -q mirror mixed) 2>"$lab/p.err"
  t_expect_rc 1 "$?" "pre-push ENFORCE: history already on origin is still checked for a new remote"
  if git --git-dir="$mirror" rev-parse -q --verify refs/heads/mixed >/dev/null; then
    t_fail "pre-push ENFORCE: refused mirror push did not land"
  else
    t_ok "pre-push ENFORCE: refused mirror push did not land"
  fi

  gg_rmrepo "$r"; rm -rf "$lab"
}
