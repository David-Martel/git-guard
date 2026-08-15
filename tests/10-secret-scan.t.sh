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

  return 0
}
