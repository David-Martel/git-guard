const { spawn, spawnSync } = require('node:child_process');

const sshExe = 'C:\\Windows\\System32\\OpenSSH\\ssh.exe';
const args = process.argv.slice(2);
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
// Keep interactive prompts/arguments unchanged. CI alone does not opt into BatchMode.
const options = { stdio: 'inherit', windowsHide: true };
// Git pipes ssh stdin/stdout, so stderr is the only stream that can be a terminal.
// Without one, nothing can answer or interrupt a stalled child (git-guard #90).
const promptDisabled = process.env.GIT_TERMINAL_PROMPT === '0';
const terminal = process.stderr.isTTY === true;
if (promptDisabled || !terminal) {
  args.unshift('-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3');
}
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
