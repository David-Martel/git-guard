#!/bin/sh
# Optional transport adapter; operational contract and scoped review register:
# ../docs/QA_TOOLING.md#optional-windows-git-ssh-adapter

# Protects: hidden children, headless bounds, Git remote quoting and exit behavior.
# Detects: missing Windows hide, CI-only restrictions, dropped/rewritten arguments,
# remote-shell splitting/injection, an inert timeout, an unbounded wait for the
# server when no terminal is attached (git-guard #90), a total cap on a long
# transfer that already started (mintty, long clones), or false success.
# Needs: Node and the suite's POSIX shell; no SSH/network/device.
# Breadcrumb: tools/windows/git-ssh-wrapper.js. Named Node selectors form this group.
t_case_windows_ssh_adapter() {
  t_begin "33 Windows SSH adapter process contract"
  if ! have node; then t_skip "Windows SSH adapter: Node unavailable"; return 0; fi
  probe_shell=$(command -v sh)
  if gg_is_windows && have cygpath; then probe_shell=$(cygpath -w "$probe_shell"); fi
  node - "$probe_shell" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawn, spawnSync } = require('node:child_process');
const { Writable } = require('node:stream');
const probeShell = process.argv[2];
const source = fs.readFileSync(path.join(process.env.GG_ROOT, 'tools/windows/git-ssh-wrapper.js'), 'utf8');
let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS ${name}`); }
  catch (error) { failures++; console.error(`FAIL ${name}: ${error.message}`); }
}
// Git always pipes ssh stdin/stdout, so stderr is the only stream that can
// carry a terminal. Default to an attached terminal; Node reports a missing
// one as undefined, not false, so the headless form mirrors that.
function invoke(env, args, execute = () => ({ status: 0 }), { terminal = true } = {}) {
  let actual;
  const messages = [];
  const sandbox = {
    require(name) {
      assert.equal(name, 'node:child_process');
      return {
        spawnSync(file, argv, options) {
          actual = { file, argv, options };
          return execute(file, argv, options);
        },
        spawn() { throw new Error('synchronous selector reached the first-response path'); },
      };
    },
    process: {
      env, argv: ['node', 'wrapper', ...args], stderr: { isTTY: terminal ? true : undefined },
      exit(code) { throw { adapterExit: code }; },
    },
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
  assert.deepEqual(result.actual.argv, ['git@host', "git-upload-pack 'repo name.git'"]);
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
const boundOptions = [
  '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
];
check('missing_terminal_non_pack_command_gets_ssh_bounds_only', () => {
  const result = invoke({ CI: 'true', GIT_TERMINAL_PROMPT: '1' }, ['host'], undefined, { terminal: false });
  assert.equal(result.actual.options.timeout, undefined);
  assert.equal(result.actual.options.windowsHide, true);
  assert.deepEqual(result.actual.argv, [...boundOptions, 'host']);
});
check('explicit_zero_with_terminal_still_restricts', () => {
  const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host', 'command'], undefined, { terminal: true });
  assert.equal(result.actual.options.timeout, 300000);
  assert.deepEqual(result.actual.argv, ['-o', 'BatchMode=yes', ...boundOptions, 'host', 'command']);
});
check('headless_push_forms_have_finite_pre_push_allowance', () => {
  for (const command of [
    ["git-receive-pack 'owner/repo.git'"],
    ['git-receive-pack', "'owner/repo.git'"],
  ]) {
    const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host', ...command]);
    assert.equal(result.actual.options.timeout, 3600000);
    assert.equal(result.actual.options.windowsHide, true);
    assert.equal(result.actual.options.stdio, 'inherit');
    assert.deepEqual(result.actual.argv, [
      '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
      '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
      'host', "git-receive-pack 'owner/repo.git'",
    ]);
  }
});
check('headless_fetch_and_other_commands_keep_five_minute_budget', () => {
  for (const command of [
    ["git-upload-pack 'owner/repo.git'"],
    ['git-upload-pack', "'owner/repo.git'"],
    ["git-upload-archive 'owner/repo.git'"],
    ['git-upload-archive', "'owner/repo.git'"],
    ["git-upload-pack 'owner/git-receive-pack repo.git'"],
    ["git-receive-pack-extra 'owner/repo.git'"],
    ["printf 'git-receive-pack owner/repo.git'"],
    ['git-receive-pack'],
  ]) {
    const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host', ...command]);
    assert.equal(result.actual.options.timeout, 300000, JSON.stringify(command));
    assert.deepEqual(result.actual.argv.slice(0, 8), [
      '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
      '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
    ]);
  }
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
check('split_pack_command_preserves_git_encoded_fragment', () => {
  const result = invoke({}, ['-p', '443', 'host', 'git-upload-pack', "'owner/repo.git'"]);
  assert.deepEqual(result.actual.argv, ['-p', '443', 'host', "git-upload-pack 'owner/repo.git'"]);
  assert.equal(result.actual.file, 'C:\\Windows\\System32\\OpenSSH\\ssh.exe');
});
// Hand-encoded Git remote-shell fragments. Stripping quotes must fail both
// transport forms, including apostrophes and harmless command substitutions.
const remotePaths = [
  { encoded: "'owner/repo; printf INERT_SIDE_EFFECT.git'", literal: 'owner/repo; printf INERT_SIDE_EFFECT.git' },
  { encoded: "'owner/space repo.git'", literal: 'owner/space repo.git' },
  { encoded: "'owner/$(printf INERT_SUBSTITUTION).git'", literal: 'owner/$(printf INERT_SUBSTITUTION).git' },
  { encoded: "'owner/`printf INERT_BACKTICK`.git'", literal: 'owner/`printf INERT_BACKTICK`.git' },
  { encoded: "'owner/it'\\''s repo.git'", literal: "owner/it's repo.git" },
  { encoded: "'owner/back\\slash \"double\".git'", literal: 'owner/back\\slash "double".git' },
];
function expectLiteralRemotePath(argv, literal) {
  const command = argv.at(-1);
  assert.match(command, /^(git-upload-pack|git-upload-archive|git-receive-pack)\s/);
  // Replace only the fixed pack executable with a shell builtin. The real,
  // hidden, bounded shell parses the adapter's untouched remote fragment;
  // no Git server or SSH is started, and every probe uses only inert printf.
  const script = command.replace(/^(git-upload-pack|git-upload-archive|git-receive-pack)/, 'set --')
    + '; printf \'%s\\n\' "$#"; printf \'%s\\0\' "$@"';
  const child = spawnSync(probeShell, ['-c', script], {
    encoding: 'utf8', windowsHide: true, timeout: 2000,
  });
  assert.ifError(child.error);
  assert.equal(child.status, 0, child.stderr);
  assert.equal(child.stderr, '');
  assert.equal(child.stdout, '1\n' + literal + '\0');
}
check('combined_remote_shell_paths_are_literal', () => {
  for (const verb of ['git-upload-pack', 'git-upload-archive', 'git-receive-pack']) {
    for (const fixture of remotePaths) {
      const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host', verb + ' ' + fixture.encoded]);
      assert.equal(result.actual.options.timeout, verb === 'git-receive-pack' ? 3600000 : 300000);
      expectLiteralRemotePath(result.actual.argv, fixture.literal);
    }
  }
});
check('split_remote_shell_paths_are_literal', () => {
  for (const verb of ['git-upload-pack', 'git-upload-archive', 'git-receive-pack']) {
    for (const fixture of remotePaths) {
      const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, ['host', verb, fixture.encoded]);
      assert.equal(result.actual.options.timeout, verb === 'git-receive-pack' ? 3600000 : 300000);
      expectLiteralRemotePath(result.actual.argv, fixture.literal);
    }
  }
});
check('real_child_timeout_is_finite_and_reports_failure', () => {
  const started = Date.now();
  for (const [args, budget] of [
    [['host'], 300000],
    [['host', "git-receive-pack 'owner/repo.git'"], 3600000],
  ]) {
    const result = invoke({ GIT_TERMINAL_PROMPT: '0' }, args, (_file, _argv, options) => {
      assert.equal(options.timeout, budget);
      // Production duration checked above; shorten only at the executable boundary.
      // Child self-terminates after 1s even if the timeout regresses: RED cannot hang.
      return spawnSync(process.execPath, ['-e', 'Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,1000)'], {
        ...options, timeout: 80,
      });
    });
    assert.equal(result.exit, 1);
    assert.ok(result.messages.some(message => /ETIMEDOUT/.test(message)));
  }
  assert.ok(Date.now() - started < 2000);
});
check('spawn_error_and_signal_do_not_become_success', () => {
  assert.equal(invoke({}, [], () => ({ status: null, error: new Error('inert failure') })).exit, 1);
  assert.equal(invoke({}, [], () => ({ status: null, signal: 'SIGTERM' })).exit, 1);
});
// No-terminal pack commands run asynchronously so the wrapper can see the
// server's first byte. Real inert children stand in for ssh.exe; only the
// 300000ms first-response timer is shortened, at the sandbox timer boundary.
function invokeAsync(env, args, execute, { firstResponseMs = 80 } = {}) {
  return new Promise((resolve, reject) => {
    let actual;
    let exitCode;
    let settled = false;
    const messages = [];
    const timers = [];
    const chunks = [];
    const guard = setTimeout(() => reject(new Error('wrapper did not settle within 3000ms')), 3000);
    const finish = (exit) => {
      if (settled) return;
      settled = true;
      clearTimeout(guard);
      resolve({ actual: JSON.parse(JSON.stringify(actual ?? null)), messages, timers, exit,
        stdout: Buffer.concat(chunks).toString() });
    };
    const sandboxProcess = {
      env, argv: ['node', 'wrapper', ...args], stderr: { isTTY: undefined },
      stdout: new Writable({ write(chunk, _encoding, done) { chunks.push(Buffer.from(chunk)); done(); } }),
      exit(code) { throw { adapterExit: code }; },
    };
    Object.defineProperty(sandboxProcess, 'exitCode', { get: () => exitCode, set(value) { exitCode = value; } });
    const sandbox = {
      require(name) {
        assert.equal(name, 'node:child_process');
        return {
          spawnSync() { throw new Error('no-terminal pack command took the synchronous path'); },
          spawn(file, argv, options) {
            actual = { file, argv, options };
            const child = execute(file, argv, options);
            // Run after the wrapper's own handlers have recorded the status.
            const settle = () => setImmediate(() => finish(exitCode));
            child.on('close', settle);
            child.on('error', settle);
            return child;
          },
        };
      },
      process: sandboxProcess,
      console: { error(message) { messages.push(message); } },
      setTimeout(fn, ms) { timers.push(ms); return setTimeout(fn, ms === 300000 ? firstResponseMs : ms); },
      clearTimeout(handle) { clearTimeout(handle); },
    };
    try { vm.runInNewContext(source, sandbox, { timeout: 1000 }); }
    catch (error) {
      clearTimeout(guard);
      if (Object.hasOwn(error, 'adapterExit')) { finish(error.adapterExit); return; }
      reject(error);
    }
  });
}
function inertChild(script, options) {
  return spawn(process.execPath, ['-e', script], options);
}
const sleep = ms => `Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,${ms})`;
const asyncChecks = [];
function checkAsync(name, fn) { asyncChecks.push([name, fn]); }
checkAsync('missing_terminal_pack_commands_wait_only_for_first_response', async () => {
  for (const [env, command] of [
    [{}, ["git-upload-pack 'owner/repo.git'"]],
    [{}, ['git-upload-pack', "'owner/repo.git'"]],
    [{}, ["git-receive-pack 'owner/repo.git'"]],
    [{}, ['git-receive-pack', "'owner/repo.git'"]],
    [{ TERM_PROGRAM: 'mintty' }, ["git-upload-pack 'owner/repo.git'"]],
    [{ CI: 'true', GIT_TERMINAL_PROMPT: '1' }, ["git-upload-archive 'owner/repo.git'"]],
  ]) {
    const result = await invokeAsync(env, ['host', ...command], (_file, _argv, options) =>
      inertChild('process.stdout.write("x")', options));
    const label = JSON.stringify([env, command]);
    assert.equal(result.actual.file, 'C:\\Windows\\System32\\OpenSSH\\ssh.exe', label);
    // Bounds only: prompts (mintty, askpass, passphrase) stay possible without the opt-in.
    assert.deepEqual(result.actual.argv, [...boundOptions, 'host', command.join(' ')], label);
    assert.deepEqual(result.actual.options.stdio, ['inherit', 'pipe', 'inherit'], label);
    assert.equal(result.actual.options.windowsHide, true, label);
    // No total lifetime; the only wrapper timer is the 5min first-response bound.
    assert.equal(result.actual.options.timeout, undefined, label);
    assert.deepEqual(result.timers, [300000], label);
    assert.equal(result.stdout, 'x', label);
    assert.equal(result.exit, 0, label);
  }
});
checkAsync('missing_terminal_transfer_after_first_byte_is_not_cut', async () => {
  // First byte, then silence well past the (shortened) first-response bound.
  const result = await invokeAsync({}, ['host', "git-receive-pack 'owner/repo.git'"], (_file, _argv, options) =>
    inertChild(`process.stdout.write("a");${sleep(400)};process.stdout.write("b")`, options));
  assert.equal(result.stdout, 'ab');
  assert.equal(result.exit, 0);
  assert.deepEqual(result.messages, []);
});
checkAsync('missing_terminal_silent_server_is_stopped', async () => {
  const started = Date.now();
  // The child self-exits 0 after 1s, so a removed kill reads as exit 0 and fails.
  const result = await invokeAsync({}, ['host', "git-upload-pack 'owner/repo.git'"], (_file, _argv, options) =>
    inertChild(sleep(1000), options));
  assert.equal(result.exit, 1);
  assert.ok(result.messages.some(message => /no server response within 300000ms.*#90/.test(message)),
    JSON.stringify(result.messages));
  assert.ok(Date.now() - started < 900, `took ${Date.now() - started}ms`);
});
checkAsync('missing_terminal_exit_status_and_spawn_error_propagate', async () => {
  const status = await invokeAsync({}, ['host', "git-upload-pack 'owner/repo.git'"], (_file, _argv, options) =>
    inertChild('process.stdout.write("x");process.exit(23)', options));
  assert.equal(status.exit, 23);
  const failed = await invokeAsync({}, ['host', "git-upload-pack 'owner/repo.git'"], (_file, argv, options) =>
    spawn(path.join(process.env.GG_T_TMPROOT, 'missing-ssh-executable'), argv, options));
  assert.equal(failed.exit, 1);
  assert.ok(failed.messages.some(message => /ENOENT/.test(message)), JSON.stringify(failed.messages));
});
(async () => {
  for (const [name, fn] of asyncChecks) {
    try { await fn(); console.log(`PASS ${name}`); }
    catch (error) { failures++; console.error(`FAIL ${name}: ${error.message}`); }
  }
  process.exitCode = failures ? 1 : 0;
})();
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
# known_push_baseline_upgrades_without_config_or_acl_change
# Exact predecessor bytes from 8a9fe8e0, not synthesized from the successor.
$pushBaseline = Join-Path $env:GG_ROOT 'tests/fixtures/windows-ssh-wrapper-push-baseline.js'
Assert-Equal (Get-FileHash $pushBaseline).Hash '27758C691F894F76EEFCFC59ED2939E90D15993682C872F1F464B0195B678183' 'push predecessor fixture pin'
[IO.File]::WriteAllBytes($js, [IO.File]::ReadAllBytes($pushBaseline))
$pushBaselineHash = (Get-FileHash $js).Hash
$plan = & $script -SourceRoot $source -BinDirectory $bin
Assert-Equal $plan.Status 'Planned' 'push predecessor plan'
Assert-Equal (Get-FileHash $js).Hash $pushBaselineHash 'push predecessor plan must not write'
$upgraded = & $script -SourceRoot $source -BinDirectory $bin -Apply
Assert-Equal $upgraded.Status 'Installed' 'push predecessor upgrade'
Assert-Equal (Get-FileHash $js).Hash (Get-FileHash (Join-Path $adapter 'git-ssh-wrapper.js')).Hash 'push predecessor installed JS'
Assert-Equal (Get-Acl -LiteralPath $js).Sddl $acl 'push predecessor ACL'
Assert-Equal (Get-FileHash $gitConfig).Hash $configHash 'push predecessor Git config unchanged'
$again = & $script -SourceRoot $source -BinDirectory $bin -Apply
Assert-Equal $again.Status 'Current' 'push predecessor repeat install'
Assert-Equal @(Get-ChildItem -LiteralPath $bin).Count 2 'push predecessor no backup/extra files'
# known_batch_baseline_upgrades_without_config_or_acl_change
# Exact predecessor bytes from 70946f0 (#84), bounded only under GIT_TERMINAL_PROMPT=0.
$batchBaseline = Join-Path $env:GG_ROOT 'tests/fixtures/windows-ssh-wrapper-batch-baseline.js'
Assert-Equal (Get-FileHash $batchBaseline).Hash '0B718434D540C476C5581BD8354E4D5A6D1A67EB2E8AD06FC5541F2238FBFA82' 'batch predecessor fixture pin'
[IO.File]::WriteAllBytes($js, [IO.File]::ReadAllBytes($batchBaseline))
$batchBaselineHash = (Get-FileHash $js).Hash
$plan = & $script -SourceRoot $source -BinDirectory $bin
Assert-Equal $plan.Status 'Planned' 'batch predecessor plan'
Assert-Equal (Get-FileHash $js).Hash $batchBaselineHash 'batch predecessor plan must not write'
$upgraded = & $script -SourceRoot $source -BinDirectory $bin -Apply
Assert-Equal $upgraded.Status 'Installed' 'batch predecessor upgrade'
Assert-Equal (Get-FileHash $js).Hash (Get-FileHash (Join-Path $adapter 'git-ssh-wrapper.js')).Hash 'batch predecessor installed JS'
Assert-Equal (Get-Acl -LiteralPath $js).Sddl $acl 'batch predecessor ACL'
Assert-Equal (Get-FileHash $gitConfig).Hash $configHash 'batch predecessor Git config unchanged'
$again = & $script -SourceRoot $source -BinDirectory $bin -Apply
Assert-Equal $again.Status 'Current' 'batch predecessor repeat install'
Assert-Equal @(Get-ChildItem -LiteralPath $bin).Count 2 'batch predecessor no backup/extra files'
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
