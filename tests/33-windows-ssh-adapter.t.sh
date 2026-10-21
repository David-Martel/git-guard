#!/bin/sh
# Optional transport adapter; operational contract and scoped review register:
# ../docs/QA_TOOLING.md#optional-windows-git-ssh-adapter

# Protects: hidden children, explicit headless bounds, legacy argument/exit behavior.
# Detects: missing Windows hide, CI-only restrictions, dropped/rewritten arguments,
# an inert timeout, or false success. Needs: Node; no SSH/network/device.
# Breadcrumb: tools/windows/git-ssh-wrapper.js. Named Node selectors form this group.
t_case_windows_ssh_adapter() {
  t_begin "33 Windows SSH adapter process contract"
  if ! have node; then t_skip "Windows SSH adapter: Node unavailable"; return 0; fi
  node <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const source = fs.readFileSync(path.join(process.env.GG_ROOT, 'tools/windows/git-ssh-wrapper.js'), 'utf8');
let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS ${name}`); }
  catch (error) { failures++; console.error(`FAIL ${name}: ${error.message}`); }
}
function invoke(env, args, execute = () => ({ status: 0 })) {
  let actual;
  const messages = [];
  const sandbox = {
    require(name) {
      assert.equal(name, 'node:child_process');
      return { spawnSync(file, argv, options) {
        actual = { file, argv, options };
        return execute(file, argv, options);
      } };
    },
    process: { env, argv: ['node', 'wrapper', ...args], exit(code) { throw { adapterExit: code }; } },
    console: { error(message) { messages.push(message); } },
  };
  let exit;
  try { vm.runInNewContext(source, sandbox, { timeout: 1000 }); }
  catch (error) {
    if (!Object.hasOwn(error, 'adapterExit')) throw error;
    exit = error.adapterExit;
  }
  // Cross-context arrays/objects have distinct prototypes; compare plain data.
  return { actual: JSON.parse(JSON.stringify(actual)), messages, exit };
}
check('interactive_hides_without_restricting_prompt_or_lifetime', () => {
  const result = invoke({}, ['git@host', "git-upload-pack 'repo name.git'"]);
  assert.equal(result.actual.options.windowsHide, true);
  assert.equal(result.actual.options.stdio, 'inherit');
  assert.equal(result.actual.options.timeout, undefined);
  assert.deepEqual(result.actual.argv, ['git@host', 'git-upload-pack repo name.git']);
  assert.equal(result.exit, 0);
});
check('ci_alone_retains_interactive_options', () => {
  const result = invoke({ CI: 'true', GIT_TERMINAL_PROMPT: '1' }, ['host']);
  assert.equal(result.actual.options.windowsHide, true);
  assert.equal(result.actual.options.timeout, undefined);
  assert.deepEqual(result.actual.argv, ['host']);
});
check('explicit_noninteractive_has_existing_fleet_bounds', () => {
  const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host', 'command']);
  assert.equal(result.actual.options.windowsHide, true);
  assert.equal(result.actual.options.timeout, 300000);
  assert.deepEqual(result.actual.argv, [
    '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3', 'host', 'command',
  ]);
});
check('real_child_roundtrips_arguments_and_exit_status', () => {
  const output = path.join(process.env.GG_T_TMPROOT, 'ssh-argv.json');
  const args = ['space value', 'quote"value', 'unicode-é', 'back\\slash', '', 'semi;$(literal)'];
  const result = invoke({}, args, (_file, argv, options) => spawnSync(process.execPath, [
    '-e', 'require("node:fs").writeFileSync(process.argv[1],JSON.stringify(process.argv.slice(2)));process.exit(23)',
    '--', output, ...argv,
  ], options));
  assert.deepEqual(JSON.parse(fs.readFileSync(output, 'utf8')), args);
  assert.equal(result.exit, 23);
});
check('split_pack_command_keeps_existing_normalization', () => {
  const result = invoke({}, ['-p', '443', 'host', 'git-upload-pack', "'owner/repo.git'"]);
  assert.deepEqual(result.actual.argv, ['-p', '443', 'host', 'git-upload-pack owner/repo.git']);
  assert.equal(result.actual.file, 'C:\\Windows\\System32\\OpenSSH\\ssh.exe');
});
check('real_child_timeout_is_finite_and_reports_failure', () => {
  const started = Date.now();
  const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host'], (_file, _argv, options) => {
    assert.equal(options.timeout, 300000);
    // Production duration checked above; shorten only at the executable boundary.
    // Child self-terminates after 1s even if the timeout regresses: RED cannot hang.
    return spawnSync(process.execPath, ['-e', 'Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,1000)'], {
      ...options, timeout: 80,
    });
  });
  assert.equal(result.exit, 1);
  assert.ok(result.messages.some(message => /ETIMEDOUT/.test(message)));
  assert.ok(Date.now() - started < 2000);
});
check('spawn_error_and_signal_do_not_become_success', () => {
  assert.equal(invoke({}, [], () => ({ status: null, error: new Error('inert failure') })).exit, 1);
  assert.equal(invoke({}, [], () => ({ status: null, signal: 'SIGTERM' })).exit, 1);
});
process.exitCode = failures ? 1 : 0;
NODE
  t_expect_rc 0 "$?" "SSH adapter named Node controls"
}

# Protects: opt-in, known-byte migration without changing config or foreign WIP.
# Detects: unrequested writes, accepting unknown bytes/source, ACL loss, or repeat
# install failure. Needs: native Windows, PowerShell7, Node. No SSH/network.
# Breadcrumb: tools/windows/install-git-ssh-wrapper.ps1; named fixture blocks below.
t_case_windows_ssh_adapter_install() {
  t_begin "33 Windows SSH adapter installer"
  if ! gg_is_windows || ! have pwsh || ! have node; then
    t_skip "SSH installer requires native Windows, PowerShell7 and Node"; return 0
  fi
  fixture="$GG_T_TMPROOT/ssh-adapter-install.ps1"
  cat > "$fixture" <<'PWSH'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $env:GG_T_TMPROOT 'ssh-install-fixture'
$source = Join-Path $root 'release'
$bin = Join-Path $root 'bin'
$adapter = Join-Path $source 'tools/windows'
[IO.Directory]::CreateDirectory($adapter) | Out-Null
[IO.Directory]::CreateDirectory($bin) | Out-Null
[IO.File]::WriteAllText((Join-Path $source '.git-guard-commit'), ('a' * 40))
[IO.File]::WriteAllText((Join-Path $source 'VERSION'), '0.0.0')
Copy-Item -LiteralPath (Join-Path $env:GG_ROOT 'tools/windows/git-ssh-wrapper.js') -Destination $adapter
Copy-Item -LiteralPath (Join-Path $env:GG_ROOT 'tools/windows/git-ssh-wrapper.cmd') -Destination $adapter
$script = Join-Path $env:GG_ROOT 'tools/windows/install-git-ssh-wrapper.ps1'
$legacyJs = @'
const { spawnSync } = require('node:child_process');

const sshExe = 'C:\\Windows\\System32\\OpenSSH\\ssh.exe';
const args = process.argv.slice(2);
const packCommands = new Set(['git-upload-pack', 'git-upload-archive', 'git-receive-pack']);

if (args.length > 1) {
  const lastIndex = args.length - 1;
  const lastArg = args[lastIndex];
  const previousArg = args[lastIndex - 1];

  if (packCommands.has(previousArg)) {
    args.splice(lastIndex - 1, 2, `${previousArg} ${lastArg.replace(/'/g, '')}`);
  } else if (/^(git-upload-pack|git-upload-archive|git-receive-pack)\s/.test(lastArg)) {
    args[lastIndex] = lastArg.replace(/'/g, '');
  }
}

const result = spawnSync(sshExe, args, { stdio: 'inherit' });

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}

process.exit(result.status ?? 1);
'@
# Exact observed legacy bytes are a fixture contract, not derived from new code.
$legacyJs = $legacyJs.Replace("`r`n", "`n") + "`n"
$js = Join-Path $bin 'git-ssh-wrapper.js'
$cmd = Join-Path $bin 'git-ssh-wrapper.cmd'
[IO.File]::WriteAllText($js, $legacyJs, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllBytes($cmd, [IO.File]::ReadAllBytes((Join-Path $adapter 'git-ssh-wrapper.cmd')))
function Assert-Equal($actual, $expected, [string]$why) {
    if ($actual -ne $expected) { throw "$why expected=$expected actual=$actual" }
}
Assert-Equal (Get-FileHash $js).Hash '46D2615192CB8EBAADBF2FA43DAB8B1C93FEFE79260F61FB8571FDBAFE7A2EF1' 'fixture legacy JS pin'
$before = (Get-FileHash $js).Hash
# Distinguish in-place preservation from a same-directory delete/recreate.
# Only this owned temporary fixture receives an explicit, protected descriptor.
$descriptor = Get-Acl -LiteralPath $js
$descriptor.SetAccessRuleProtection($true, $true)
$readSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
$descriptor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($readSid, [Security.AccessControl.FileSystemRights]::Read, [Security.AccessControl.AccessControlType]::Allow))
Set-Acl -LiteralPath $js -AclObject $descriptor
$acl = (Get-Acl -LiteralPath $js).Sddl
# plan_only_retains_legacy_bytes
$plan = & $script -SourceRoot $source -BinDirectory $bin
Assert-Equal $plan.Status 'Planned' 'default is read-only'
Assert-Equal (Get-FileHash $js).Hash $before 'plan modified JS'
# apply_promotes_validated_source_without_config_or_acl_change
$gitConfig = Join-Path $root 'gitconfig'
[IO.File]::WriteAllText($gitConfig, "[core]`n`thooksPath = unchanged`n")
$env:GIT_CONFIG_GLOBAL = $gitConfig
$configHash = (Get-FileHash $gitConfig).Hash
$result = & $script -SourceRoot $source -BinDirectory $bin -Apply
Assert-Equal $result.Status 'Installed' 'apply disposition'
Assert-Equal (Get-FileHash $js).Hash (Get-FileHash (Join-Path $adapter 'git-ssh-wrapper.js')).Hash 'installed JS'
Assert-Equal (Get-Acl -LiteralPath $js).Sddl $acl 'existing ACL'
Assert-Equal (Get-FileHash $gitConfig).Hash $configHash 'Git config unchanged'
# idempotent_install_has_no_redundant_backup
$again = & $script -SourceRoot $source -BinDirectory $bin -Apply
Assert-Equal $again.Status 'Current' 'repeat install'
Assert-Equal @(Get-ChildItem -LiteralPath $bin).Count 2 'no backup/extra files'
# unknown_launcher_is_preserved_and_refused
[IO.File]::WriteAllText($js, $legacyJs, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($cmd, 'unique launcher work')
$unknownCmd = (Get-FileHash $cmd).Hash
$rejected = $false
try { & $script -SourceRoot $source -BinDirectory $bin -Apply | Out-Null } catch { $rejected = $_.Exception.Message -match 'CMD.*unknown' }
Assert-Equal $rejected $true 'unknown launcher must fail'
Assert-Equal (Get-FileHash $cmd).Hash $unknownCmd 'foreign launcher preserved'
Assert-Equal (Get-FileHash $js).Hash $before 'launcher failure must not write JS'
[IO.File]::WriteAllBytes($cmd, [IO.File]::ReadAllBytes((Join-Path $adapter 'git-ssh-wrapper.cmd')))
# invalid_javascript_fails_before_target_writes
$newJs = Join-Path $adapter 'git-ssh-wrapper.js'
$newBytes = [IO.File]::ReadAllBytes($newJs)
[IO.File]::WriteAllText($newJs, 'const { invalid syntax')
$rejected = $false
try { & $script -SourceRoot $source -BinDirectory $bin -Apply | Out-Null } catch { $rejected = $_.Exception.Message -match 'syntax validation' }
Assert-Equal $rejected $true 'invalid JavaScript must fail'
Assert-Equal (Get-FileHash $js).Hash $before 'syntax failure must not write JS'
[IO.File]::WriteAllBytes($newJs, $newBytes)
# unknown_work_is_preserved_and_refused
[IO.File]::WriteAllText($js, 'unique local work')
$uniqueHash = (Get-FileHash $js).Hash
$rejected = $false
try { & $script -SourceRoot $source -BinDirectory $bin -Apply | Out-Null } catch { $rejected = $_.Exception.Message -match 'unknown|legacy' }
Assert-Equal $rejected $true 'unknown target must fail'
Assert-Equal (Get-FileHash $js).Hash $uniqueHash 'foreign work preserved'
# invalid_release_marker_does_not_touch_targets
[IO.File]::WriteAllText((Join-Path $source '.git-guard-commit'), 'not a commit')
$rejected = $false
try { & $script -SourceRoot $source -BinDirectory $bin -Apply | Out-Null } catch { $rejected = $_.Exception.Message -match 'materialized|commit' }
Assert-Equal $rejected $true 'invalid source must fail'
Assert-Equal (Get-FileHash $js).Hash $uniqueHash 'invalid source target preservation'
# timeout_cleanup_terminates_real_owned_child
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Installer did not parse for helper isolation' }
$drainHelper = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Receive-WrapperSyntaxOutput' }, $true)
if ($null -eq $drainHelper) { throw 'Missing production output-drain lifecycle helper' }
. ([scriptblock]::Create($drainHelper.Extent.Text))
$helper = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WrapperSyntaxCheck' }, $true)
if ($null -eq $helper) { throw 'Missing production syntax-check lifecycle helper' }
. ([scriptblock]::Create($helper.Extent.Text))
$nodeExe = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$childInfo = [Diagnostics.ProcessStartInfo]::new($nodeExe)
$childInfo.UseShellExecute = $false
$childInfo.CreateNoWindow = $true
$childInfo.RedirectStandardOutput = $true
$childInfo.RedirectStandardError = $true
$childInfo.ArgumentList.Add('-e')
$childInfo.ArgumentList.Add('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,1200)')
$clock = [Diagnostics.Stopwatch]::StartNew()
$rejected = $false
try { Invoke-WrapperSyntaxCheck -StartInfo $childInfo -TimeoutMilliseconds 80 } catch { $rejected = $_.Exception.Message -eq 'Node syntax validation timed out before any target write.' }
$clock.Stop()
Assert-Equal $rejected $true 'owned child timeout must fail'
if ($clock.ElapsedMilliseconds -gt 700) { throw "Timeout cleanup exceeded test bound: $($clock.ElapsedMilliseconds)ms" }
# held_pipe_drain_is_bounded
# Real pending pipe read, not an assumed Windows inheritance behavior. A finite
# writer closure bounds the old GetResult RED, including older supported .NET.
Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
public static class GitGuardPipeFixture {
    public static void CloseAfter(Stream stream, int milliseconds) {
        ThreadPool.QueueUserWorkItem(_ => {
            Thread.Sleep(milliseconds);
            stream.Dispose();
        });
    }
}
'@
$pipeName = 'git-guard-drain-' + [Guid]::NewGuid().ToString('N')
$server = [IO.Pipes.NamedPipeServerStream]::new($pipeName, [IO.Pipes.PipeDirection]::In, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
$client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::Out, [IO.Pipes.PipeOptions]::Asynchronous)
$connected = $server.WaitForConnectionAsync()
$client.Connect(1000)
if (-not $connected.Wait(1000)) { throw 'Local pipe fixture connection failed' }
$pipeReader = [IO.StreamReader]::new($server)
$pending = $pipeReader.ReadToEndAsync()
[GitGuardPipeFixture]::CloseAfter($client, 1200)
$complete = [Threading.Tasks.Task]::FromResult([string]'')
$clock.Restart()
$rejected = $false
$lastDiagnostic = ''
try {
    try { Receive-WrapperSyntaxOutput -Stdout $pending -Stderr $complete -TimeoutMilliseconds 80 } catch { $lastDiagnostic = $_.Exception.Message; $rejected = $lastDiagnostic -match 'drain' }
} finally {
    $client.Dispose()
    $pipeReader.Dispose()
}
$clock.Stop()
Assert-Equal $rejected $true "held pipe must fail finite drain ($lastDiagnostic, $($clock.ElapsedMilliseconds)ms)"
if ($clock.ElapsedMilliseconds -gt 700) { throw "Pipe drain exceeded test bound: $($clock.ElapsedMilliseconds)ms" }
Assert-Equal (Get-FileHash $js).Hash $uniqueHash 'lifecycle failures preserve targets'
'PASS installer plan/apply/ACL/config/idempotency/unknown/source/syntax controls'
PWSH
  pwsh -NoLogo -NoProfile -NonInteractive -File "$fixture"
  t_expect_rc 0 "$?" "SSH adapter installer controls"
}
