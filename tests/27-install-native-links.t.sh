#!/bin/sh
# Windows install/update must create native links, never MSYS deep copies.
# All releases, configs and links stay in a temporary clone/isolated HOME.
# Existing release tags are read only; no shared worktrees, refs or hooks change.
# shellcheck shell=sh

t_case_install_native_links() {
  t_begin "27 Windows installer: native links and fail-closed atomic update"
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*) : ;;
    *) t_skip "native MSYS/Git Bash required for actual Windows symlink qualification"; return 0 ;;
  esac

  native_case_root="$(mktemp -d "$GG_T_TMPROOT/native-install.XXXXXX")" || return 1
  native_source="$native_case_root/source"
  native_old=v0.2.7
  native_new=v0.2.8
  if ! git -c core.autocrlf=false clone -q --no-hardlinks "$GG_ROOT" "$native_source"; then
    t_fail "could not create isolated installer source clone"; return 1
  fi
  for native_tag in "$native_old" "$native_new"; do
    if ! git -C "$native_source" rev-parse --verify "refs/tags/$native_tag" >/dev/null 2>&1; then
      t_fail "existing release tag $native_tag required for Windows qualification"; return 1
    fi
  done

  # Original release installer is the detecting control. Seed a valid native
  # current link, then reproduce default MSYS copying on its next atomic swap.
  git -C "$native_source" show "$native_new:install.sh" > "$native_source/install.sh"
  native_home="$native_case_root/baseline-home"
  mkdir -p "$native_home"
  native_store="$native_home/.local/share/git-guard"
  native_hooks="$native_home/.git-hooks"
  (
    export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    MSYS=winsymlinks:nativestrict sh "$native_source/install.sh" --to "$native_old"
  ) > "$native_case_root/baseline-seed.log" 2>&1
  t_expect_rc 0 "$?" "baseline old release installs with explicit native creation"
  native_config_before="$(gg_sha "$native_home/.gitconfig")"
  (
    export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    unset MSYS
    sh "$native_source/install.sh" --to "$native_new"
  ) > "$native_case_root/baseline-default-update.log" 2>&1
  native_rc=$?
  [ "$native_rc" != 0 ] && t_ok "original default Windows update detects the copied-directory failure" \
    || t_fail "original release installer did not reproduce the Windows update failure"
  [ "$(readlink "$native_store/current")" = "$native_store/$native_old" ] \
    && t_ok "detecting control preserves previous current target" || t_fail "baseline changed current"
  [ "$(gg_sha "$native_home/.gitconfig")" = "$native_config_before" ] \
    && t_ok "detecting control preserves isolated global configuration" || t_fail "baseline changed config"

  cp "$GG_ROOT/install.sh" "$native_source/install.sh"
  (
    export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    unset MSYS
    sh "$native_source/bin/git-guard" update --to "$native_new"
  ) > "$native_case_root/fixed-default-update.log" 2>&1
  t_expect_rc 0 "$?" "fixed CLI update succeeds without manual MSYS configuration"
  [ -L "$native_store/current" ] && [ "$(readlink "$native_store/current")" = "$native_store/$native_new" ] \
    && t_ok "fixed update atomically promotes a real link to the new release" || t_fail "fixed current invalid"
  [ -f "$native_store/$native_old/hooks/pre-commit" ] \
    && t_ok "previous immutable release remains present" || t_fail "previous release removed"

  # A fresh default install exercises every link, rather than relying on the
  # detecting control's already-native hooks/doc links.
  native_home="$native_case_root/fresh-home"
  mkdir -p "$native_home"
  native_store="$native_home/.local/share/git-guard"
  native_hooks="$native_home/.git-hooks"
  (
    export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    unset MSYS
    sh "$native_source/install.sh" --to "$native_new"
  ) > "$native_case_root/fixed-fresh-install.log" 2>&1
  t_expect_rc 0 "$?" "fresh default Windows release install succeeds"
  for native_link in "$native_store/current" "$native_hooks" \
    "$native_home/.agents/QA_TOOLING.md" "$native_home/.agents/GIT_COMMIT_SAFETY.md"; do
    [ -L "$native_link" ] && t_ok "real symlink: $native_link" || t_fail "copied/non-link: $native_link"
  done
  if have pwsh && have cygpath; then
    (
      GG_NATIVE_FIXTURE_HOME="$(cygpath -w "$native_home")" || exit 1
      export GG_NATIVE_FIXTURE_HOME
      pwsh -NoLogo -NoProfile -Command '
        $paths = @(".local/share/git-guard/current", ".git-hooks", ".agents/QA_TOOLING.md", ".agents/GIT_COMMIT_SAFETY.md")
        foreach ($path in $paths) {
          $item = Get-Item -Force -LiteralPath (Join-Path $env:GG_NATIVE_FIXTURE_HOME $path) -ErrorAction Stop
          if ($item.LinkType -ne "SymbolicLink") { throw "Expected native Windows SymbolicLink: $path" }
        }
      '
    ) > "$native_case_root/native-windows-link-types.log" 2>&1
    t_expect_rc 0 "$?" "native PowerShell recognizes all four Windows symlinks"
  else
    t_fail "pwsh/cygpath required to verify native Windows consumer link types"
  fi
  native_config_before="$(gg_sha "$native_home/.gitconfig")"
  native_hook_before="$(gg_sha "$native_hooks/pre-commit")"
  (
    export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    unset MSYS
    sh "$native_source/install.sh" --to "$native_new"
  ) > "$native_case_root/fixed-idempotent.log" 2>&1
  t_expect_rc 0 "$?" "repeated default install is idempotent"
  [ "$(gg_sha "$native_hooks/pre-commit")" = "$native_hook_before" ] \
    && [ "$(gg_sha "$native_home/.gitconfig")" = "$native_config_before" ] \
    && t_ok "idempotent install preserves hook/config bytes" || t_fail "idempotent bytes changed"

  # A controlled ln boundary observes actual child MSYS options and injects
  # privilege denial or a bogus successful copy. The installer itself is real.
  native_bin="$native_case_root/bin"
  mkdir -p "$native_bin"
  native_real_ln="$(command -v ln)"
  cat > "$native_bin/ln" <<'SH'
#!/bin/sh
printf '%s\n' "${MSYS:-}" >> "$GG_NATIVE_OPTIONS_LOG"
case "${GG_NATIVE_LINK_MODE:-}" in
  deny) echo 'fixture: native symlink privilege denied' >&2; exit 77 ;;
  copy) cp -R "$2" "$3"; exit $? ;;
  late)
    if [ "$3" = "$GG_NATIVE_FAIL_PATH" ]; then
      echo 'fixture: native symlink denied at final hooks/docs destination' >&2
      exit 77
    fi
    ;;
esac
exec "$GG_NATIVE_REAL_LN" "$@"
SH
  chmod +x "$native_bin/ln"
  native_options_log="$native_case_root/child-msys-options.log"
  (
    export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    export PATH="$native_bin:$PATH" GG_NATIVE_REAL_LN="$native_real_ln" GG_NATIVE_OPTIONS_LOG="$native_options_log"
    MSYS='winsymlinks:deepcopy noglob winsymlinks:native' sh "$native_source/install.sh" --to "$native_new"
  ) > "$native_case_root/preserve-msys-options.log" 2>&1
  t_expect_rc 0 "$?" "installer overrides conflicting symlink modes"
  grep -qx 'noglob winsymlinks:nativestrict' "$native_options_log" \
    && t_ok "child tools retain unrelated MSYS options and only native-strict symlinks" \
    || t_fail "MSYS options were discarded or conflicting modes survived"

  for native_mode in deny copy; do
    (
      export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
      export PATH="$native_bin:$PATH" GG_NATIVE_REAL_LN="$native_real_ln" GG_NATIVE_OPTIONS_LOG="$native_options_log"
      export GG_NATIVE_LINK_MODE="$native_mode"
      unset MSYS
      sh "$native_source/install.sh" --to "$native_old"
    ) > "$native_case_root/failure-$native_mode.log" 2>&1
    native_rc=$?
    t_expect_rc 2 "$native_rc" "native $native_mode failure is refused"
    [ "$(readlink "$native_store/current")" = "$native_store/$native_new" ] \
      && t_ok "$native_mode failure preserves current" || t_fail "$native_mode changed current"
    [ "$(gg_sha "$native_home/.gitconfig")" = "$native_config_before" ] \
      && t_ok "$native_mode failure preserves isolated global config" || t_fail "$native_mode changed config"
    grep -q 'native Windows symlink required' "$native_case_root/failure-$native_mode.log" \
      && t_ok "$native_mode failure explains required Windows symlink capability" \
      || t_fail "$native_mode failure missing actionable diagnostic"
  done

  # Deny each final destination after the new current link has already been
  # promoted. Existing real hook directories/docs files must be restored too.
  for native_destination in hooks qa safety; do
    native_home="$native_case_root/late-$native_destination-home"
    mkdir -p "$native_home"
    native_store="$native_home/.local/share/git-guard"
    native_hooks="$native_home/.git-hooks"
    (
      export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
      unset MSYS
      sh "$native_source/install.sh" --to "$native_new"
    ) > "$native_case_root/late-$native_destination-seed.log" 2>&1
    t_expect_rc 0 "$?" "$native_destination late-failure seed install succeeds"
    rm -f "$native_hooks" "$native_home/.agents/QA_TOOLING.md" "$native_home/.agents/GIT_COMMIT_SAFETY.md"
    mkdir "$native_hooks"
    printf 'original hook directory fixture\n' > "$native_hooks/pre-commit"
    printf 'original QA documentation fixture\n' > "$native_home/.agents/QA_TOOLING.md"
    printf 'original commit safety fixture\n' > "$native_home/.agents/GIT_COMMIT_SAFETY.md"
    native_config_before="$(gg_sha "$native_home/.gitconfig")"
    native_hook_before="$(gg_sha "$native_hooks/pre-commit")"
    native_qa_before="$(gg_sha "$native_home/.agents/QA_TOOLING.md")"
    native_safety_before="$(gg_sha "$native_home/.agents/GIT_COMMIT_SAFETY.md")"
    case "$native_destination" in
      hooks) native_fail_path="$native_hooks" ;;
      qa) native_fail_path="$native_home/.agents/QA_TOOLING.md" ;;
      safety) native_fail_path="$native_home/.agents/GIT_COMMIT_SAFETY.md" ;;
    esac
    (
      export HOME="$native_home" GIT_CONFIG_GLOBAL="$native_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
      export PATH="$native_bin:$PATH" GG_NATIVE_REAL_LN="$native_real_ln" GG_NATIVE_OPTIONS_LOG="$native_options_log"
      export GG_NATIVE_LINK_MODE=late GG_NATIVE_FAIL_PATH="$native_fail_path"
      unset MSYS
      sh "$native_source/install.sh" --to "$native_old"
    ) > "$native_case_root/late-$native_destination-failure.log" 2>&1
    t_expect_rc 2 "$?" "$native_destination creation failure after current promotion is refused"
    [ -L "$native_store/current" ] && [ "$(readlink "$native_store/current")" = "$native_store/$native_new" ] \
      && t_ok "$native_destination late failure restores reachable original current" \
      || t_fail "$native_destination late failure changed current"
    [ "$(gg_sha "$native_home/.gitconfig")" = "$native_config_before" ] \
      && t_ok "$native_destination late failure preserves original global config bytes" \
      || t_fail "$native_destination late failure changed config"
    [ ! -L "$native_hooks" ] && [ "$(gg_sha "$native_hooks/pre-commit")" = "$native_hook_before" ] \
      && t_ok "$native_destination late failure restores original hook directory" \
      || t_fail "$native_destination late failure lost original hooks"
    [ ! -L "$native_home/.agents/QA_TOOLING.md" ] && [ ! -L "$native_home/.agents/GIT_COMMIT_SAFETY.md" ] \
      && [ "$(gg_sha "$native_home/.agents/QA_TOOLING.md")" = "$native_qa_before" ] \
      && [ "$(gg_sha "$native_home/.agents/GIT_COMMIT_SAFETY.md")" = "$native_safety_before" ] \
      && t_ok "$native_destination late failure restores original docs files" \
      || t_fail "$native_destination late failure lost original docs"
  done
}
