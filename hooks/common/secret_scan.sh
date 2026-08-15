#!/bin/sh
#
# git-guard generic secret-scan guard (account-wide MVC).
#
# Scans the *added lines* of the staged diff and BLOCKS the commit on a hit.
# Two tiers, deliberately different in how much context they need:
#
#   TIER 1 -- HIGH-CONFIDENCE PROVIDER FORMATS.
#     AWS, GitHub, GitLab, Slack, Stripe, OpenAI, Anthropic, Google, npm,
#     Discord, SendGrid, Twilio, PyPI, Azure, JWT, PEM private keys. These are
#     structurally unmistakable, so they are flagged wherever they appear and no
#     context is consulted.
#
#   TIER 2 -- CONTEXTUAL `key = value` LITERALS.
#     password / api_key / secret_key / client_secret / token / private_key.
#     This tier is where every false positive came from, because the KEY half
#     matches perfectly ordinary code. Before 2026-08-12 the rule took
#     everything after the first ':' or '=' and called it a secret if it was 6+
#     chars, which blocked any module that legitimately *handles* credentials:
#
#         self.password = fallback.password;      -> "fallback.password;"
#         api_key: String,                        -> "String,"
#         let k = config.api_key.clone();         -> "config.api_key.clone();"
#         POSTGRES_PASSWORD: postgres             -> "postgres"
#
#     None are secrets; all four blocked commits. The fix is to judge the VALUE
#     half in context, on one principle:
#
#         A hardcoded credential is a LITERAL. A false positive is an
#         EXPRESSION. Literals and expressions are cheap to tell apart.
#
#     Concretely:
#       * In SOURCE files a credential must be a QUOTED STRING LITERAL. An
#         unquoted right-hand side in Rust/Python/Go/... is an identifier, a
#         type, a field access or a call -- never a hardcoded secret.
#       * In CONFIG/data/shell files (.env/.ini/.yml/.toml/.json/Dockerfile/
#         .sh/.ps1) an unquoted bare token IS how a credential is normally
#         written, so those are still scanned -- but code-shaped values are
#         rejected there too.
#       * Rejected everywhere: code shapes (calls, field access, generics,
#         operators, trailing ';'/','), interpolated templates (${X}, $VAR,
#         {{x}}, %X%, $(cmd)), placeholders (YOUR*/TEST*/DUMMY*/FAKE*/MOCK*/
#         SAMPLE*/CHANGEME*/EXAMPLE*/...), and low-entropy all-lowercase words
#         under 12 chars (postgres, admin, guest, root -- the CI-service-
#         container defaults).
#
# Both tiers honour the detect-secrets-compatible line pragma:
#     ... # pragma: allowlist secret
#
# Scans ADDED lines only (git diff --cached -U0, '^+'), so pre-existing benign
# matches across the ~48 account repos never start blocking.
#
# Exit 0 = clean (or nothing staged). Exit 1 = secret found, commit blocked.
# Invoke as a SUBPROCESS (./secret_scan.sh || exit 1) -- do not `.`-source it.
#
# Bypass (conscious, documented): `LEFTHOOK=0 git commit ...` / `GIT_GUARD=0`
# short-circuits in the calling hook before this runs. There is no
# secret-scan-specific opt-out; that is intentional. Prefer the line pragma.

set -u

# --- context helpers ---------------------------------------------------------

# Credential-key regex, spelled with character classes rather than `grep -i`,
# because the same expression is reused by `sed` (which has no portable
# case-insensitive flag) to locate the key's own ':'/'=' delimiter.
_GG_KEYRE='([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Ww][Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt][_-]?[Kk][Ee][Yy]|[Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn]|[Rr][Ee][Ff][Rr][Ee][Ss][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Bb][Oo][Tt][_-]?[Tt][Oo][Kk][Ee][Nn]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy])'

# True for compiled/interpreted SOURCE files, where an unquoted RHS is code.
# NOTE: shell/PowerShell/batch are deliberately NOT here -- an unquoted
# `PASSWORD=<value>` in a .sh IS a real credential assignment, and this scanner
# blocks it. (This very comment tripped the rule during development, which is
# the intended behaviour; documenting an example value is what the pragma is
# for.)  # pragma: allowlist secret
_gg_is_source_ext() {
  case "$1" in
    *.rs|*.py|*.pyi|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.jsx|*.go|*.java|*.kt|*.kts \
    |*.scala|*.c|*.h|*.cc|*.cpp|*.hpp|*.cxx|*.cs|*.rb|*.php|*.swift|*.dart \
    |*.zig|*.lua|*.pl|*.pm|*.jl|*.ex|*.exs|*.erl|*.hs|*.ml|*.vb|*.mm)
      return 0 ;;
    *) return 1 ;;
  esac
}

# True when the value is shaped like code rather than a literal token.
_gg_looks_like_code() {
  v="$1"
  case "$v" in
    # calls, blocks, indexing, generics, paths, closures, pipes.
    # `=>` and `->` need no arms of their own: `*'>'*` already covers them.
    *'('*|*')'*|*'{'*|*'}'*|*'['*|*']'*|*'<'*|*'>'*|*'::'*|*'|'*)
      return 0 ;;
    # trailing statement/list punctuation
    *';'|*','|*'.') return 0 ;;
    # more than one word: prose, a comment, or a code fragment -- not a token
    *' '*|*"$(printf '\t')"*) return 0 ;;
  esac
  # ident.ident[.ident...] -- field access / attribute chain
  if printf '%s' "$v" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$'; then
    return 0
  fi
  # bare type names that show up as struct-field declarations
  case "$v" in
    String|str|Str|int|Int|bool|Bool|bytes|Bytes|Option|Vec|Self|None|null|nil|undefined|true|false|True|False)
      return 0 ;;
  esac
  return 1
}

# True when the value is a placeholder / template / low-entropy default.
_gg_is_placeholder() {
  v="$1"
  # shellcheck disable=SC2016  # the '${' / '$(' arms are literal template sigils, not expansions
  case "$v" in
    ""|x|xx|xxx|xxxx|xxxxx|X|XX|XXX|XXXX|XXXXX) return 0 ;;
    *'<'*'>'*) return 0 ;;                       # <your-token-here>
    '${'*|'{{'*|'%'*|'$('*|'#{'*) return 0 ;;    # ${ENV} {{var}} %VAR% $(cmd) #{rb}
    YOUR*|your*|MY_*|my_*) return 0 ;;
    CHANGEME*|changeme*|CHANGE_ME*|change_me*|CHANGEIT*|changeit*) return 0 ;;
    TODO*|todo*|FIXME*|fixme*) return 0 ;;
    PLACEHOLDER*|placeholder*|EXAMPLE*|example*|SAMPLE*|sample*) return 0 ;;
    TEST*|test*|DUMMY*|dummy*|FAKE*|fake*|MOCK*|mock*|STUB*|stub*) return 0 ;;
    FOO*|foo*|BAR*|bar*|BAZ*|baz*) return 0 ;;
    REDACTED*|redacted*|OMITTED*|omitted*|MASKED*|masked*) return 0 ;;
    NONE|none|NULL|null|NIL|nil|EMPTY|empty|UNSET|unset) return 0 ;;
    '****'*|'...'*|'---'*) return 0 ;;
  esac
  # Shell / PowerShell / Make interpolation anywhere in the value: "$safeTag-$sha".
  # `$` followed by an identifier or opening brace/paren. A leading `$2b$` bcrypt
  # hash is NOT matched (digit after `$`), so hashes still reach the checks.
  if printf '%s' "$v" | grep -Eq '\$[A-Za-z_{(]'; then return 0; fi
  # Low-entropy: a single-case alphabetic word shorter than 12 chars. Covers the
  # CI-service defaults (postgres, mysql, root, admin, guest, secret) without a
  # hand-maintained denylist. A real credential of this shape is already weak.
  if printf '%s' "$v" | grep -Eq '^[a-z]{1,11}$'; then return 0; fi
  if printf '%s' "$v" | grep -Eq '^[A-Z]{1,11}$'; then return 0; fi
  return 1
}

# --- pattern engine ----------------------------------------------------------

scan_match() {
  # $1 = candidate line content (without the leading '+')
  # $2 = path of the file the line belongs to (context for tier 2)
  line="$1"
  sfile="${2:-}"

  # Allowlist pragma (detect-secrets compatible): a line tagged with
  # `pragma: allowlist secret` is intentionally exempt -- for documenting
  # patterns, test fixtures, or known-safe example values.
  case "$line" in *'pragma: allowlist secret'*) return 1 ;; esac

  # ---- TIER 1: high-confidence provider formats (context-free) -------------
  # AWS access key id
  if printf '%s' "$line" | grep -Eq 'AKIA[0-9A-Z]{16}'; then
    echo "AWS access key"; return 0
  fi
  # GitHub classic personal access token
  if printf '%s' "$line" | grep -Eq 'ghp_[A-Za-z0-9_]{30,}'; then
    echo "GitHub PAT"; return 0
  fi
  # GitHub fine-grained PAT / other github_pat_ tokens
  if printf '%s' "$line" | grep -Eq 'github_pat_[A-Za-z0-9_]{30,}'; then
    echo "GitHub fine-grained PAT"; return 0
  fi
  # Other GitHub token classes: oauth / user-to-server / server-to-server / refresh
  if printf '%s' "$line" | grep -Eq 'gh[osur]_[A-Za-z0-9_]{30,}'; then
    echo "GitHub token"; return 0
  fi
  # GitLab personal access token
  if printf '%s' "$line" | grep -Eq 'glpat-[A-Za-z0-9_-]{20,}'; then
    echo "GitLab PAT"; return 0
  fi
  # Slack tokens (bot/user/app/refresh/legacy)
  if printf '%s' "$line" | grep -Eq 'xox[baprse]-[A-Za-z0-9-]{10,}'; then
    echo "Slack token"; return 0
  fi
  # Google API key
  if printf '%s' "$line" | grep -Eq 'AIza[0-9A-Za-z_-]{35}'; then
    echo "Google API key"; return 0
  fi
  # Stripe live secret / restricted key
  if printf '%s' "$line" | grep -Eq '\b[sr]k_live_[0-9a-zA-Z]{16,}'; then
    echo "Stripe live key"; return 0
  fi
  # Anthropic API key
  if printf '%s' "$line" | grep -Eq 'sk-ant-[A-Za-z0-9_-]{20,}'; then
    echo "Anthropic API key"; return 0
  fi
  # OpenAI API key (classic and project-scoped)
  if printf '%s' "$line" | grep -Eq 'sk-proj-[A-Za-z0-9_-]{20,}'; then
    echo "OpenAI project key"; return 0
  fi
  if printf '%s' "$line" | grep -Eq 'sk-[A-Za-z0-9]{32,}'; then
    echo "OpenAI API key"; return 0
  fi
  # npm access token
  if printf '%s' "$line" | grep -Eq 'npm_[A-Za-z0-9]{36}'; then
    echo "npm token"; return 0
  fi
  # PyPI upload token
  if printf '%s' "$line" | grep -Eq 'pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{20,}'; then
    echo "PyPI token"; return 0
  fi
  # SendGrid API key
  if printf '%s' "$line" | grep -Eq 'SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'; then
    echo "SendGrid API key"; return 0
  fi
  # Twilio API key SID
  if printf '%s' "$line" | grep -Eq '\bSK[0-9a-fA-F]{32}\b'; then
    echo "Twilio key SID"; return 0
  fi
  # Discord bot token (3 dot-separated segments, id.timestamp.hmac)
  if printf '%s' "$line" | grep -Eq '\b[MNO][A-Za-z0-9_-]{23,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}'; then
    echo "Discord bot token"; return 0
  fi
  # Azure storage account key in a connection string
  if printf '%s' "$line" | grep -Eq 'AccountKey=[A-Za-z0-9+/=]{60,}'; then
    echo "Azure storage key"; return 0
  fi
  # JSON Web Token (header.payload., both base64url of a JSON object)
  if printf '%s' "$line" | grep -Eq 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'; then
    echo "JWT"; return 0
  fi
  # PEM private key header. Use -e/-- so the leading '-' is not parsed as an
  # option by grep.
  if printf '%s' "$line" | grep -Eq -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'; then
    echo "private key"; return 0
  fi

  # ---- TIER 2: contextual key = value literals ------------------------------
  # Require an assignment to a credential-ish key. Comparisons are not
  # assignments: `if password == expected` assigns nothing.
  printf '%s' "$line" | grep -Eq "${_GG_KEYRE}[[:space:]]*[:=]" || return 1
  case "$line" in *'=='*|*'!='*|*'<='*|*'>='*) return 1 ;; esac

  # Right-hand side: everything after the CREDENTIAL KEY's own ':' or '=' — NOT
  # after the first delimiter on the line. Consider this Rust:
  #     let c = Config { password: "s3cr3t" };   # pragma: allowlist secret
  # its first '=' is in `let c =`, so splitting there yields `Config { ... }`,
  # which is unquoted and code-shaped -- the real literal was never examined and
  # the line was silently allowed (a false NEGATIVE). Splitting at the key's own
  # delimiter fixes it. The leading `.*` is greedy, so on a line carrying several
  # credential keys the LAST one wins.
  rhs="$(printf '%s' "$line" | sed -E "s/^.*${_GG_KEYRE}[[:space:]]*[:=][[:space:]]*//")"
  # Drop a trailing line comment so `KEY=abc  # set me` judges only `abc`.
  rhs="$(printf '%s' "$rhs" | sed -E 's/[[:space:]]+(#|\/\/).*$//')"
  rhs="$(printf '%s' "$rhs" | sed -E 's/[[:space:]]+$//')"

  # Is the value a quoted string literal? If so, take the literal's contents.
  quoted=0
  case "$rhs" in
    '"'*) val="$(printf '%s' "$rhs" | sed -e 's/^"//' -e 's/".*$//')"; quoted=1 ;;
    "'"*) val="$(printf '%s' "$rhs" | sed -e "s/^'//" -e "s/'.*\$//")"; quoted=1 ;;
    '`'*) val="$(printf '%s' "$rhs" | sed -e 's/^`//' -e 's/`.*$//')"; quoted=1 ;;
    *)    val="$rhs" ;;
  esac

  if [ "$quoted" -eq 0 ]; then
    # In real source code an unquoted RHS is an identifier / type / call /
    # field access -- structurally incapable of being a hardcoded literal.
    _gg_is_source_ext "$sfile" && return 1
    # In config/shell, still reject anything code-shaped.
    _gg_looks_like_code "$val" && return 1
  fi

  _gg_is_placeholder "$val" && return 1

  # Plausible value: require at least 6 chars to avoid empty/short noise.
  if [ "${#val}" -ge 6 ]; then
    echo "credential literal"; return 0
  fi
  return 1
}

# --- staged-diff walk --------------------------------------------------------

# Collect added lines from the staged diff, tagged with their file path so we
# can report file:line. -U0 keeps context to zero; --diff-filter=ACM ignores
# deletions/renames-without-content. We parse the unified diff ourselves to
# track the current file and the new-file line number of each '+' line.
added="$(git diff --cached -U0 --diff-filter=ACM --no-color 2>/dev/null)"
[ -z "$added" ] && exit 0

cur_file=""
new_lineno=0
hit_file=""
hit_line=""
hit_label=""

# Read the unified diff line by line. We need POSIX-safe iteration that
# preserves leading spaces, so use read -r with IFS unset.
while IFS= read -r diffline; do
  case "$diffline" in
    "+++ "*)
      # New-file path: "+++ b/path/to/file" or "+++ /dev/null".
      p="${diffline#+++ }"
      case "$p" in
        /dev/null) cur_file="" ;;
        b/*)       cur_file="${p#b/}" ;;
        *)         cur_file="$p" ;;
      esac
      ;;
    "@@ "*)
      # Hunk header: @@ -old,cnt +new,cnt @@ ...  Extract the new-file start.
      newpart="$(printf '%s' "$diffline" | sed -E 's/^@@ [^+]*\+([0-9]+).*/\1/')"
      case "$newpart" in
        ''|*[!0-9]*) new_lineno=0 ;;
        *) new_lineno="$newpart" ;;
      esac
      ;;
    "+++"*) : ;;  # already handled by "+++ "* above; guard stray
    "+"*)
      # An added content line (but not the +++ header).
      content="${diffline#+}"
      if [ -n "$cur_file" ]; then
        # Cheap pure-shell pre-filter: only invoke the subprocess-heavy
        # scan_match on lines containing a trigger substring. On large commits
        # this avoids many grep spawns PER added line -- the Git-Bash hot-path
        # killer. The pre-filter is a deliberate SUPERSET; a false trigger just
        # costs one scan_match call that then decides precisely. Every TIER 1
        # pattern MUST have a trigger here or it can never fire.
        case "$content" in
          *AKIA*|*ghp_*|*gho_*|*ghs_*|*ghu_*|*ghr_*|*github_pat_*|*glpat-* \
          |*xox*|*AIza*|*sk_live_*|*rk_live_*|*sk-*|*npm_*|*pypi-*|*SG.* \
          |*SK[0-9a-fA-F]*|*AccountKey=*|*eyJ*|*"PRIVATE KEY"* \
          |*[Pp][Aa][Ss][Ss][Ww]*|*[Pp][Ww][Dd]*|*[Aa][Pp][Ii][-_][Kk][Ee][Yy]* \
          |*[Aa][Pp][Ii][Kk][Ee][Yy]*|*[Ss][Ee][Cc][Rr][Ee][Tt]* \
          |*[Tt][Oo][Kk][Ee][Nn]*|*[Pp][Rr][Ii][Vv][Aa][Tt][Ee][-_][Kk][Ee][Yy]*)
            label="$(scan_match "$content" "$cur_file")" && {
              hit_file="$cur_file"
              hit_line="$new_lineno"
              hit_label="$label"
              break
            }
            ;;
        esac
      fi
      new_lineno=$((new_lineno + 1))
      ;;
    "-"*)
      # Removed line: does not advance the new-file counter.
      : ;;
    *)
      # Context / metadata line: advances the new-file counter only for
      # actual context (space-prefixed) lines inside a hunk.
      case "$diffline" in
        " "*) new_lineno=$((new_lineno + 1)) ;;
        *) : ;;
      esac
      ;;
  esac
done <<EOF
$added
EOF

if [ -n "$hit_label" ]; then
  printf '%s\n' "git-guard BLOCKED: possible secret in ${hit_file}:${hit_line} (${hit_label}). Your changes are STAGED but UNCOMMITTED — do NOT 'git reset --hard' (it permanently destroys git-add'ed work). Remove the secret, use .env/secret store, re-stage, re-commit. If it is genuinely not a secret, tag the line '# pragma: allowlist secret'. Verify: git log -1 --pretty='%h %G? %s'" >&2
  exit 1
fi

exit 0
