#!/bin/sh
# Category 14 — optional Git-config post-commit fallback and chain precedence.
# shellcheck shell=sh

gg_postcommit_fixture_run() {
  ( cd "$1" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_GUARD_DOWNSTREAM_POST_COMMIT="${2:-}" \
      sh "$GG_ROOT/hooks/post-commit" 'argument with spaces' 'second' >/dev/null 2>&1 )
}

t_case_postcommit_config() {
  t_begin "14 post-commit config fallback preserves chain precedence"
  r="$(gg_mktemp_repo)"
  chain_log="$(gg_tmp_log)"
  export GG_POSTCOMMIT_LOG="$chain_log"
  mkdir -p "$r/hooks with spaces"
  for kind in config environment local; do
    {
      printf '#!/bin/sh\n'
      printf 'printf "%%s\\n" "%s" "$@" >> "$GG_POSTCOMMIT_LOG"\n' "$kind"
      printf 'exit 7\n'
    } > "$r/hooks with spaces/$kind"
    chmod +x "$r/hooks with spaces/$kind"
  done

  gg_postcommit_fixture_run "$r"; rc=$?
  t_expect_rc 0 "$rc" "absent config is a non-fatal no-op"
  if [ ! -s "$chain_log" ]; then t_ok "absent config does not run a downstream hook"; else t_fail "absent config does not run a downstream hook"; fi

  git -C "$r" config gitGuard.downstreamPostCommit "$r/hooks with spaces/config"
  gg_postcommit_fixture_run "$r"; rc=$?
  t_expect_rc 0 "$rc" "configured downstream failure stays non-fatal"
  expected="$(printf 'config\nargument with spaces\nsecond')"
  if [ "$(cat "$chain_log")" = "$expected" ]; then t_ok "configured path and argument boundaries are preserved"; else t_fail "configured path and argument boundaries are preserved"; fi

  : > "$chain_log"
  git -C "$r" config gitGuard.downstreamPostCommit "$r/missing-hook"
  gg_postcommit_fixture_run "$r"; rc=$?
  t_expect_rc 0 "$rc" "missing configured path is ignored"
  if [ ! -s "$chain_log" ]; then t_ok "missing configured path runs no hook"; else t_fail "missing configured path runs no hook"; fi

  # Plain text has no executable permission on POSIX or executable signature
  # on Git Bash. Never weaken the assertion if this host treats it as runnable.
  printf 'ordinary non-executable text\n' > "$r/not-executable.txt"
  chmod 644 "$r/not-executable.txt"
  if [ ! -x "$r/not-executable.txt" ]; then t_ok "non-executable fixture is actually non-executable"; else t_fail "non-executable fixture is actually non-executable"; fi
  git -C "$r" config gitGuard.downstreamPostCommit "$r/not-executable.txt"
  gg_postcommit_fixture_run "$r"; rc=$?
  t_expect_rc 0 "$rc" "non-executable configured file is ignored"
  if [ ! -s "$chain_log" ]; then t_ok "non-executable configured file runs no hook"; else t_fail "non-executable configured file runs no hook"; fi

  git -C "$r" config gitGuard.downstreamPostCommit "$r/hooks with spaces/config"
  mkdir -p "$r/.git-guard"
  cp "$r/hooks with spaces/local" "$r/.git-guard/post-commit.local"
  chmod +x "$r/.git-guard/post-commit.local"
  gg_postcommit_fixture_run "$r"; rc=$?
  t_expect_rc 0 "$rc" "repository-local hook failure stays non-fatal"
  expected="$(printf 'local\nargument with spaces\nsecond')"
  if [ "$(cat "$chain_log")" = "$expected" ]; then t_ok "repository-local hook takes precedence over config"; else t_fail "repository-local hook takes precedence over config"; fi

  : > "$chain_log"
  gg_postcommit_fixture_run "$r" "$r/hooks with spaces/environment"; rc=$?
  t_expect_rc 0 "$rc" "environment hook failure stays non-fatal"
  expected="$(printf 'environment\nargument with spaces\nsecond')"
  if [ "$(cat "$chain_log")" = "$expected" ]; then t_ok "environment hook takes precedence over local and config"; else t_fail "environment hook takes precedence over local and config"; fi

  unset GG_POSTCOMMIT_LOG
  rm -f "$chain_log"
  gg_rmrepo "$r"
}
