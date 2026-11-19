const { spawn, spawnSync } = require('node:child_process');
const { existsSync } = require('node:fs');

const windowsSsh = 'C:\\Windows\\System32\\OpenSSH\\ssh.exe';
const args = process.argv.slice(2);

// ssh(1) options that take a value; the first other argument is the destination.
const valueOptions = new Set('BbcDEeFIiJLlmOoPpQRSWw');
function destinationHost(argv) {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--') return (argv[i + 1] ?? '').replace(/^.*@/, '').toLowerCase();
    if (arg.length > 1 && arg.startsWith('-')) {
      for (let j = 1; j < arg.length; j++) {
        if (valueOptions.has(arg[j])) {
          if (j === arg.length - 1) i++;
          break;
        }
      }
      continue;
    }
    return arg.replace(/^.*@/, '').toLowerCase();
  }
  return '';
}

// Windows OpenSSH (9.5p2 and 10.4.0.0p1) hung after git-upload-pack when no console was
// attached (sshd sessions), while Git for Windows' bundled OpenSSH finished in about 1s
// (dtm-p1gen7, dtm-super-nuc, 2026-11-11). Prefer the bundled client and fall back to
// Windows OpenSSH. The bundled client cannot reach the Windows ssh-agent pipe, so remote
// hosts named in GIT_GUARD_WINDOWS_SSH_HOSTS (separated by commas, semicolons or spaces;
// '*' for every host) keep Windows OpenSSH.
function selectSsh(env, host) {
  const windowsHosts = String(env.GIT_GUARD_WINDOWS_SSH_HOSTS ?? '')
    .split(/[\s,;]+/).map(name => name.toLowerCase()).filter(Boolean);
  if (windowsHosts.includes('*') || (host && windowsHosts.includes(host))) return windowsSsh;
  const roots = [];
  // Git sets GIT_EXEC_PATH to <git-root>/<mingw64|ucrt64|clangarm64>/libexec/git-core.
  const match = /^(.+)[\\/][^\\/]+[\\/]libexec[\\/]git-core[\\/]?$/i.exec(env.GIT_EXEC_PATH ?? '');
  if (match) roots.push(match[1].replace(/\//g, '\\'));
  roots.push('C:\\Program Files\\Git');
  for (const root of roots) {
    const candidate = `${root}\\usr\\bin\\ssh.exe`;
    if (existsSync(candidate)) return candidate;
  }
  return windowsSsh;
}
const sshExe = selectSsh(process.env, destinationHost(args));
const packCommands = new Set(['git-upload-pack', 'git-upload-archive', 'git-receive-pack']);

if (args.length > 1) {
  const lastIndex = args.length - 1;
  const lastArg = args[lastIndex];
  const previousArg = args[lastIndex - 1];

  if (packCommands.has(previousArg)) {
    // Git supplies a remote-shell-encoded fragment, not a local filesystem path.
    // Join the split transport form verbatim; stripping quotes changes its meaning.
    args.splice(lastIndex - 1, 2, `${previousArg} ${lastArg}`);
  }
}

// Classify only the final remote command after the verbatim split-form join.
const isPush = args.length > 1 && /^git-receive-pack[ \t]/.test(args[args.length - 1]);
const isPack = args.length > 1
  && /^(git-upload-pack|git-upload-archive|git-receive-pack)[ \t]/.test(args[args.length - 1]);

// Optional Windows adapter contract/tests: docs/QA_TOOLING.md, tests/33-windows-ssh-adapter.t.sh.
// Keep interactive prompts and lifetime unchanged. CI alone does not opt into BatchMode.
const options = { stdio: 'inherit', windowsHide: true };
// Git pipes ssh stdin/stdout, so stderr is the only stream that can be a terminal.
// Without one, nothing can answer or interrupt a stalled child (git-guard #90).
const promptDisabled = process.env.GIT_TERMINAL_PROMPT === '0';
const terminal = process.stderr.isTTY === true;
// Connect and keepalive bounds end only a dead connect or a dead link; they never cut a
// live transfer or a prompt, so every invocation gets them. Without them a stalled link
// hung an interactive-terminal fetch forever (dtm-p1gen7, 2026-11-11).
args.unshift('-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3');
if (promptDisabled) {
  args.unshift('-o', 'BatchMode=yes');
  // Push SSH stays open during local pre-push QA. Allow a finite, provisional
  // 60min total push lifetime; other commands retain the 5min automation budget.
  // Callers can end either operation sooner.
  options.timeout = isPush ? 3600000 : 300000;
}

// A Git server always speaks first (ref or capability advertisement), and
// receive-pack does so before pre-push runs. Without a terminal, bound only the
// wait for that first byte: it covers connect, auth, askpass and a pre-connect
// stall, while a long clone or pre-push gate after it is never cut. ServerAlive
// then ends a dead connection. Prompts stay available (mintty, askpass GUIs).
const firstResponseMilliseconds = 300000;
function runUntilFirstResponse() {
  const child = spawn(sshExe, args, { stdio: ['inherit', 'pipe', 'inherit'], windowsHide: true });
  let responded = false;
  let failed = false;
  const timer = setTimeout(() => {
    if (responded) return;
    console.error(`git-ssh-wrapper: no server response within ${firstResponseMilliseconds}ms; stopping ssh (git-guard #90)`);
    child.kill();
  }, firstResponseMilliseconds);
  child.stdout.once('data', () => { responded = true; clearTimeout(timer); });
  // process.stdout stays open; Git sees EOF when this process exits.
  child.stdout.pipe(process.stdout, { end: false });
  child.on('error', (error) => {
    failed = true;
    clearTimeout(timer);
    console.error(error.message);
    process.exitCode = 1;
  });
  child.on('close', (code) => {
    clearTimeout(timer);
    // A spawn error, signal or kill has no usable status; never report success.
    process.exitCode = !failed && Number.isInteger(code) && code >= 0 ? code : 1;
  });
}

if (!promptDisabled && !terminal && isPack) {
  runUntilFirstResponse();
} else {
  const result = spawnSync(sshExe, args, options);

  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }

  process.exit(result.status ?? 1);
}
