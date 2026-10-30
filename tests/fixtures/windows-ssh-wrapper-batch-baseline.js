const { spawnSync } = require('node:child_process');

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

// Optional Windows adapter contract/tests: docs/QA_TOOLING.md, tests/33-windows-ssh-adapter.t.sh.
// Keep interactive prompts/arguments unchanged. CI alone does not opt into headless restrictions.
const options = { stdio: 'inherit', windowsHide: true };
if (process.env.GIT_TERMINAL_PROMPT === '0') {
  args.unshift('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3');
  // Push SSH stays open during local pre-push QA. Allow a finite, provisional
  // 60min total push lifetime; other commands retain the 5min automation budget.
  // Callers can end either operation sooner.
  options.timeout = isPush ? 3600000 : 300000;
}
const result = spawnSync(sshExe, args, options);

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}

process.exit(result.status ?? 1);
