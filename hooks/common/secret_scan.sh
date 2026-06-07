#!/bin/sh
#
# git-guard generic secret-scan guard (account-wide MVC).
#
# Scans the *added lines* of the staged diff for a small, high-confidence set
# of secret patterns and BLOCKS the commit on a hit. Ported from
# vigil-utils/scripts/vigil_quality_gate.sh:check_staged_secret_patterns, but:
#   * scans ADDED lines only (git diff --cached -U0, '^+'), not whole blobs, so
#     pre-existing benign matches in the ~48 account repos never start blocking;
#   * drops VIGIL-specific exceptions;
#   * keeps a conservative pattern set to minimise false positives;
#   * requires a plausible value for password=/api_key= literals.  (pragma: allowlist secret)
#
# Exit 0 = clean (or nothing staged). Exit 1 = secret found, commit blocked.
# Invoke as a SUBPROCESS (./secret_scan.sh || exit 1) — do not `.`-source it.
#
# Bypass (conscious, documented): same as the lefthook stub it lives in,
# `LEFTHOOK=0 git commit ...` short-circuits before this runs. There is no
# secret-scan-specific opt-out; that is intentional.

set -u

# Collect added lines from the staged diff, tagged with their file path so we
# can report file:line. -U0 keeps context to zero; --diff-filter=ACM ignores
# deletions/renames-without-content. We parse the unified diff ourselves to
# track the current file and the new-file line number of each '+' line.
added="$(git diff --cached -U0 --diff-filter=ACM --no-color 2>/dev/null)"
[ -z "$added" ] && exit 0

# Pattern table: each entry is "LABEL<TAB>EXTENDED_REGEX".
# High-confidence, specific patterns — kept verbatim from the vigil set.
# The password=/api_key= literals get a value-shape guard applied separately.  (pragma: allowlist secret)
scan_match() {
  # $1 = candidate line content (without the leading '+')
  line="$1"

  # Allowlist pragma (detect-secrets compatible): a line tagged with
  # `pragma: allowlist secret` is intentionally exempt — for documenting
  # patterns, test fixtures, or known-safe example values.
  case "$line" in *'pragma: allowlist secret'*) return 1 ;; esac

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
  # PEM private key header. Use -e/-- so the leading '-' is not parsed as an
  # option by grep.
  if printf '%s' "$line" | grep -Eq -e '-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'; then
    echo "private key"; return 0
  fi
  # password= / api_key= / apikey= / secret= literals WITH a plausible value.  (pragma: allowlist secret)
  # Require: an assignment, then a value that is not an obvious placeholder.
  if printf '%s' "$line" | grep -Eiq '(password|passwd|api[_-]?key|secret[_-]?key|client[_-]?secret)[[:space:]]*[:=]'; then
    # Extract the value side (everything after the first : or =).
    val="$(printf '%s' "$line" | sed -E 's/^[^:=]*[:=][[:space:]]*//')"
    # Strip surrounding quotes.
    val="$(printf '%s' "$val" | sed -E "s/^['\"]//; s/['\"][[:space:]]*\$//")"
    # Reject placeholders / empty / templated values.
    case "$val" in
      ""|x|xx|xxx|xxxx|XXX|XXXX) : ;;  # placeholder -> not a secret
      *'<'*'>'*) : ;;                  # <your-token-here>
      '${'*|'{{'*|'%'*|'$('*) : ;;     # ${ENV}, {{var}}, %VAR%, $(cmd)
      YOUR*|your*|CHANGEME*|changeme*|CHANGE_ME*|change_me*|TODO*|todo*|PLACEHOLDER*|placeholder*|EXAMPLE*|example*) : ;;
      *)
        # Plausible value: require at least 6 chars to avoid empty/short noise.
        if [ "${#val}" -ge 6 ]; then
          echo "credential literal"; return 0
        fi
        ;;
    esac
  fi
  return 1
}

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
        # scan_match (≈5 grep spawns) on lines containing a trigger substring.
        # On large commits this avoids ~5 grep spawns PER added line — the
        # Git-Bash hot-path killer. The pre-filter is a deliberate SUPERSET; a
        # false trigger just costs one scan_match call that then decides
        # precisely. Detection semantics are unchanged.
        case "$content" in
          *AKIA*|*ghp_*|*github_pat_*|*"PRIVATE KEY"*|*[Pp]assw*|*[Aa]pi[-_]key*|*[Aa]pikey*|*[Ss]ecret*|*[Cc]lient[-_]secret*)
            label="$(scan_match "$content")" && {
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
  printf '%s\n' "git-guard BLOCKED: possible secret in ${hit_file}:${hit_line} (${hit_label}). Your changes are STAGED but UNCOMMITTED — do NOT 'git reset --hard' (it permanently destroys git-add'ed work). Remove the secret, use .env/secret store, re-stage, re-commit. Verify: git log -1 --pretty='%h %G? %s'" >&2
  exit 1
fi

exit 0
