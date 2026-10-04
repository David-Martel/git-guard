#!/bin/sh
#
# git-guard identity — per-agent SSH signing identity + authorship attestation.
#
# Every agent on a host commits as the same human author, so the commit
# signature is the only thing that can say WHICH agent made a commit. This
# script gives each (agent, host) its own ed25519 signing key, maps each key to
# a principal (= the agent id) in a versioned allowed_signers file, and checks
# that the `Agent:` trailer written by prepare-commit-msg names the same
# principal as the key that signed the commit.
#
# Usage: git-guard identity <subcommand> [args]
#
#   keygen <agent> [--dir D] [--host H]
#       Create ~/.ssh/agent-signing/<agent>@<host> (ed25519, no passphrase,
#       file 0600, dir 0700) unless it already exists. Prints ONLY the public
#       key and the GitHub registration command; never the private key.
#   env <agent> [--dir D] [--host H] [--allowed-signers F]
#       [--format sh|json|toml] [--allow-missing]
#       Print the GIT_CONFIG_COUNT/KEY_n/VALUE_n block (command scope: beats
#       repo-local config, keeps ~/.gitconfig and core.hooksPath) that makes
#       git sign with that agent's key, plus GIT_GUARD_AGENT.
#       json = a Claude Code settings.json "env" object;
#       toml = a Codex [shell_environment_policy.set] table.
#   status
#       What THIS process would sign with, which principal that maps to, and
#       which Agent trailer prepare-commit-msg would write.
#   allowed-signers path
#   allowed-signers show  [--file F]
#   allowed-signers check [--file F]
#   allowed-signers add <principal> <pubkey-file> [--file F]
#       Maintain the versioned allowed_signers file (default: this release's
#       identity/allowed_signers). `add` refuses to edit an installed release.
#   verify [--allowed-signers F] [--quiet] [--] <rev-args...>
#       Check the REAL signatures of a range (CI and pre-push). Exit codes:
#         0  every commit is signed by a known key whose principal matches its
#            Agent trailer (agent principal) or has no trailer (human)
#         1  at least one mismatch: unsigned, bad/unverifiable signature,
#            trailer != principal, human key with a trailer, >1 Agent trailer
#         2  no mismatch, but at least one commit is signed by a key that is
#            not in allowed_signers (good signature, unknown key: %G? = U)
#         3  usage or configuration error (no range, no allowed_signers file)
#       1 wins over 2 when a range has both.
#
# Internal (called by hooks/commit-msg and hooks/pre-push):
#   check-msg <message-file>          intent check: configured signing key vs
#                                     the trailer, BEFORE the commit is signed
#   pre-push <remote> <url> < refs    verify every pushed range
#   configured                        exit 0 iff an allowed_signers file is set
#   Both return 0 ok / 1 mismatch / 2 unknown key; the hook decides whether to
#   warn (default) or block (GIT_GUARD_IDENTITY=enforce).
#
# Environment:
#   GIT_GUARD_IDENTITY            off | warn (default) | enforce   (hooks only)
#   GIT_GUARD_ALLOWED_SIGNERS     allowed_signers file (beats git config)
#   GIT_GUARD_IDENTITY_KEYDIR     key directory (default ~/.ssh/agent-signing)
#   GIT_GUARD_HOST                host name used in key names (default: hostname)
#   GIT_GUARD_AGENT_PRINCIPALS    agent principals (default "claude codex jules gemini")
#   GIT_GUARD_IDENTITY_MAX_COMMITS  pre-push range cap (default 500)
#
# Pure POSIX sh + git + ssh-keygen. No machine-specific paths.

set -u

GG_ID_SELF="$0"
GG_ID_DIR="$(cd "$(dirname "$0")" && pwd -P)"
GG_ID_ROOT="$(cd "$GG_ID_DIR/../.." && pwd -P)"
GG_AGENT_PRINCIPALS="${GIT_GUARD_AGENT_PRINCIPALS:-claude codex jules gemini}"
# The agents prepare-commit-msg can actually attribute today.
GG_TRAILER_AGENTS="claude codex"

gg_die() { printf 'git-guard identity: %s\n' "$*" >&2; exit 3; }
gg_warn() { printf 'git-guard identity: %s\n' "$*" >&2; }

gg_is_agent_principal() {
  case " $GG_AGENT_PRINCIPALS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Agent ids and host names: lowercase, start with a letter, [a-z0-9._-], <=32.
gg_valid_id() {
  case "$1" in ""|[!a-z]*|*[!a-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}
# Principals may also be a human's email address (today's fleet uses one).
gg_valid_principal() {
  case "$1" in ""|*[!A-Za-z0-9._@+-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

gg_host() {
  h="${GIT_GUARD_HOST:-}"
  [ -n "$h" ] || h="$(hostname 2>/dev/null || uname -n)"
  h="${h%%.*}"
  printf '%s' "$h" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

gg_keydir() { printf '%s' "${GIT_GUARD_IDENTITY_KEYDIR:-$HOME/.ssh/agent-signing}"; }

# The release root as a STABLE path. When this release is reached through the
# installer's `current` symlink, name the file through `current`, so a launcher
# configured once keeps following `git-guard update` instead of pinning a
# version directory that a later cleanup may delete.
gg_stable_root() {
  parent="$(dirname "$GG_ID_ROOT")"
  if [ -L "$parent/current" ] &&
     [ "$(cd "$parent/current" 2>/dev/null && pwd -P)" = "$GG_ID_ROOT" ]; then
    printf '%s/current' "$parent"
  else
    printf '%s' "$GG_ID_ROOT"
  fi
}
gg_fleet_signers() { printf '%s/identity/allowed_signers' "$(gg_stable_root)"; }

# The allowed_signers file this process is CONFIGURED with: explicit env, then
# git config (which includes the GIT_CONFIG_COUNT block `identity env` prints).
# Empty when neither is set. The hooks use only this, so a host that never set
# up SSH signing is a silent no-op instead of warning on every commit and push.
gg_configured_signers() {
  if [ -n "${GIT_GUARD_ALLOWED_SIGNERS:-}" ]; then
    printf '%s' "$GIT_GUARD_ALLOWED_SIGNERS"; return 0
  fi
  git config --path --get gpg.ssh.allowedSignersFile 2>/dev/null || true
}
# For the explicit commands (verify, status): configured, else this release's
# fleet file.
gg_resolve_signers() {
  cfg="$(gg_configured_signers)"
  if [ -n "$cfg" ]; then printf '%s' "$cfg"; else printf '%s' "$(gg_fleet_signers)"; fi
}

# Print the base64 key blob of an allowed_signers / .pub style line or of a
# `user.signingkey` value (key:: literal, .pub file, or private key file).
gg_blob_of_publine() { printf '%s\n' "$1" | awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i + 1); exit } }'; }
gg_signingkey_blob() {
  key="$1"
  # shellcheck disable=SC2088  # matching a LITERAL "~/" stored in git config
  case "$key" in
    key::*) gg_blob_of_publine "${key#key::}"; return ;;
    "~/"*) key="$HOME/${key#\~/}" ;;
  esac
  [ -f "$key" ] || return 1
  first="$(head -n 1 "$key" 2>/dev/null)"
  case "$first" in
    ssh-*|ecdsa-*|sk-*) gg_blob_of_publine "$first"; return ;;
  esac
  if [ -f "$key.pub" ]; then gg_blob_of_publine "$(head -n 1 "$key.pub")"; return; fi
  pub="$(ssh-keygen -y -f "$key" 2>/dev/null)" || return 1
  gg_blob_of_publine "$pub"
}

# Principal(s) for a key blob in an allowed_signers file (first matching line).
# Only the field right after the FIRST key-type field counts as the key, so a
# blob quoted in another line's comment cannot claim a principal.
gg_principal_for_blob() {
  awk -v kb="$2" '
    /^[[:space:]]*(#|$)/ { next }
    {
      for (i = 2; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) {
        if ($(i + 1) == kb) { print $1; exit }
        next
      }
    }
  ' "$1"
}

# The OPTIONS field of an allowed_signers line: everything between the
# principal(s) and the key type. Empty when there are no options.
gg_signer_options() {
  printf '%s\n' "$1" | awk '{
    out = ""
    for (i = 2; i <= NF; i++) {
      if ($i ~ /^(ssh-|ecdsa-|sk-)/) break
      out = (out == "" ? $i : out " " $i)
    }
    print out
  }'
}

# --- keygen ------------------------------------------------------------------
cmd_keygen() {
  agent="" dir="$(gg_keydir)" host="$(gg_host)"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
      --host) host="${2:?--host needs a value}"; shift 2 ;;
      -*) gg_die "keygen: unknown option $1" ;;
      *) [ -z "$agent" ] || gg_die "keygen: one agent id only"; agent="$1"; shift ;;
    esac
  done
  gg_valid_id "$agent" || gg_die "keygen: invalid agent id '${agent}' (lowercase [a-z0-9._-], starts with a letter)"
  gg_valid_id "$host" || gg_die "keygen: invalid host '${host}'"
  command -v ssh-keygen >/dev/null 2>&1 || gg_die "keygen: ssh-keygen not found"
  key="$dir/$agent@$host"
  if [ ! -d "$dir" ]; then
    (umask 077 && mkdir -p "$dir") || gg_die "keygen: cannot create $dir"
  fi
  chmod 700 "$dir" || gg_die "keygen: cannot chmod 700 $dir"
  if [ -f "$key" ] || [ -f "$key.pub" ]; then
    [ -f "$key" ] && [ -f "$key.pub" ] || gg_die "keygen: half a key pair at $key — fix it by hand, refusing to overwrite"
    gg_warn "keygen: $key already exists; not regenerating"
    # shellcheck disable=SC2012  # only the mode column of one known path is read
    mode="$(ls -ld "$key" | cut -c1-10)"
    [ "$mode" = "-rw-------" ] || gg_warn "keygen: WARNING $key has mode $mode (want -rw-------)"
  else
    ssh-keygen -q -t ed25519 -N '' -C "agent-$agent@$host" -f "$key" </dev/null >/dev/null ||
      gg_die "keygen: ssh-keygen failed"
    chmod 600 "$key" || gg_die "keygen: cannot chmod 600 $key"
    gg_warn "keygen: created $key (register the public key below; nothing was uploaded)"
  fi
  # stdout: ONLY the public key and the registration command.
  cat "$key.pub"
  printf 'gh api -X POST user/ssh_signing_keys -f title=agent-%s@%s -F key=@%s\n' "$agent" "$host" "$key.pub"
}

# --- env ---------------------------------------------------------------------
gg_sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
gg_dq_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cmd_env() {
  agent="" dir="$(gg_keydir)" host="$(gg_host)" signers="" fmt=sh allow_missing=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
      --host) host="${2:?--host needs a value}"; shift 2 ;;
      --allowed-signers) signers="${2:?--allowed-signers needs a value}"; shift 2 ;;
      --format) fmt="${2:?--format needs a value}"; shift 2 ;;
      --allow-missing) allow_missing=1; shift ;;
      -*) gg_die "env: unknown option $1" ;;
      *) [ -z "$agent" ] || gg_die "env: one agent id only"; agent="$1"; shift ;;
    esac
  done
  gg_valid_id "$agent" || gg_die "env: invalid agent id '${agent}'"
  gg_valid_id "$host" || gg_die "env: invalid host '${host}'"
  case "$fmt" in sh|json|toml) ;; *) gg_die "env: --format must be sh, json or toml" ;; esac
  [ -n "$signers" ] || signers="$(gg_fleet_signers)"
  key="$dir/$agent@$host"
  if [ ! -f "$key" ] && [ "$allow_missing" -ne 1 ]; then
    # An identity block naming a missing key makes EVERY commit fail to sign.
    printf 'git-guard identity: env: no key at %s — run: git-guard identity keygen %s (or pass --allow-missing)\n' "$key" "$agent" >&2
    exit 1
  fi
  [ -f "$signers" ] || gg_warn "env: allowed_signers file $signers does not exist yet"
  if gg_is_agent_principal "$agent"; then
    case " $GG_TRAILER_AGENTS " in
      *" $agent "*) ;;
      *) gg_warn "env: prepare-commit-msg cannot write 'Agent: $agent' yet, so $agent-signed commits will fail verification" ;;
    esac
  fi
  # The PRIVATE key path: git then signs straight from the file, so no
  # SSH_AUTH_SOCK is needed (Codex's inherit="core" drops it; a Claude Code
  # settings value for it loses to the shell's export).
  set -- \
    GIT_CONFIG_COUNT 4 \
    GIT_CONFIG_KEY_0 user.signingkey GIT_CONFIG_VALUE_0 "$key" \
    GIT_CONFIG_KEY_1 gpg.format GIT_CONFIG_VALUE_1 ssh \
    GIT_CONFIG_KEY_2 commit.gpgsign GIT_CONFIG_VALUE_2 true \
    GIT_CONFIG_KEY_3 gpg.ssh.allowedSignersFile GIT_CONFIG_VALUE_3 "$signers"
  if gg_is_agent_principal "$agent"; then set -- "$@" GIT_GUARD_AGENT "$agent"; fi
  case "$fmt" in
    sh)
      while [ "$#" -gt 0 ]; do printf 'export %s=%s\n' "$1" "$(gg_sh_quote "$2")"; shift 2; done ;;
    toml)
      printf '[shell_environment_policy.set]\n'
      while [ "$#" -gt 0 ]; do printf '%s = "%s"\n' "$1" "$(gg_dq_escape "$2")"; shift 2; done ;;
    json)
      printf '{\n'
      while [ "$#" -gt 0 ]; do
        sep=","; [ "$#" -gt 2 ] || sep=""
        printf '  "%s": "%s"%s\n' "$1" "$(gg_dq_escape "$2")" "$sep"; shift 2
      done
      printf '}\n' ;;
  esac
}

# --- status ------------------------------------------------------------------
cmd_status() {
  signers="$(gg_resolve_signers)"
  key="$(git config --get user.signingkey 2>/dev/null || true)"
  scope="$(git config --show-scope --get user.signingkey 2>/dev/null | cut -f1)"
  fmt="$(git config --get gpg.format 2>/dev/null || echo openpgp)"
  sign="$(git config --bool --get commit.gpgsign 2>/dev/null || echo false)"
  agent=""
  case "${GIT_GUARD_AGENT:-}" in
    codex|claude) agent="$GIT_GUARD_AGENT" ;;
    "") if [ -n "${CODEX_THREAD_ID:-}" ]; then agent=codex
        elif [ "${CLAUDECODE:-}" = "1" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then agent=claude; fi ;;
  esac
  printf 'mode:             %s\n' "${GIT_GUARD_IDENTITY:-warn}"
  printf 'allowed_signers:  %s%s\n' "$signers" "$([ -f "$signers" ] || echo ' (MISSING)')"
  printf 'user.signingkey:  %s%s\n' "${key:-<unset>}" "${scope:+ (scope: $scope)}"
  printf 'gpg.format:       %s\n' "$fmt"
  printf 'commit.gpgsign:   %s\n' "$sign"
  principal=""
  if [ -n "$key" ] && [ -f "$signers" ] && blob="$(gg_signingkey_blob "$key")" && [ -n "$blob" ]; then
    principal="$(gg_principal_for_blob "$signers" "$blob")"
  fi
  printf 'key principal:    %s\n' "${principal:-<unknown>}"
  printf 'Agent trailer:    %s\n' "${agent:-<none: human>}"
}

# --- allowed-signers -----------------------------------------------------------
cmd_allowed_signers() {
  sub="${1:-}"; [ "$#" -gt 0 ] && shift
  file=""
  args=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file="${2:?--file needs a value}"; shift 2 ;;
      -*) gg_die "allowed-signers: unknown option $1" ;;
      *) args="$args
$1"; shift ;;
    esac
  done
  [ -n "$file" ] || file="$(gg_fleet_signers)"
  case "$sub" in
    path) printf '%s\n' "$file" ;;
    show) gg_signers_show "$file" ;;
    check) gg_signers_check "$file" ;;
    add)
      principal="$(printf '%s\n' "$args" | sed -n 2p)"
      pubfile="$(printf '%s\n' "$args" | sed -n 3p)"
      gg_signers_add "$file" "$principal" "$pubfile" ;;
    *) gg_die "allowed-signers: want path|show|check|add" ;;
  esac
}

gg_signers_show() {
  [ -f "$1" ] || gg_die "allowed-signers: $1 does not exist"
  t="$(mktemp "${TMPDIR:-/tmp}/gg-id.XXXXXX")" || gg_die "mktemp failed"
  grep -v '^[[:space:]]*\(#\|$\)' "$1" | while IFS= read -r line; do
    principal="$(printf '%s\n' "$line" | awk '{print $1}')"
    printf '%s\n' "$line" | awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { out = $i " " $(i + 1); for (j = i + 2; j <= NF; j++) out = out " " $j; print out; exit } }' > "$t"
    printf '%-24s %s\n' "$principal" "$(ssh-keygen -l -f "$t" 2>/dev/null || echo '<unparseable key>')"
  done
  rm -f "$t"
}

# Lint: every entry parses, is namespace-restricted to git, has a valid
# principal, and no key appears twice. Exit 1 on any problem.
gg_signers_check() {
  [ -f "$1" ] || gg_die "allowed-signers: $1 does not exist"
  command -v ssh-keygen >/dev/null 2>&1 || gg_die "allowed-signers check: ssh-keygen not found"
  t="$(mktemp "${TMPDIR:-/tmp}/gg-id.XXXXXX")" || gg_die "mktemp failed"
  seen="$(mktemp "${TMPDIR:-/tmp}/gg-id.XXXXXX")" || gg_die "mktemp failed"
  bad=0 n=0 lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    stripped="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    case "$stripped" in ""|"#"*) continue ;; esac
    n=$((n + 1))
    principals="$(printf '%s\n' "$stripped" | awk '{print $1}')"
    for p in $(printf '%s' "$principals" | tr ',' ' '); do
      gg_valid_principal "$p" || { printf 'line %d: invalid principal %s\n' "$lineno" "$p"; bad=1; }
    done
    # namespaces="git" must be an OPTION (before the key type). The same text
    # in the trailing comment restricts nothing: ssh-keygen ignores it.
    case ",$(gg_signer_options "$stripped")," in
      *',namespaces="git",'*) : ;;
      *) printf 'line %d: missing namespaces="git" option (key would verify any namespace)\n' "$lineno"; bad=1 ;;
    esac
    blob="$(gg_blob_of_publine "$stripped")"
    if [ -z "$blob" ]; then printf 'line %d: no key found\n' "$lineno"; bad=1; continue; fi
    printf '%s\n' "$stripped" | awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $i " " $(i + 1); exit } }' > "$t"
    ssh-keygen -l -f "$t" >/dev/null 2>&1 || { printf 'line %d: key does not parse\n' "$lineno"; bad=1; }
    if grep -qxF "$blob" "$seen"; then printf 'line %d: key listed twice\n' "$lineno"; bad=1; fi
    printf '%s\n' "$blob" >> "$seen"
  done < "$1"
  rm -f "$t" "$seen"
  printf '%s: %d entr%s, %s\n' "$1" "$n" "$([ "$n" -eq 1 ] && echo y || echo ies)" "$([ "$bad" -eq 0 ] && echo ok || echo PROBLEMS)"
  return "$bad"
}

gg_signers_add() {
  file="$1" principal="$2" pubfile="$3"
  gg_valid_principal "$principal" || gg_die "allowed-signers add: invalid principal '$principal'"
  [ -f "$pubfile" ] || gg_die "allowed-signers add: no public key file '$pubfile'"
  if [ -f "$(dirname "$file")/../.git-guard-commit" ]; then
    gg_die "allowed-signers add: $file belongs to an installed release; edit identity/allowed_signers in a git-guard checkout and open a PR (or pass --file)"
  fi
  first="$(head -n 1 "$pubfile")"
  case "$first" in *PRIVATE*) gg_die "allowed-signers add: $pubfile is a PRIVATE key; pass the .pub file" ;; esac
  blob="$(gg_blob_of_publine "$first")"
  [ -n "$blob" ] || gg_die "allowed-signers add: $pubfile is not an SSH public key"
  ssh-keygen -l -f "$pubfile" >/dev/null 2>&1 || gg_die "allowed-signers add: $pubfile does not parse"
  if [ -f "$file" ]; then
    existing="$(gg_principal_for_blob "$file" "$blob")"
    if [ -n "$existing" ]; then
      [ "$existing" = "$principal" ] || gg_die "allowed-signers add: that key is already listed for '$existing'; one key, one principal"
      gg_warn "allowed-signers add: already present for $principal (no change)"
      return 0
    fi
  fi
  keypart="$(printf '%s\n' "$first" | awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { out = $i " " $(i + 1); for (j = i + 2; j <= NF; j++) out = out " " $j; print out; exit } }')"
  printf '%s namespaces="git" %s\n' "$principal" "$keypart" >> "$file" || gg_die "allowed-signers add: cannot write $file"
  gg_warn "allowed-signers add: added $principal to $file"
}

# --- verify (actual signatures) -------------------------------------------------
# One record per commit: sha, %G?, %GS, %GF, Agent trailer values (comma-joined).
GG_VERIFY_FMT='%H%x1f%G?%x1f%GS%x1f%GF%x1f%(trailers:key=Agent,valueonly,separator=%x2C)%x1e'

# gg_verify_rows SIGNERS QUIET REV-ARGS... ; prints findings, returns 0/1/2.
gg_verify_rows() {
  signers="$1" quiet="$2"; shift 2
  out="$(mktemp "${TMPDIR:-/tmp}/gg-id.XXXXXX")" || gg_die "mktemp failed"
  # log.showSignature would splice raw ssh-keygen output into the format.
  if ! git -c "gpg.ssh.allowedSignersFile=$signers" -c log.showSignature=false \
       log --no-show-signature "--format=$GG_VERIFY_FMT" "$@" > "$out" 2>"$out.err"; then
    sed 's/^/  /' "$out.err" >&2
    rm -f "$out" "$out.err"
    gg_die "verify: git log failed for: $*"
  fi
  rm -f "$out.err"
  res="$(tr -d '\n' < "$out" | tr '\036' '\n' | awk -F '\037' -v agents=" $GG_AGENT_PRINCIPALS " -v quiet="$quiet" '
    NF < 5 { next }
    {
      sha = substr($1, 1, 10); st = $2; gs = $3; gf = $4; tr = $5
      n = split(tr, parts, ","); cnt = 0; agent = ""
      for (i = 1; i <= n; i++) {
        v = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "") { cnt++; agent = tolower(v) }
      }
      problem = ""; kind = "ok"
      if (st == "U") { kind = "unknown"; problem = "good signature by a key NOT in allowed_signers (" (gf == "" ? "-" : gf) ")" }
      else if (st == "N") { kind = "mismatch"; problem = "unsigned (or no allowed_signers configured)" }
      else if (st != "G") { kind = "mismatch"; problem = "signature status " st " (want G)" }
      else if (cnt > 1) { kind = "mismatch"; problem = "multiple Agent trailers" }
      else if (index(agents, " " gs " ") > 0 && agent != gs) { kind = "mismatch"; problem = "signed by \047" gs "\047 but Agent trailer is \047" (agent == "" ? "<none>" : agent) "\047" }
      else if (index(agents, " " gs " ") == 0 && agent != "") { kind = "mismatch"; problem = "signed by human \047" gs "\047 but Agent trailer is \047" agent "\047" }
      total++
      if (kind == "mismatch") mis++
      if (kind == "unknown") unk++
      if (kind == "ok") { if (quiet != "1") printf "ok   %s %s %s Agent=%s\n", sha, st, (gs == "" ? "-" : gs), (agent == "" ? "-" : agent) }
      else printf "%s %s %s %s Agent=%s  <- %s\n", (kind == "unknown" ? "UNKN" : "FAIL"), sha, st, (gs == "" ? "-" : gs), (agent == "" ? "-" : agent), problem
    }
    END { printf "#summary %d %d %d\n", total + 0, mis + 0, unk + 0 }
  ')"
  rm -f "$out"
  printf '%s\n' "$res" | grep -v '^#summary '
  summary="$(printf '%s\n' "$res" | sed -n 's/^#summary //p')"
  # shellcheck disable=SC2086  # intentional split of "total mismatch unknown"
  set -- $summary
  GG_VERIFY_TOTAL="$1" GG_VERIFY_MIS="$2" GG_VERIFY_UNK="$3"
  [ "$GG_VERIFY_MIS" -gt 0 ] && return 1
  [ "$GG_VERIFY_UNK" -gt 0 ] && return 2
  return 0
}

cmd_verify() {
  signers="" quiet=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allowed-signers) signers="${2:?--allowed-signers needs a value}"; shift 2 ;;
      --quiet) quiet=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || gg_die "verify: give a revision range, e.g. origin/main..HEAD"
  [ -n "$signers" ] || signers="$(gg_resolve_signers)"
  # Without an allowed_signers file git reports every SSH-signed commit as N,
  # indistinguishable from unsigned: refuse instead of producing that verdict.
  [ -f "$signers" ] || gg_die "verify: allowed_signers file '$signers' does not exist"
  gg_verify_rows "$signers" "$quiet" "$@"
  rc=$?
  printf 'identity verify: %s commit(s), %s mismatch, %s unknown-key (allowed_signers: %s)\n' \
    "$GG_VERIFY_TOTAL" "$GG_VERIFY_MIS" "$GG_VERIFY_UNK" "$signers"
  return "$rc"
}

# --- check-msg (intent, before signing) ----------------------------------------
cmd_check_msg() {
  msg="${1:-}"
  [ -n "$msg" ] && [ -f "$msg" ] || gg_die "check-msg: message file missing"
  # Nothing to cross-check unless this commit will be SSH-signed with a known key
  # file: an unconfigured host must stay a silent no-op.
  [ "$(git config --bool --get commit.gpgsign 2>/dev/null)" = "true" ] || return 0
  [ "$(git config --get gpg.format 2>/dev/null)" = "ssh" ] || return 0
  key="$(git config --get user.signingkey 2>/dev/null || true)"
  [ -n "$key" ] || return 0
  signers="$(gg_configured_signers)"
  [ -n "$signers" ] && [ -f "$signers" ] || return 0
  trailer="$(git interpret-trailers --parse "$msg" 2>/dev/null |
    awk -F ':' 'tolower($1) ~ /^agent[[:space:]]*$/ { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print tolower(v) }' | tail -n 1)"
  blob="$(gg_signingkey_blob "$key" 2>/dev/null || true)"
  if [ -z "$blob" ]; then
    printf 'git-guard identity: cannot read the public half of user.signingkey (%s)\n' "$key" >&2
    return 2
  fi
  principal="$(gg_principal_for_blob "$signers" "$blob")"
  if [ -z "$principal" ]; then
    printf 'git-guard identity: user.signingkey %s is not in %s (unknown key; Agent trailer: %s)\n' \
      "$key" "$signers" "${trailer:-<none>}" >&2
    return 2
  fi
  if gg_is_agent_principal "$principal"; then
    if [ "$trailer" != "$principal" ]; then
      printf "git-guard identity: signing key belongs to agent '%s' but the Agent trailer is '%s'\n" \
        "$principal" "${trailer:-<none>}" >&2
      return 1
    fi
  elif [ -n "$trailer" ]; then
    printf "git-guard identity: signing key belongs to human principal '%s' but the Agent trailer is '%s' (shared key? see: git-guard identity keygen %s)\n" \
      "$principal" "$trailer" "$trailer" >&2
    return 1
  fi
  return 0
}

# --- pre-push (actual signatures of every pushed range) -------------------------
gg_is_zero_sha() { case "$1" in *[!0]*) return 1 ;; esac; return 0; }

cmd_pre_push() {
  remote="${1:-}"
  signers="$(gg_configured_signers)"
  # Same rule as check-msg: an unconfigured host is a silent no-op.
  if [ -z "$signers" ] || [ ! -f "$signers" ]; then cat >/dev/null; return 0; fi
  max="${GIT_GUARD_IDENTITY_MAX_COMMITS:-500}"
  case "$max" in ""|*[!0-9]*) max=500 ;; esac
  rows="$(mktemp "${TMPDIR:-/tmp}/gg-id.XXXXXX")" || gg_die "mktemp failed"
  rc=0
  while read -r _lref lsha _rref rsha; do
    [ -n "${lsha:-}" ] || continue
    gg_is_zero_sha "$lsha" && continue                       # deletion
    if [ -n "${rsha:-}" ] && ! gg_is_zero_sha "$rsha" &&
       git cat-file -e "$rsha^{commit}" 2>/dev/null; then
      set -- "$rsha..$lsha"
    elif [ -n "$remote" ] && git remote 2>/dev/null | grep -qxF "$remote"; then
      # New ref, or remote tip not fetched: exclude only what THIS remote is
      # known to have. Excluding every remote would verify nothing when the
      # same history is pushed to a second remote (a mirror, a fork).
      set -- "$lsha" --not --remotes="$remote"
    else
      set -- "$lsha"                                         # push to a URL: no tracking refs
    fi
    if ! count="$(git rev-list --count "$@" 2>/dev/null)"; then
      printf 'git-guard identity: cannot list the commits pushed to %s (%s); not checked\n' "$_lref" "$*" >&2
      [ "$rc" -eq 0 ] && rc=2
      continue
    fi
    [ "$count" -gt 0 ] || continue
    if [ "$count" -gt "$max" ]; then
      printf 'git-guard identity: %s commit(s) in %s exceed GIT_GUARD_IDENTITY_MAX_COMMITS=%s; not checked (run: git-guard identity verify %s)\n' \
        "$count" "$_lref" "$max" "$*" >&2
      [ "$rc" -eq 0 ] && rc=2
      continue
    fi
    # Not in a $(...) subshell: gg_verify_rows sets the GG_VERIFY_* counters.
    gg_verify_rows "$signers" 1 "$@" > "$rows"; r=$?
    if [ "$r" -ne 0 ]; then
      printf 'git-guard identity: %s (%s commit(s)): %s mismatch, %s unknown-key\n' \
        "$_lref" "$GG_VERIFY_TOTAL" "$GG_VERIFY_MIS" "$GG_VERIFY_UNK" >&2
      sed 's/^/  /' "$rows" >&2
      if [ "$r" -eq 1 ] || [ "$rc" -eq 0 ]; then rc="$r"; fi
    fi
  done
  rm -f "$rows"
  return "$rc"
}

case "${1:-help}" in
  keygen) shift; cmd_keygen "$@" ;;
  env) shift; cmd_env "$@" ;;
  status) shift; cmd_status "$@" ;;
  allowed-signers) shift; cmd_allowed_signers "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  check-msg) shift; cmd_check_msg "$@" ;;
  pre-push) shift; cmd_pre_push "$@" ;;
  configured)  # internal: exit 0 iff an allowed_signers file is configured
    f="$(gg_configured_signers)"; [ -n "$f" ] && [ -f "$f" ] ;;
  help|--help|-h)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$GG_ID_SELF" ;;
  *) gg_die "unknown subcommand '$1' (try: git-guard identity help)" ;;
esac
