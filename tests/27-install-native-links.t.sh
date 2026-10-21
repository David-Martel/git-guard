#!/bin/sh
# Windows install/update must create native links, never MSYS deep copies.
# All releases, configs and links stay in a temporary clone/isolated HOME.
# Existing release tags are read only; no shared worktrees, refs or hooks change.
# shellcheck shell=sh

# Protects: real Windows symlinks and previous reachable install on link failures.
# Detects: MSYS deep copies and loss of original hooks/docs after late failures.
# Needs: native Git Bash, PowerShell and existing v0.2.7/v0.2.8 release tags.
# Breadcrumb: install.sh Windows link transaction and config publication.
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
  native_seed_rc=$?
  if [ "$native_seed_rc" != 0 ]; then
    cat "$native_case_root/baseline-seed.log" >&2
  fi
  t_expect_rc 0 "$native_seed_rc" "baseline old release installs with explicit native creation"
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
  mkdir -p "$native_source/tools/windows"
  cp "$GG_ROOT/tools/windows/set-hooks-config.ps1" "$native_source/tools/windows/set-hooks-config.ps1"
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

# Protects: installer updates retain the existing Windows config owner, group and
# DACL; equivalent hooksPath writes nothing; default/XDG config routing and
# foreign Git locks retain normal semantics; validated stages are not retained.
# Legacy AI normalization changes no other serialized descriptor field; actual
# displaced concurrent bytes/descriptors survive, and ambiguous paths refuse.
# Detects: native Git's rename drops custom security even when bytes are unchanged.
# Needs: native Git Bash, PowerShell7, native symlinks and an elevated token for
# deliberately distinct fixture owner/group. Every file stays in GG_T_TMPROOT.
# Breadcrumb: install.sh; tools/windows/set-hooks-config.ps1.
t_case_install_native_config_acl() {
  t_begin "27 Windows installer: global config identity and descriptor"
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*) : ;;
    *) t_skip "native Windows required for actual config descriptor qualification"; return 0 ;;
  esac
  if ! have pwsh || ! have cygpath; then
    t_skip "PowerShell7 and cygpath required for native descriptor qualification"; return 0
  fi
  if ! git -C "$GG_ROOT" rev-parse --verify refs/tags/v0.2.14 >/dev/null 2>&1; then
    t_fail "existing immutable v0.2.14 tag required for isolated installer fixture"; return 1
  fi
  config_acl_root="$(mktemp -d "$GG_T_TMPROOT/config-acl.XXXXXX")" || return 1
  GG_CONFIG_ACL_ROOT="$(cygpath -am "$config_acl_root")" || return 1
  GG_CONFIG_ACL_SOURCE="$(cygpath -am "$GG_ROOT")" || return 1
  GG_CONFIG_ACL_SH="$(cygpath -am "$(command -v sh)")" || return 1
  GG_CONFIG_ACL_GIT="$(cygpath -am "$(command -v git)")" || return 1
  export GG_CONFIG_ACL_ROOT GG_CONFIG_ACL_SOURCE GG_CONFIG_ACL_SH GG_CONFIG_ACL_GIT
  cat > "$config_acl_root/fixture.ps1" <<'PS'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output 'SKIP: elevated native token required for distinct fixture owner/group'
    exit 77
}
$user = $identity.User
$admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$script:failures = 0
function Assert-Actual {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Output "PASS $Message" }
    else { Write-Output "FAIL $Message"; $script:failures++ }
}
function Invoke-InertNative {
    param([string]$Executable, [string[]]$Arguments, [hashtable]$EnvironmentValues)
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($key in $EnvironmentValues.Keys) {
        if ($null -eq $EnvironmentValues[$key]) { $null = $start.Environment.Remove($key) }
        else { $start.Environment[$key] = $EnvironmentValues[$key] }
    }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill($true)
        if (-not $process.WaitForExit(5000)) { throw 'Owned inert installer fixture did not reap' }
        throw 'Owned inert installer fixture timed out'
    }
    if (-not [Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 5000)) {
        throw 'Inert installer fixture output did not drain'
    }
    [pscustomobject]@{ Exit = $process.ExitCode; Out = $stdout.Result; Error = $stderr.Result }
}
function Initialize-LegacyConfigParent {
    param([string]$Path)
    if ($null -eq ('GitGuardConfigFixture.LegacySecurity' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace GitGuardConfigFixture {
    public static class LegacySecurity {
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetFileSecurityW(string path, uint information, byte[] descriptor);
    }
}
'@
    }
    # Test-only obsolete API: reproduce a real legacy parent with no AI flag.
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new((Get-Acl -LiteralPath $Path).Sddl)
    $raw.SetFlags($raw.ControlFlags -band (-bnot 0x0400))
    $bytes = [byte[]]::new($raw.BinaryLength)
    $raw.GetBinaryForm($bytes, 0)
    if (-not [GitGuardConfigFixture.LegacySecurity]::SetFileSecurityW($Path, 4, $bytes)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    $actual = [Security.AccessControl.RawSecurityDescriptor]::new((Get-Acl -LiteralPath $Path).Sddl)
    if (($actual.ControlFlags -band 0x0400) -ne 0) { throw 'Legacy fixture parent still has AI' }
}
function Get-DescriptorBytes {
    param([Security.AccessControl.RawSecurityDescriptor]$Descriptor)
    $bytes = [byte[]]::new($Descriptor.BinaryLength)
    $Descriptor.GetBinaryForm($bytes, 0)
    return ,$bytes
}
function Add-ForwardAi {
    param([byte[]]$Bytes)
    $copy = [byte[]]$Bytes.Clone()
    $copy[3] = $copy[3] -bor 4
    return ,$copy
}
$helper = Join-Path $env:GG_CONFIG_ACL_SOURCE 'tools/windows/set-hooks-config.ps1'
$parseTokens = $null
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$parseTokens, [ref]$parseErrors)
$comparison = @($helperAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-ConfigCopyDescriptor'
}, $true))
Assert-Actual ($comparison.Count -eq 1) 'canonical binary descriptor comparison is present exactly once'
if ($comparison.Count -eq 1) {
    . ([scriptblock]::Create($comparison[0].Extent.Text))
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new(
        'O:' + $user.Value + 'G:' + $user.Value + 'D:(A;;FR;;;SY)(A;;FW;;;BA)S:(AU;SA;FR;;;WD)')
    $opaque = [Security.AccessControl.CommonAce]::new(
        [Security.AccessControl.AceFlags]::None, [Security.AccessControl.AceQualifier]::AccessAllowed,
        1, $user, $true, [byte[]]@(1, 2, 3, 4))
    $raw.DiscretionaryAcl.InsertAce(2, $opaque)
    $expected = Get-DescriptorBytes $raw
    Assert-Actual (Test-ConfigCopyDescriptor $expected $expected) 'binary guard accepts exact descriptor'
    $forward = Add-ForwardAi $expected
    Assert-Actual (Test-ConfigCopyDescriptor $expected $forward) 'binary guard accepts only forward AI'
    Assert-Actual (-not (Test-ConfigCopyDescriptor $forward $expected)) 'binary guard rejects removed AI'
    $other = [byte[]]$forward.Clone()
    $other[3] = $other[3] -bxor 0x10
    Assert-Actual (-not (Test-ConfigCopyDescriptor $expected $other)) 'binary guard rejects another control flag'
    foreach ($field in @('Owner', 'Group', 'AceOrder', 'Opaque', 'Sacl')) {
        $changed = [Security.AccessControl.RawSecurityDescriptor]::new($expected, 0)
        switch ($field) {
            Owner { $changed.Owner = [Security.Principal.SecurityIdentifier]::new(($user.Value -replace '-\d+$', '-2000')) }
            Group { $changed.Group = [Security.Principal.SecurityIdentifier]::new(($user.Value -replace '-\d+$', '-2000')) }
            AceOrder {
                $first = $changed.DiscretionaryAcl[0]
                $changed.DiscretionaryAcl.RemoveAce(0)
                $changed.DiscretionaryAcl.InsertAce(1, $first)
            }
            Opaque { $changed.DiscretionaryAcl[2].SetOpaque([byte[]]@(5, 2, 3, 4)) }
            Sacl { $changed.SystemAcl[0].AccessMask = $changed.SystemAcl[0].AccessMask -bxor 1 }
        }
        Assert-Actual (-not (Test-ConfigCopyDescriptor $expected (Add-ForwardAi (Get-DescriptorBytes $changed)))) "binary guard rejects $field change alongside AI"
    }
    $nullDacl = [Security.AccessControl.RawSecurityDescriptor]::new('O:SYG:BAD:NO_ACCESS_CONTROL')
    $nullBytes = Get-DescriptorBytes $nullDacl
    Assert-Actual (Test-ConfigCopyDescriptor $nullBytes (Add-ForwardAi $nullBytes)) 'binary guard retains represented null DACL'
    $nullDacl.DiscretionaryAcl = [Security.AccessControl.RawAcl]::new(2, 0)
    Assert-Actual (-not (Test-ConfigCopyDescriptor $nullBytes (Add-ForwardAi (Get-DescriptorBytes $nullDacl)))) 'binary guard rejects null-to-empty DACL'
}
$cases = @(
    @{ Name = 'unchanged-protected'; Changed = $false; Protected = $true },
    @{ Name = 'changed-protected'; Changed = $true; Protected = $true },
    @{ Name = 'unchanged-inherited'; Changed = $false; Protected = $false },
    @{ Name = 'changed-inherited'; Changed = $true; Protected = $false },
    @{ Name = 'changed-legacy-no-ai'; Changed = $true; Protected = $false; Legacy = $true },
    @{ Name = 'changed-xdg-only'; Changed = $true; Protected = $true; Xdg = $true },
    @{ Name = 'default-missing'; Changed = $false; Protected = $true; Defaults = $true },
    @{ Name = 'default-kept'; Changed = $true; Protected = $true; Defaults = $true; Keep = $true },
    @{ Name = 'foreign-lock'; Changed = $true; Protected = $true; Locked = $true },
    @{ Name = 'absent-default'; Absent = $true },
    @{ Name = 'absent-normal-defaults'; Absent = $true; Defaults = $true }
)
foreach ($case in $cases) {
    $homePath = Join-Path $env:GG_CONFIG_ACL_ROOT $case.Name
    $null = [IO.Directory]::CreateDirectory($homePath)
    $legacy = $case.ContainsKey('Legacy')
    if ($legacy) { Initialize-LegacyConfigParent $homePath }
    $hooks = Join-Path $homePath '.git-hooks'
    $absent = $case.ContainsKey('Absent')
    $xdg = $case.ContainsKey('Xdg')
    $defaults = $case.ContainsKey('Defaults')
    $keep = $case.ContainsKey('Keep')
    $config = Join-Path $homePath $(if ($absent) { '.gitconfig' } elseif ($xdg) { '.config/git/config' } else { 'explicit-global.config' })
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config))
    $posixHome = '/' + $homePath.Substring(0, 1).ToLowerInvariant() + $homePath.Substring(2).Replace('\', '/')
    $environmentValues = @{
        HOME = $posixHome
        GIT_CONFIG_GLOBAL = $(if ($absent -or $xdg) { $null } else { $config })
        GIT_CONFIG_NOSYSTEM = '1'
        XDG_CONFIG_HOME = $null
    }
    $beforeSddl = $null
    $beforeBytes = $null
    $beforeTime = $null
    if (-not $absent) {
        $oldHooks = if ($case.Changed) { Join-Path $homePath 'previous-hooks' } else { $hooks }
        [IO.File]::WriteAllText($config, "# retained comment" + [Environment]::NewLine +
            "[fixture]" + [Environment]::NewLine + " value = retained" + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false))
        $seed = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $config, 'core.hooksPath', $oldHooks) @{}
        if ($seed.Exit -ne 0) { throw "Fixture configuration failed: $($seed.Error)" }
        if ($keep) {
            foreach ($pair in @(@('fetch.prune', 'false'), @('hygiene.maxWorktrees', '7'), @('hygiene.exemptLockPrefix', 'operator-choice/'))) {
                $seed = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $config, $pair[0], $pair[1]) @{}
                if ($seed.Exit -ne 0) { throw 'Operator-choice fixture configuration failed' }
            }
        }
        if (-not $legacy) {
            $acl = Get-Acl -LiteralPath $config
            if ($case.Protected) { $acl.SetAccessRuleProtection($true, $false) }
            foreach ($sid in @($user, $admins, $system)) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
            }
            $acl.SetOwner($user)
            $acl.SetGroup($admins)
            Set-Acl -LiteralPath $config -AclObject $acl
        }
        if ($legacy) {
            $legacyDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new((Get-Acl -LiteralPath $config).Sddl)
            Assert-Actual (($legacyDescriptor.ControlFlags -band 0x0400) -eq 0) 'legacy config genuinely starts without AI'
        }
        [IO.File]::SetLastWriteTimeUtc($config, [DateTime]::UtcNow.AddDays(-2))
        $beforeSddl = (Get-Acl -LiteralPath $config).Sddl
        $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($config))
        $beforeTime = [IO.File]::GetLastWriteTimeUtc($config)
    }
    $locked = $case.ContainsKey('Locked')
    if ($locked) { [IO.File]::WriteAllText($config + '.lock', 'foreign fixture lock') }
    $installArguments = @((Join-Path $env:GG_CONFIG_ACL_SOURCE 'install.sh'), '--to', 'v0.2.14')
    if (-not $defaults) { $installArguments += '--no-git-defaults' }
    $run = Invoke-InertNative $env:GG_CONFIG_ACL_SH $installArguments $environmentValues
    if ($locked) {
        Assert-Actual ($run.Exit -eq 2) "$($case.Name): installer refuses another writer's lock"
        Assert-Actual ((Get-Acl -LiteralPath $config).Sddl -ceq $beforeSddl) "$($case.Name): descriptor remains original"
        Assert-Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq $beforeBytes) "$($case.Name): config bytes remain original"
        Assert-Actual ([IO.File]::ReadAllText($config + '.lock') -ceq 'foreign fixture lock') "$($case.Name): foreign lock content remains original"
        [IO.File]::Delete($config + '.lock') # only this fixture's own detecting-control file
        continue
    }
    Assert-Actual ($run.Exit -eq 0) "$($case.Name): actual installer succeeds; $($run.Error)"
    if (-not [IO.File]::Exists($config)) {
        Assert-Actual $false "$($case.Name): expected global destination exists"
        continue
    }
    $value = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $config, '--get', 'core.hooksPath') @{}
    Assert-Actual (($value.Exit -eq 0) -and
        ([IO.Path]::GetFullPath($value.Out.Trim()) -ieq [IO.Path]::GetFullPath($hooks))) "$($case.Name): native Git reads intended hooksPath"
    if (-not $absent) {
        if ($legacy -and $comparison.Count -eq 1) {
            $beforeRaw = [Security.AccessControl.RawSecurityDescriptor]::new($beforeSddl)
            Assert-Actual (Test-ConfigCopyDescriptor (Get-DescriptorBytes $beforeRaw) (Get-Acl -LiteralPath $config).GetSecurityDescriptorBinaryForm()) "$($case.Name): only forward AI allowed"
        } else {
            Assert-Actual ((Get-Acl -LiteralPath $config).Sddl -ceq $beforeSddl) "$($case.Name): original owner/group/DACL preserved"
        }
        $content = [IO.File]::ReadAllText($config)
        Assert-Actual ($content.Contains('# retained comment') -and $content.Contains('value = retained')) "$($case.Name): unrelated Git-serialized content retained"
        if (-not $case.Changed -and -not $defaults) {
            Assert-Actual (([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq $beforeBytes) -and
                ([IO.File]::GetLastWriteTimeUtc($config) -eq $beforeTime)) "$($case.Name): equivalent path never rewrites config"
        }
    }
    Assert-Actual (-not [IO.File]::Exists($config + '.lock')) "$($case.Name): no retained owned config lock"
    Assert-Actual (@([IO.Directory]::GetDirectories([IO.Path]::GetDirectoryName($config), '.git-guard-config.*')).Count -eq 0) "$($case.Name): validated transaction originals removed"
    Assert-Actual (@([IO.Directory]::GetFiles([IO.Path]::GetDirectoryName($config), '.git-guard-config-original.*')).Count -eq 0) "$($case.Name): no retained validated sibling original"
    $prune = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $config, '--get', 'fetch.prune') @{}
    if ($defaults) {
        Assert-Actual ($prune.Exit -eq 0 -and $prune.Out.Trim() -ceq $(if ($keep) { 'false' } else { 'true' })) "$($case.Name): missing default is added or operator choice retained"
        $limit = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $config, '--get', 'hygiene.maxWorktrees') @{}
        Assert-Actual ($limit.Exit -eq 0 -and $limit.Out.Trim() -ceq $(if ($keep) { '7' } else { '3' })) "$($case.Name): existing numeric choice wins over default"
        $prefix = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $config, '--get-all', 'hygiene.exemptLockPrefix') @{}
        $expectedPrefixes = if ($keep) { @('operator-choice/') } else { @('vigil.operator-release/', 'vigil.fleet-build/') }
        Assert-Actual ($prefix.Exit -eq 0 -and (($prefix.Out.Trim() -split '\r?\n') -join '|') -ceq ($expectedPrefixes -join '|')) "$($case.Name): existing multi-value choice wins over defaults"
        $defaultBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($config))
        $defaultDescriptor = (Get-Acl -LiteralPath $config).Sddl
        [IO.File]::SetLastWriteTimeUtc($config, [DateTime]::UtcNow.AddDays(-2))
        $defaultTime = [IO.File]::GetLastWriteTimeUtc($config)
        $repeat = Invoke-InertNative $env:GG_CONFIG_ACL_SH $installArguments $environmentValues
        Assert-Actual ($repeat.Exit -eq 0 -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq $defaultBytes -and
            [IO.File]::GetLastWriteTimeUtc($config) -eq $defaultTime -and
            (Get-Acl -LiteralPath $config).Sddl -ceq $defaultDescriptor) "$($case.Name): repeated default installation leaves config entirely untouched"
    } else {
        Assert-Actual ($prune.Exit -eq 1) "$($case.Name): opt-out never adds a default"
    }
}

# Instrument only a private exact-source copy at the real Replace boundary.
# This performs an actual noncooperating write after the production precheck;
# no production hook, timing race, mock filesystem or live config is involved.
$helperText = [IO.File]::ReadAllText($helper)
$bindingHome = Join-Path $env:GG_CONFIG_ACL_ROOT 'defaults-private-binding'
$null = [IO.Directory]::CreateDirectory($bindingHome)
$bindingConfig = Join-Path $bindingHome 'config'
$bindingRecord = Join-Path $bindingHome 'observed-global-path'
$bindingRead = Join-Path $bindingHome 'observed-global-read'
$bindingExit = Join-Path $bindingHome 'observed-global-exit'
$bindingScript = Join-Path $bindingHome 'record-defaults.sh'
$includedConfig = Join-Path $bindingHome 'choices.config'
[IO.File]::WriteAllText($includedConfig, '[fetch]' + [Environment]::NewLine + ' prune = false' + [Environment]::NewLine)
[IO.File]::WriteAllText($bindingConfig, '# private binding fixture' + [Environment]::NewLine +
    '[include]' + [Environment]::NewLine + ' path = choices.config' + [Environment]::NewLine)
$includedBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($includedConfig))
$originalGlobalRead = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--global', '--get', 'fetch.prune') @{
    GIT_CONFIG_GLOBAL = $bindingConfig; GIT_CONFIG_NOSYSTEM = '1'
}
$includedPositive = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--global', '--includes', '--get', 'fetch.prune') @{
    GIT_CONFIG_GLOBAL = $bindingConfig; GIT_CONFIG_NOSYSTEM = '1'
}
Assert-Actual ($includedPositive.Exit -eq 0 -and $includedPositive.Out.Trim() -ceq 'false') 'relative include fixture actually resolves with explicit includes'
$bindingBefore = (Get-Acl -LiteralPath $bindingConfig).Sddl
# Test-only child observation delegates every actual default to maintained code.
[IO.File]::WriteAllText($bindingScript,
    'printf "%s\n" "$GIT_CONFIG_GLOBAL" > "$GG_CONFIG_ACL_BINDING_RECORD"' + [char]10 +
    'git config --global --get fetch.prune > "$GG_CONFIG_ACL_BINDING_READ"; printf "%s" "$?" > "$GG_CONFIG_ACL_BINDING_EXIT"' + [char]10 +
    'exec /usr/bin/sh.exe "$GG_CONFIG_ACL_REAL_DEFAULTS" "$@"' + [char]10, [Text.UTF8Encoding]::new($false))
$run = Invoke-InertNative (Get-Process -Id $PID).Path @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helper,
    '-GitExecutable', $env:GG_CONFIG_ACL_GIT, '-ConfigPath', $bindingConfig,
    '-HooksPath', (Join-Path $bindingHome 'hooks'),
    '-DefaultsScript', $bindingScript, '-GitShell', $env:GG_CONFIG_ACL_SH
) @{
    GIT_CONFIG_GLOBAL = $bindingConfig; GIT_CONFIG_NOSYSTEM = '1'
    GG_CONFIG_ACL_BINDING_RECORD = $bindingRecord
    GG_CONFIG_ACL_BINDING_READ = $bindingRead
    GG_CONFIG_ACL_BINDING_EXIT = $bindingExit
    GG_CONFIG_ACL_REAL_DEFAULTS = (Join-Path $env:GG_CONFIG_ACL_SOURCE 'hooks/common/hygiene.sh')
}
Assert-Actual ($run.Exit -eq 0) "maintained defaults succeed through private global binding; $($run.Error)"
if ([IO.File]::Exists($bindingRecord)) {
    $observed = [IO.File]::ReadAllText($bindingRecord).Trim()
    Assert-Actual ([IO.Path]::IsPathFullyQualified($observed) -and
        [IO.Path]::GetFileName($observed) -ceq 'serialized.config' -and
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($observed)).StartsWith('.git-guard-config.') -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($observed)) -ieq $bindingHome -and
        $observed -ine $bindingConfig) 'defaults child sees only the exact private serialized global destination'
    Assert-Actual (-not [IO.File]::Exists($observed)) 'validated private default payload is removed'
} else { Assert-Actual $false 'defaults child emitted an actual environment observation' }
Assert-Actual ((Get-Acl -LiteralPath $bindingConfig).Sddl -ceq $bindingBefore) 'private defaults publication retains original security'
Assert-Actual ([IO.File]::ReadAllText($bindingExit) -ceq [string]$originalGlobalRead.Exit -and
    [IO.File]::ReadAllText($bindingRead) -ceq $originalGlobalRead.Out) 'private global read matches actual original relative-include behavior without redefining policy'
Assert-Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($includedConfig)) -ceq $includedBefore) 'defaults publication never rewrites included operator configuration'

# A real cooperative Git write after the early read must not make publication
# trust a stale equivalent hooksPath. This private copy instruments one boundary.
$prelockHome = Join-Path $env:GG_CONFIG_ACL_ROOT 'prelock-change'
$null = [IO.Directory]::CreateDirectory($prelockHome)
$prelockConfig = Join-Path $prelockHome 'config'
$prelockHooks = Join-Path $prelockHome 'hooks'
$seed = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $prelockConfig, 'core.hooksPath', $prelockHooks) @{}
if ($seed.Exit -ne 0) { throw 'Prelock fixture configuration failed' }
$lockNeedle = '    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)'
Assert-Actual (($helperText.Split(@($lockNeedle), [StringSplitOptions]::None).Count - 1) -eq 1) 'prelock seam matches exactly one canonical acquisition'
$prelockInjection = '    $writer = Invoke-ConfigProcess -Executable $GitExecutable -Arguments @("config", "--file", $ConfigPath, "core.hooksPath", ($HooksPath + "-concurrent"))' + [Environment]::NewLine +
    '    if ($writer.Exit -ne 0) { throw "Actual cooperative prelock fixture writer failed" }'
$prelockHelper = Join-Path $prelockHome 'instrumented-helper.ps1'
[IO.File]::WriteAllText($prelockHelper, $helperText.Replace($lockNeedle, $prelockInjection + [Environment]::NewLine + $lockNeedle), [Text.UTF8Encoding]::new($false))
$run = Invoke-InertNative (Get-Process -Id $PID).Path @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $prelockHelper,
    '-GitExecutable', $env:GG_CONFIG_ACL_GIT, '-ConfigPath', $prelockConfig, '-HooksPath', $prelockHooks,
    '-DefaultsScript', (Join-Path $env:GG_CONFIG_ACL_SOURCE 'hooks/common/hygiene.sh'), '-GitShell', $env:GG_CONFIG_ACL_SH
) @{ GIT_CONFIG_GLOBAL = $prelockConfig; GIT_CONFIG_NOSYSTEM = '1' }
Assert-Actual ($run.Exit -eq 0) "actual prelock writer/default publication succeeds; $($run.Error)"
$publishedHooks = Invoke-InertNative $env:GG_CONFIG_ACL_GIT @('config', '--file', $prelockConfig, '--get', 'core.hooksPath') @{}
Assert-Actual ($publishedHooks.Exit -eq 0 -and [IO.Path]::GetFullPath($publishedHooks.Out.Trim()) -ieq $prelockHooks) 'publication recomputes intended hooksPath from captured preimage after prelock write'
foreach ($suffix in @(' ', '.')) {
    $ambiguousHome = Join-Path $env:GG_CONFIG_ACL_ROOT ('ambiguous-' + [int][char]$suffix)
    $null = [IO.Directory]::CreateDirectory($ambiguousHome)
    $normal = Join-Path $ambiguousHome 'config'
    [IO.File]::WriteAllText($normal, '[fixture]' + [Environment]::NewLine + ' value = retained')
    $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($normal))
    $beforeDescriptor = (Get-Acl -LiteralPath $normal).Sddl
    $run = Invoke-InertNative (Get-Process -Id $PID).Path @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helper,
        '-GitExecutable', $env:GG_CONFIG_ACL_GIT, '-ConfigPath', ($normal + $suffix),
        '-HooksPath', (Join-Path $ambiguousHome 'hooks')
    ) @{ GIT_CONFIG_GLOBAL = $normal; GIT_CONFIG_NOSYSTEM = '1' }
    Assert-Actual ($run.Exit -ne 0 -and $run.Error.Contains('before normalization')) "ambiguous suffix $([int][char]$suffix) refuses before normalization"
    Assert-Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($normal)) -ceq $beforeBytes) 'ambiguous destination leaves canonical config bytes untouched'
    Assert-Actual ((Get-Acl -LiteralPath $normal).Sddl -ceq $beforeDescriptor) 'ambiguous destination leaves canonical descriptor untouched'
    Assert-Actual (-not [IO.File]::Exists($normal + '.lock') -and
        @([IO.Directory]::GetDirectories($ambiguousHome, '.git-guard-config.*')).Count -eq 0) 'ambiguous destination creates no stage or lock'
}
$needle = '        [IO.File]::Replace($lockPath, $ConfigPath, $original, $false)'
Assert-Actual (($helperText.Split(@($needle), [StringSplitOptions]::None).Count - 1) -eq 1) 'race seam matches exactly one canonical Replace boundary'
foreach ($mutation in @('bytes', 'descriptor')) {
    $raceHome = Join-Path $env:GG_CONFIG_ACL_ROOT ('race-' + $mutation)
    $null = [IO.Directory]::CreateDirectory($raceHome)
    $raceConfig = Join-Path $raceHome 'config'
    [IO.File]::WriteAllText($raceConfig, '[fixture]' + [Environment]::NewLine + ' value = original' + [Environment]::NewLine)
    $sourceBefore = [IO.File]::ReadAllText($raceConfig)
    $sourceDescriptor = (Get-Acl -LiteralPath $raceConfig).Sddl
    $injection = if ($mutation -ceq 'bytes') {
        '        [IO.File]::AppendAllText($ConfigPath, "# concurrent writer retained" + [Environment]::NewLine)'
    } else {
        '        $raceAcl = Get-Acl -LiteralPath $ConfigPath' + [Environment]::NewLine +
        '        $raceAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new("S-1-1-0"), "Read", "Allow"))' + [Environment]::NewLine +
        '        Set-Acl -LiteralPath $ConfigPath -AclObject $raceAcl'
    }
    $instrumented = Join-Path $raceHome 'instrumented-helper.ps1'
    [IO.File]::WriteAllText($instrumented, $helperText.Replace($needle, $injection + [Environment]::NewLine + $needle), [Text.UTF8Encoding]::new($false))
    $run = Invoke-InertNative (Get-Process -Id $PID).Path @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $instrumented,
        '-GitExecutable', $env:GG_CONFIG_ACL_GIT, '-ConfigPath', $raceConfig,
        '-HooksPath', (Join-Path $raceHome 'hooks')
    ) @{ GIT_CONFIG_GLOBAL = $raceConfig; GIT_CONFIG_NOSYSTEM = '1' }
    Assert-Actual ($run.Exit -ne 0 -and $run.Error.Contains('Actual displaced original differs')) "$mutation race refuses after actual displaced check"
    $transactions = @([IO.Directory]::GetFiles($raceHome, '.git-guard-config-original.*'))
    $displaced = if ($transactions.Count -eq 1) { $transactions[0] } else { '' }
    Assert-Actual ([IO.File]::Exists($displaced)) "$mutation race retains actual unique displaced original"
    if ([IO.File]::Exists($displaced)) {
        if ($mutation -ceq 'bytes') {
            Assert-Actual ([IO.File]::ReadAllText($displaced) -ceq ($sourceBefore + '# concurrent writer retained' + [Environment]::NewLine)) 'actual concurrent content survives'
            Assert-Actual ((Get-Acl -LiteralPath $displaced).Sddl -ceq $sourceDescriptor) 'data race retains exact displaced descriptor'
        } else {
            Assert-Actual ([IO.File]::ReadAllText($displaced) -ceq $sourceBefore) 'descriptor race retains exact displaced bytes'
            Assert-Actual ((Get-Acl -LiteralPath $displaced).Sddl -cne $sourceDescriptor) 'actual concurrent descriptor survives'
        }
    }
}
exit $(if ($script:failures -eq 0) { 0 } else { 1 })
PS
  pwsh -NoLogo -NoProfile -NonInteractive -File "$config_acl_root/fixture.ps1" \
    > "$config_acl_root/result.log" 2>&1
  config_acl_rc=$?
  cat "$config_acl_root/result.log"
  if [ "$config_acl_rc" = 77 ]; then
    t_skip "elevated native token required for distinct owner/group fixtures"; return 0
  fi
  t_expect_rc 0 "$config_acl_rc" "native unchanged/changed/default config publication preserves full descriptor"
}
