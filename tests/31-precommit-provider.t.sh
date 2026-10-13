#!/bin/sh
# Declared pre-commit providers must actually run; PATH-only lefthook cannot steal them.
# shellcheck shell=sh
t_case_precommit_provider() {
  t_begin '31 declared pre-commit provider and pushed-source binding'
  r="$(gg_mktemp_repo)"
  log="$(gg_tmp_log)"
  bin="$GG_T_TMPROOT/framework-bin"
  mkdir -p "$bin"
  marker="$GG_T_TMPROOT/framework-calls"
  refs_copy="$GG_T_TMPROOT/framework-refs"
  args_copy="$GG_T_TMPROOT/framework-args"
  cat > "$bin/pre-commit" <<EOF
#!/bin/sh
printf '%s\\n' framework >> '$marker'
printf '%s\\n' "\$@" > '$args_copy'
cat > '$refs_copy'
exit "\${FRAMEWORK_RC:-0}"
EOF
  cat > "$bin/lefthook" <<EOF
#!/bin/sh
printf '%s\\n' lefthook >> '$marker'
exit 0
EOF
  chmod +x "$bin/pre-commit" "$bin/lefthook"
  path="$bin:$PATH"
  printf 'repos: []\n' > "$r/.pre-commit-config.yaml"
  printf 'fixture\n' > "$r/a.txt"
  (cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" && git add .pre-commit-config.yaml a.txt)
  (cd "$r" && env PATH="$path" FRAMEWORK_RC=9 git commit -m provider-negative) > "$log" 2>&1 </dev/null
  rc=$?; t_expect_rc 1 "$rc" 'real Git commit refuses declared framework failure'
  grep -q '^framework$' "$marker"; t_assert $? 'declared framework actually executed'
  if grep -q '^lefthook$' "$marker"; then t_fail 'PATH-only lefthook stole configured provider'; else t_ok 'PATH-only lefthook did not steal provider'; fi
  (cd "$r" && env PATH="$path" git commit -m provider-positive) > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'real Git commit succeeds when declared provider succeeds'
  remote="$GG_T_TMPROOT/framework-remote.git"
  git init --bare -q "$remote"
  (cd "$r" && git remote add fixture "$remote")
  (cd "$r" && env PATH="$path" FRAMEWORK_RC=8 git push fixture HEAD:refs/heads/main) > "$log" 2>&1
  t_expect_rc 1 "$?" 'real Git push refuses framework failure before updating bare remote'
  if git --git-dir="$remote" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
    t_fail 'failed provider still published the ref'
  else
    t_ok 'failed provider did not publish a ref'
  fi
  (cd "$r" && env PATH="$path" git push fixture HEAD:refs/heads/main) > "$log" 2>&1
  t_expect_rc 0 "$?" 'real Git push publishes after framework success'
  head="$(git -C "$r" rev-parse HEAD)"
  zero=0000000000000000000000000000000000000000
  record="refs/heads/main $head refs/heads/main $zero"
  printf '%s\n' "$record" | (cd "$r" && env PATH="$path" FRAMEWORK_RC=8 sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 8 "$?" 'pre-push propagates framework failure'
  grep -qxF "$record" "$refs_copy"; t_assert $? 'complete original pre-push stdin reached provider'
  grep -qxF 'pre-push' "$args_copy"; t_assert $? 'provider received correct hook stage'
  grep -qxF 'inert://no-network' "$args_copy"; t_assert $? 'provider received original remote argv'

  missing="$GG_T_TMPROOT/framework-missing-bin"
  mkdir -p "$missing"
  for tool in git sh dirname cat grep sed awk sort uniq tr cut head tail wc find xargs mkdir rm mv cp chmod mktemp date uname sleep touch stat id; do
    actual="$(command -v "$tool")" || return 1
    # POSIX-safe wrappers keep only declared fixture tools on PATH.
    actual="$(printf '%s' "$actual" | sed "s/'/'\\\\''/g")"
    printf '#!/bin/sh\nexec '\''%s'\'' "$@"\n' "$actual" > "$missing/$tool"
    chmod +x "$missing/$tool"
  done
  (cd "$r" && env PATH="$missing" sh "$GG_ROOT/hooks/common/precommit-provider.sh" pre-commit) > "$log" 2>&1 </dev/null
  t_expect_rc 1 "$?" 'configured but missing framework refuses'
  grep -q 'not runnable' "$log"; t_assert $? 'missing framework refusal is loud'
  printf '#!/bin/sh\nexit 0\n' > "$missing/pre-commit"
  chmod -x "$missing/pre-commit"
  if gg_is_windows; then
    t_skip 'Unix non-executable framework mode is not tested on Windows'
  else
    (cd "$r" && env PATH="$missing" sh "$GG_ROOT/hooks/common/precommit-provider.sh" pre-commit) > "$log" 2>&1 </dev/null
    t_expect_rc 1 "$?" 'configured but non-executable framework refuses'
  fi

  printf 'dirty tracked source\n' >> "$r/a.txt"
  printf '%s\n' "$record" | (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 1 "$?" 'dirty tracked workspace cannot substitute for pushed HEAD'
  git -C "$r" restore a.txt
  previous="$head"
  printf 'next committed source\n' >> "$r/a.txt"
  (cd "$r" && git add a.txt && env PATH="$path" git commit -m next-source) > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'second current HEAD fixture committed'
  head="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/old %s refs/heads/old %s\n' "$previous" "$zero" | (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 1 "$?" 'other committed head cannot substitute current workspace'
  record="refs/heads/main $head refs/heads/main $zero"
  printf '%s\n%s\n' "$record" "refs/heads/other $head refs/heads/other $zero" | (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 1 "$?" 'multiple changed updates refuse the single-update framework seam'
  printf 'refs/heads/main %s refs/heads/main %s\n' "$zero" "$head" | (cd "$r" && env PATH="$path" FRAMEWORK_RC=8 sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 0 "$?" 'delete-only update does not execute software QA'
  printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$head" | (cd "$r" && env PATH="$path" FRAMEWORK_RC=8 sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 0 "$?" 'unchanged source does not execute software QA'
  (cd "$r" && git -c tag.gpgsign=false tag -a fixture-tag -m fixture-tag)
  tag="$(git -C "$r" rev-parse fixture-tag)"
  printf 'refs/tags/fixture-tag %s refs/tags/fixture-tag %s\n' "$tag" "$zero" | (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 0 "$?" 'annotated tag dereferences to current HEAD'

  git -C "$r" mv .pre-commit-config.yaml .pre-commit-config.yml
  (cd "$r" && env PATH="$path" git commit -m yml-config) > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'new staged .yml framework configuration remains committable'
  grep -qxF "$r/.pre-commit-config.yml" "$args_copy"; t_assert $? 'commit dispatch selects explicit .yml config'
  head="$(git -C "$r" rev-parse HEAD)"
  record="refs/heads/main $head refs/heads/main $zero"
  printf '%s\n' "$record" | (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 0 "$?" '.yml config belongs to pushed HEAD and reaches framework'
  grep -qxF "$r/.pre-commit-config.yml" "$args_copy"; t_assert $? 'push dispatch selects explicit .yml config'
  printf 'repos: []\n' > "$r/.pre-commit-config.yaml"
  (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'both supported configs keep deterministic selection'
  grep -qxF "$r/.pre-commit-config.yaml" "$args_copy"; t_assert $? '.yaml takes documented precedence over .yml'
  rm "$r/.pre-commit-config.yaml"
  git -C "$r" mv .pre-commit-config.yml .pre-commit-config.yaml
  (cd "$r" && env PATH="$path" git commit -m yaml-precedence-fixture) > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'canonical .yaml fixture committed for provider precedence controls'
  head="$(git -C "$r" rev-parse HEAD)"
  record="refs/heads/main $head refs/heads/main $zero"

  printf 'pre-commit:\n  commands: {}\n' > "$r/lefthook.yml"
  : > "$marker"
  (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'declared lefthook keeps existing precedence'
  grep -qxF lefthook "$marker"; t_assert $? 'declared lefthook ran alone'
  # The explicitly allowed missing lefthook is a skip of that provider, not
  # permission to substitute an unrelated configured framework.
  : > "$marker"
  (cd "$r" && env PATH="$missing" GIT_GUARD_ALLOW_MISSING_LEFTHOOK=1 sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'allowed missing declared lefthook keeps commit skip semantics'
  printf '%s\n' "$record" | (cd "$r" && env PATH="$missing" GIT_GUARD_ALLOW_MISSING_LEFTHOOK=1 sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
  t_expect_rc 0 "$?" 'allowed missing declared lefthook keeps push skip semantics'
  if [ -s "$marker" ]; then t_fail 'another provider substituted for intentionally skipped lefthook'; else t_ok 'intentional provider skip did not substitute framework'; fi
  rm -f "$r/lefthook.yml"
  mkdir -p "$r/.git-guard"
  printf '#!/bin/sh\nexit 7\n' > "$r/.git-guard/pre-commit.local"
  chmod +x "$r/.git-guard/pre-commit.local"
  (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
  t_expect_rc 7 "$?" 'explicit local repository QA retains precedence'
  (cd "$r" && env PATH="$path" GIT_GUARD=0 sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'documented emergency bypass remains available'
  rm -f "$r/.git-guard/pre-commit.local" "$r/.pre-commit-config.yaml" "$r/.pre-commit-config.yml"
  # A declaration is not absence just because its target is broken. Test
  # both stages and extensions before a PATH-only provider could steal it.
  if gg_is_windows; then
    t_skip 'Unix symlink fixture semantics are not qualified on Windows'
  else
    for extension in yaml yml; do
      ln -s missing-config "$r/.pre-commit-config.$extension"
      (cd "$r" && env PATH="$path" FRAMEWORK_RC=77 sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
      t_expect_rc 1 "$?" "$extension broken declared config refuses commit"
      printf '%s\n' "$record" | (cd "$r" && env PATH="$path" FRAMEWORK_RC=77 sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
      t_expect_rc 1 "$?" "$extension broken declared config refuses push"
      rm "$r/.pre-commit-config.$extension"
    done
    ln -s missing-config "$r/.pre-commit-config.yaml"
    printf 'repos: []\n' > "$r/.pre-commit-config.yml"
    (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
    t_expect_rc 1 "$?" 'broken yaml priority cannot substitute runnable yml'
    rm "$r/.pre-commit-config.yaml" "$r/.pre-commit-config.yml"
    mkdir "$r/.pre-commit-config.yaml"
    (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
    t_expect_rc 1 "$?" 'directory declaration refuses before provider dispatch'
    rmdir "$r/.pre-commit-config.yaml"
    printf 'repos: []\n' > "$r/linked-config.yml"
    ln -s linked-config.yml "$r/.pre-commit-config.yaml"
    (cd "$r" && git add .pre-commit-config.yaml linked-config.yml && env PATH="$path" git commit -m linked-config-fixture) > "$log" 2>&1 </dev/null
    t_expect_rc 0 "$?" 'valid newly staged linked config keeps commit framework semantics'
    head="$(git -C "$r" rev-parse HEAD)"
    record="refs/heads/main $head refs/heads/main $zero"
    printf '%s\n' "$record" | (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$log" 2>&1
    t_expect_rc 1 "$?" 'linked configuration refuses pushed-source admission'
    rm "$r/.pre-commit-config.yaml"
  fi
  (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/pre-commit") > "$log" 2>&1 </dev/null
  t_expect_rc 0 "$?" 'repo without framework declaration is unaffected'
  (cd "$r" && env PATH="$path" sh "$GG_ROOT/hooks/common/precommit-provider.sh" pre-commit) > "$log" 2>&1 </dev/null
  t_expect_rc 1 "$?" 'provider configuration disappearing fails loudly'

  # Exercise the actual installer admission function against private trees.
  # Old releases without the new dispatcher remain installable.
  sed -n '/^qa_verify_materialized_tree() {/,/^}/p' "$GG_ROOT/install.sh" > "$GG_T_TMPROOT/provider-installer.sh"
  . "$GG_T_TMPROOT/provider-installer.sh"
  tree="$GG_T_TMPROOT/provider-materialized"
  mkdir -p "$tree/hooks/common"
  printf '#!/bin/sh\n# precommit-provider.sh\nexit 0\n' > "$tree/hooks/pre-commit"
  printf '#!/bin/sh\nexit 0\n' > "$tree/hooks/pre-push"
  printf '#!/bin/sh\nexit 0\n' > "$tree/hooks/common/qa_gate.sh"
  printf '#!/bin/sh\nexit 0\n' > "$tree/hooks/common/precommit-provider.sh"
  chmod +x "$tree/hooks/pre-commit"
  qa_verify_materialized_tree "$tree" > "$log" 2>&1
  t_expect_rc 0 "$?" 'installer admits a complete dispatcher tree'
  rm "$tree/hooks/common/precommit-provider.sh"
  qa_verify_materialized_tree "$tree" > "$log" 2>&1
  t_expect_rc 2 "$?" 'installer refuses a referenced missing helper before current changes'
  printf 'if [\n' > "$tree/hooks/common/precommit-provider.sh"
  qa_verify_materialized_tree "$tree" > "$log" 2>&1
  t_expect_rc 2 "$?" 'installer refuses a malformed new helper'
  printf '#!/bin/sh\nexit 0\n' > "$tree/hooks/pre-commit"
  qa_verify_materialized_tree "$tree" > "$log" 2>&1
  t_expect_rc 0 "$?" 'older releases without dispatcher keep original admission semantics'
  gg_rmrepo "$r"; rm -f "$log"
}
