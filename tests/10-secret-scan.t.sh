#!/bin/sh
#
# git-guard tests — secret_scan.sh (tier 1 provider formats, tier 2 contextual
# key=value literals, and the false-positive regressions that motivated the
# 2026-08-12 context rewrite).
#
# Every planted "secret" is ASSEMBLED FROM FRAGMENTS at runtime so that this
# file itself never contains a complete pattern — git-guard's own pre-commit
# gate would otherwise refuse to commit its own test suite. Lines that must
# embed credential-ish text carry the detect-secrets pragma for the same reason.
#
# The regressions (all real, all previously BLOCKING):
#   self.password = fallback.password;   -> value "fallback.password;"
#   api_key: String,                     -> value "String,"
#   config.api_key.clone(),              -> value "config.api_key.clone(),"
#   POSTGRES_PASSWORD: postgres          -> value "postgres"
#   $token = "$safeTag-$gitSha"          -> value "$safeTag-$gitSha"
# A storage module that merely *handles* credentials could not be committed.

# _ss_probe FILENAME CONTENT — stage CONTENT as FILENAME in a throwaway repo and
# run secret_scan.sh against it. Returns the scan's exit code (1 = blocked).
_ss_probe() {
  _r="$(gg_mktemp_repo)" || return 99
  printf '%s\n' "$2" > "$_r/$1"
  ( cd "$_r" && git add -A >/dev/null 2>&1 )
  ( cd "$_r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" >/dev/null 2>&1 )
  _rc=$?
  gg_rmrepo "$_r"
  return $_rc
}

# _ss_blocks   NAME FILE CONTENT — assert the scan BLOCKS (rc 1).
# Capture rc into a variable first: reading $? inside the message would report
# the status of the `[` test, not of the scan.
_ss_blocks() {
  _ss_probe "$2" "$3"; _got=$?
  if [ "$_got" = "1" ]; then t_ok "blocks: $1"
  else t_fail "blocks: $1 (expected rc=1, got rc=$_got)"; fi
}

# _ss_allows   NAME FILE CONTENT — assert the scan ALLOWS (rc 0).
_ss_allows() {
  _ss_probe "$2" "$3"; _got=$?
  if [ "$_got" = "0" ]; then t_ok "allows: $1"
  else t_fail "allows: $1 (expected rc=0, got rc=$_got)"; fi
}


# Diagnose synthetic staged records without printing their assembled value.
_ss_label_probe() {
  _r="$(gg_mktemp_repo)" || return 99
  printf 'harmless line\ntoken=%s\n' "$1" > "$_r/provider.txt"
  (cd "$_r" && git add provider.txt) >/dev/null 2>&1
  _diagnostic="$(cd "$_r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" 2>&1)"; _got=$?
  case "$_diagnostic" in
    *"provider.txt:2 ($2)"*) _label_ok=1 ;;
    *) _label_ok=0 ;;
  esac
  if [ "$_got" = 1 ] && [ "$_label_ok" = 1 ]; then t_ok "provider label/path/line: $2"
  else t_fail "provider label/path/line: $2 (rc=$_got, label=$_label_ok)"; fi
  gg_rmrepo "$_r"
}

_ss_matcher_error_probe() {
  _r="$(gg_mktemp_repo)" || return 99
  printf '%s\n' 'token=abcDEF012345' > "$_r/check.conf"
  (cd "$_r" && git add check.conf) >/dev/null 2>&1
  mkdir "$_r/matcher-bin"
  cat > "$_r/matcher-bin/grep" <<'GG_MATCHER_ERROR'
#!/bin/sh
n=0
[ ! -f "$GG_MATCHER_COUNT" ] || n="$(cat "$GG_MATCHER_COUNT")"
n=$((n+1)); printf '%s' "$n" > "$GG_MATCHER_COUNT"
case "$GG_MATCHER_PHASE:$n" in
  provider:1) exit 2 ;;
  ordered:1) exit 0 ;;
  ordered:2) exit 2 ;;
  context:1) exit 1 ;;
  context:2) exit 2 ;;
  code:1) exit 1 ;;
  code:2) exit 0 ;;
  code:3) exit 2 ;;
  interpolate:1|lower:1|upper:1) exit 1 ;;
  interpolate:2|lower:2|upper:2) exit 0 ;;
  interpolate:3|lower:3|upper:3) exit 1 ;;
  interpolate:4) exit 2 ;;
  lower:4) exit 1 ;;
  lower:5) exit 2 ;;
  upper:4|upper:5) exit 1 ;;
  upper:6) exit 2 ;;
  *) exit 1 ;;
esac
GG_MATCHER_ERROR
  chmod +x "$_r/matcher-bin/grep"
  _diagnostic="$(cd "$_r" && PATH="$_r/matcher-bin:$PATH" GG_MATCHER_COUNT="$_r/count" GG_MATCHER_PHASE="$1" sh "$GG_ROOT/hooks/common/secret_scan.sh" 2>&1)"; _got=$?
  case "$_diagnostic" in *'secret scan matcher failed'*) _failed=1 ;; *) _failed=0 ;; esac
  if [ "$_got" = 1 ] && [ "$_failed" = 1 ]; then t_ok "matcher status 2 fails closed: $1"
  else t_fail "matcher status 2 fails closed: $1 (rc=$_got, diagnostic=$_failed)"; fi
  gg_rmrepo "$_r"
}

# A no-hit status remains a successful whole scan even when sh -e is used.
_ss_errexit_probe() {
  _r="$(gg_mktemp_repo)" || return 99
  printf '%s\n' 'token=environment.lookup()' 'password=postgres' > "$_r/safe.conf"
  (cd "$_r" && git add safe.conf) >/dev/null 2>&1
  _diagnostic="$(cd "$_r" && sh -e "$GG_ROOT/hooks/common/secret_scan.sh" 2>&1)"; _got=$?
  if [ "$_got" = 0 ]; then t_ok "normal negative scan remains successful with errexit"
  else t_fail "negative scan with errexit (rc=$_got)"; fi
  gg_rmrepo "$_r"
}

t_case_secret_scan() {
  t_begin "secret_scan: provider formats, contextual literals, FP regressions"

  if ! have git; then
    t_skip "secret_scan: git absent"
    return 0
  fi

  # ---- TIER 1: high-confidence provider formats (assembled at runtime) ------
  _aws="AKIA";      _aws_b="EXAMPLEFAKEKEY42"
  _ss_blocks "AWS access key" "leak.js" "const K = \"${_aws}${_aws_b}\";"

  _gh="ghp_";       _gh_b="0123456789abcdef0123456789abcdef0123"
  _ss_blocks "GitHub classic PAT" "leak.js" "const K = \"${_gh}${_gh_b}\";"

  _gl="glpat-";     _gl_b="abcdefghij0123456789XY"
  _ss_blocks "GitLab PAT" "leak.js" "const K = \"${_gl}${_gl_b}\";"

  _sl="xox";        _sl_b="b-1234567890-FAKEFAKEFAKE"
  _ss_blocks "Slack bot token" "leak.js" "const K = \"${_sl}${_sl_b}\";"

  _go="AIza";       _go_b="SyA0123456789abcdefghijklmnopqrstuvw"
  _ss_blocks "Google API key" "leak.js" "const K = \"${_go}${_go_b}\";"

  _st="sk_live_";   _st_b="0123456789abcdefXYZ"
  _ss_blocks "Stripe live key" "leak.js" "const K = \"${_st}${_st_b}\";"

  _an="sk-";        _an_b="ant-api03-0123456789abcdefghij"
  _ss_blocks "Anthropic API key" "leak.js" "const K = \"${_an}${_an_b}\";"

  # Discord tokens have no distinctive prefix, so unlike every other tier-1
  # format they cannot be pre-filtered on their own shape — the cheap pure-shell
  # pre-filter has to catch them via a nearby `token` key. That is how they
  # actually appear in configs, and it is what this fixture pins.
  # Split so NEITHER fragment is a whole token on its own: the first has no
  # third segment, and the second starts with 'K' so it fails the leading
  # [MNO] class. GitHub push protection rejected an earlier split whose second
  # fragment began with 'N' and was therefore a complete, valid-looking token
  # sitting in the file — the same reason lib.sh assembles its AWS fixture.
  _dc="MTIzNDU2Nzg5MDEyMzQ1Njc4OTA.GhIj"; _dc_b="Kl.0123456789abcdefghijklmnopq"
  _ss_blocks "Discord bot token" "config.json" "{\"bot_token\": \"${_dc}${_dc_b}\"}"

  _jw="eyJ";        _jw_b="hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig"
  _ss_blocks "JWT" "leak.js" "const K = \"${_jw}${_jw_b}\";"

  _pem="-----BEGIN"; _pem_b=" RSA PRIVATE KEY-----"
  _ss_blocks "PEM private key header" "id_rsa" "${_pem}${_pem_b}"

  # ---- TIER 2 positives: genuine hardcoded literals -------------------------
  # Quoted literal in SOURCE — the classic hardcoded credential.
  _v1="s3cr3t"; _v2="P@ssw0rd99"
  _ss_blocks "quoted credential literal in .rs" "cfg.rs" \
    "let c = Config { password: \"${_v1}${_v2}\".to_string() };"

  # Unquoted bare token in a .env — the normal way to write one there.
  _ss_blocks "unquoted credential in .env" ".env" \
    "DB_PASSWORD=${_v1}${_v2}"

  # Unquoted in a shell script is a real assignment too (.sh is NOT treated as
  # "source requiring quotes", deliberately).
  _ss_blocks "unquoted credential in .sh" "deploy.sh" \
    "export API_KEY=${_v1}${_v2}"

  # ---- TIER 2 negatives: the regressions ------------------------------------
  # Field access / assignment between struct fields.
  _ss_allows "rust field-to-field assignment" "repo_config.rs" \
    'self.password = fallback.password;'                      # pragma: allowlist secret

  # A struct field DECLARATION — the "value" is a type name.
  _ss_allows "rust struct field type" "providers.rs" \
    '    pub api_key: String,'                                # pragma: allowlist secret

  # A method call on a field.
  _ss_allows "rust method call on field" "providers.rs" \
    '            api_key: config.api_key.clone(),'            # pragma: allowlist secret

  # A function call with a closure.
  _ss_allows "rust call + closure" "lib.rs" \
    '    let password = runtime_password().or_else(|| None);'  # pragma: allowlist secret

  # A bare identifier terminating a statement.
  _ss_allows "rust bare identifier" "cli.rs" \
    '    let k = llm_api_key;'                                # pragma: allowlist secret

  # CI service-container default: low-entropy all-lowercase word.
  _ss_allows "CI postgres service default" "ci.yml" \
    '          POSTGRES_PASSWORD: postgres'                   # pragma: allowlist secret

  # PowerShell/shell interpolation is a template, not a literal.
  _ss_allows "interpolated build tag" "helpers.ps1" \
    '    $token = "$safeTag-$gitSha-$tokenTime"'              # pragma: allowlist secret

  # Placeholder families.
  _ss_allows "test placeholder fixture" "providers.rs" \
    '            api_key: "test-api-key".to_string(),'        # pragma: allowlist secret
  _ss_allows "env-var template" ".env" \
    'DB_PASSWORD=${POSTGRES_PASSWORD}'                        # pragma: allowlist secret
  _ss_allows "angle-bracket placeholder" "README.md" \
    'api_key: <your-api-key-here>'                            # pragma: allowlist secret
  _ss_allows "CHANGEME placeholder" ".env.example" \
    'CLIENT_SECRET=CHANGEME_before_deploy'                    # pragma: allowlist secret

  # A comparison assigns nothing.
  _ss_allows "equality comparison" "auth.py" \
    'if password == expected_password_value:'                 # pragma: allowlist secret

  # ---- the pragma escape hatch still works ---------------------------------
  _ss_allows "pragma exempts a real-looking literal" "fixture.rs" \
    "let p = \"${_v1}${_v2}\"; // pragma: allowlist secret"

  # ---- unrelated content is untouched --------------------------------------
  _ss_allows "ordinary code with no credential keys" "main.rs" \
    'fn main() { println!("hello"); }'

  # ---- RENAMED FILES: an added secret in a renamed file must be scanned ------
  # --diff-filter=ACM dropped status R, so editing a file while renaming it hid
  # the added line from both the staged scan and --commits mode. The planted
  # value is assembled at runtime; the control renames with no added secret.
  _rn_secret="AKIA""EXAMPLEFAKEKEY42"
  _rn_repo() {  # $1 = line added during the rename; leaves the rename staged
    _r="$(gg_mktemp_repo)" || return 1
    i=1; : > "$_r/old.txt"
    while [ "$i" -le 20 ]; do printf 'line %s of a stable file body\n' "$i" >> "$_r/old.txt"; i=$((i+1)); done
    ( cd "$_r" && git add old.txt && git -c user.name=t -c user.email=t@t commit -qm base --no-gpg-sign ) >/dev/null 2>&1
    ( cd "$_r" && git mv old.txt new.txt ) >/dev/null 2>&1
    [ -n "$1" ] && printf '%s\n' "$1" >> "$_r/new.txt"
    ( cd "$_r" && git add -A ) >/dev/null 2>&1
    printf '%s' "$_r"
  }
  _r="$(_rn_repo "const K = \"${_rn_secret}\";")"
  ( cd "$_r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" >/dev/null 2>&1 ); _got=$?
  if [ "$_got" = "1" ]; then t_ok "blocks: secret added while renaming (staged)"
  else t_fail "blocks: secret added while renaming (staged) (expected rc=1, got rc=$_got)"; fi
  _parent="$(git -C "$_r" rev-parse HEAD)"
  _tree="$(git -C "$_r" write-tree)"
  _head="$(printf 'synthetic rename history\n' | git -C "$_r" commit-tree "$_tree" -p "$_parent")"; _seed_rc=$?
  t_expect_rc 0 "$_seed_rc" "fake rename history is created by isolated Git plumbing"
  [ "$_seed_rc" = 0 ] && git -C "$_r" update-ref HEAD "$_head" "$_parent"
  t_expect_rc 0 "$?" "fake rename history advances exactly the expected fixture HEAD"
  _head="$(cd "$_r" && git rev-parse HEAD)"
  ( cd "$_r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" --commits "$_head" >/dev/null 2>&1 ); _got=$?
  if [ "$_got" = "1" ]; then t_ok "blocks: secret added while renaming (--commits)"
  else t_fail "blocks: secret added while renaming (--commits) (expected rc=1, got rc=$_got)"; fi
  gg_rmrepo "$_r"
  _r="$(_rn_repo "a harmless added line")"
  ( cd "$_r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" >/dev/null 2>&1 ); _got=$?
  if [ "$_got" = "0" ]; then t_ok "allows: rename with a harmless edit (staged)"
  else t_fail "allows: rename with a harmless edit (staged) (expected rc=0, got rc=$_got)"; fi
  gg_rmrepo "$_r"

  # ---- portability: no `grep -e` anywhere in the scanner --------------------
  # The "PEM private key header" case above passed for months while the detector
  # was FAILING OPEN in the field: it used `grep -Eq -e PATTERN` (needed only
  # because the pattern starts with '-'), and uutils grep — common on PATH via a
  # ~/bin coreutils shim — rejects `-e`. The behavioural test could not see it
  # because the suite runs wherever GNU grep wins the PATH. Proven 2026-08-15 by
  # committing an OPENSSH PRIVATE KEY with uutils grep ahead of GNU grep while the
  # AWS detector still blocked.
  #
  # So assert the STRUCTURE, not just the behaviour: a leading-'-' pattern must be
  # written with a bracket ('[-]----BEGIN'), which needs no flag and works on both.
  # Match only real invocations: a non-comment line calling grep with a standalone
  # -e argument. (`sed -e` is fine — sed accepts it everywhere.)
  if grep -Eq '^[[:space:]]*[^#]*[^a-z]grep[^|;]*[[:space:]]-e[[:space:]]' \
       "$GG_ROOT/hooks/common/secret_scan.sh" 2>/dev/null; then
    t_fail "portability: secret_scan.sh must not use 'grep -e' (uutils grep rejects it; bracket the leading dash instead)"
  else
    t_ok "portability: no 'grep -e' in secret_scan.sh"
  fi


  # All 19 provider labels retain original priority and path/line diagnostics.
  _tail32=0123456789abcdef0123456789abcdef
  _ss_label_probe "AKIA""1234567890ABCDEF" 'AWS access key'
  _ss_label_probe "ghp_""$_tail32" 'GitHub PAT'
  _ss_label_probe "github_pat_""$_tail32" 'GitHub fine-grained PAT'
  _ss_label_probe "gho_""$_tail32" 'GitHub token'
  _ss_label_probe "glpat-""$_tail32" 'GitLab PAT'
  _ss_label_probe "xoxb-""$_tail32" 'Slack token'
  _ss_label_probe "AIza""${_tail32}abc" 'Google API key'
  _ss_label_probe "sk_live_""$_tail32" 'Stripe live key'
  _ss_label_probe "sk-ant-""$_tail32" 'Anthropic API key'
  _ss_label_probe "sk-proj-""$_tail32" 'OpenAI project key'
  _ss_label_probe "sk-""$_tail32" 'OpenAI API key'
  _ss_label_probe "npm_""${_tail32}abcd" 'npm token'
  _ss_label_probe "pypi-AgEIcHlwaS5vcmc""$_tail32" 'PyPI token'
  _ss_label_probe "SG.""${_tail32}.${_tail32}" 'SendGrid API key'
  _ss_label_probe "SK""$_tail32" 'Twilio key SID'
  _ss_label_probe "M123456789012345678901234"".123456.${_tail32}" 'Discord bot token'
  _ss_label_probe "AccountKey=""${_tail32}${_tail32}" 'Azure storage key'
  _ss_label_probe "eyJ""1234567890.eyJ1234567890.sig" 'JWT'
  _ss_label_probe "-----BEGIN"" RSA PRIVATE KEY-----" 'private key'
  _ss_label_probe "AKIA""1234567890ABCDEF ghp_${_tail32}" 'AWS access key'
  _ss_matcher_error_probe provider
  _ss_matcher_error_probe context
  _ss_matcher_error_probe ordered
  _ss_matcher_error_probe code
  _ss_matcher_error_probe interpolate
  _ss_matcher_error_probe lower
  _ss_matcher_error_probe upper
  _ss_errexit_probe

  # Protects: empty Python key markers in stderr redaction witnesses.
  # Detects: closing-quote misclassification and a final empty marker hiding a
  # real quoted assignment. Provider detection keeps its original input.
  # Needs: canonical POSIX/Git helpers; no Python runtime dependency.
  # Breadcrumb: vigil-utils test_vigil1_registrar_diagnostics.py lines 92/161.
  _empty_marker="RAW_""PASSWORD="
  _ss_allows "python native stderr empty-marker expression (registrar 92)" "fixture.py" \
    "stderr = (\"${_empty_marker}\" + TOKEN).encode()"
  _ss_allows "python cleanup stderr empty-marker expression (registrar 161)" "fixture.py" \
    "stderr = (\"${_empty_marker}\" + TOKEN).encode()"
  _ss_allows "python ordinary empty marker literal" "fixture.py" \
    "message = \"${_empty_marker}\""
  _ss_allows "python single-quoted empty marker expression" "fixture.py" \
    "stderr = ('${_empty_marker}' + TOKEN).encode()"
  _ss_blocks "python quoted assignment precedes final empty marker" "fixture.py" \
    "password = \"${_v1}${_v2}\"; message = \"${_empty_marker}\""
  _ss_blocks "python quoted assignment follows empty marker" "fixture.py" \
    "message = \"${_empty_marker}\"; password = \"${_v1}${_v2}\""

  return 0
}
