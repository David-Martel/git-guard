#!/bin/sh
# Category 1 — the default BLOCK checks refuse their failing input (exit 1).
#
# Behaviour protected: qa_gate.sh blocks the ast-grep BLOCK trio
# (avoid-static-mut, no-glob-reexport, unsafe-with-panic), invalid JSON and,
# when validate.yaml=block, invalid YAML; secret_scan.sh blocks a provider-format
# key. Each block message names its rule, because the operator acts on the name.
#
# What a failure means: a check that README.md ("The anti-brick policy") lists
# as BLOCK lets its target into a commit in every repo that uses the installed
# release. The passing inputs for these checks are in tests/28-gate-controls.t.sh
# and tests/27-rule-behaviour.t.sh.
#
# Sourced by run.sh; helpers from lib.sh. Each fixture is generated INSIDE a
# throwaway temp repo at run time so no planted secret / invalid file is ever
# committed into git-guard itself.
# shellcheck shell=sh

t_case_blockers() {
  t_begin "01 blockers fire (exit 1)"

  # --- BLOCK trio: avoid-static-mut ---
  if gg_has_astgrep; then
    r="$(gg_mktemp_repo)"
    gg_fixture_static_mut "$r"; ( cd "$r" && git add -A )
    logf="$(gg_tmp_log)"
    gg_run_gate_log "$r" "$logf"; rc=$?
    t_expect_rc 1 "$rc" "trio avoid-static-mut blocks"
    grep -q "avoid-static-mut" "$logf" 2>/dev/null \
      && t_ok "block message names avoid-static-mut" \
      || t_fail "block message missing avoid-static-mut"
    rm -f "$logf"; gg_rmrepo "$r"

    # --- BLOCK trio: no-glob-reexport ---
    r="$(gg_mktemp_repo)"
    gg_fixture_glob_reexport "$r"; ( cd "$r" && git add -A )
    logf="$(gg_tmp_log)"
    gg_run_gate_log "$r" "$logf"; rc=$?
    t_expect_rc 1 "$rc" "trio no-glob-reexport blocks"
    grep -q "no-glob-reexport" "$logf" 2>/dev/null \
      && t_ok "block message names no-glob-reexport" \
      || t_fail "block message missing no-glob-reexport"
    rm -f "$logf"; gg_rmrepo "$r"

    # --- BLOCK trio: unsafe-with-panic ---
    r="$(gg_mktemp_repo)"
    gg_fixture_unsafe_panic "$r"; ( cd "$r" && git add -A )
    logf="$(gg_tmp_log)"
    gg_run_gate_log "$r" "$logf"; rc=$?
    t_expect_rc 1 "$rc" "trio unsafe-with-panic blocks"
    grep -q "unsafe-with-panic" "$logf" 2>/dev/null \
      && t_ok "block message names unsafe-with-panic" \
      || t_fail "block message missing unsafe-with-panic"
    rm -f "$logf"; gg_rmrepo "$r"
  else
    t_skip "BLOCK trio: ast-grep CLI absent (no genuine ast-grep on PATH)"
  fi

  # --- secret_scan blocks a PLANTED FAKE secret ---
  if gg_has_python; then
    r="$(gg_mktemp_repo)"
    gg_fixture_fake_secret "$r"; ( cd "$r" && git add -A )
    logf="$(gg_tmp_log)"
    ( cd "$r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" >/dev/null 2>"$logf" ); rc=$?
    t_expect_rc 1 "$rc" "secret_scan blocks a planted fake AWS key"
    grep -q "possible secret" "$logf" 2>/dev/null \
      && t_ok "secret_scan emits the un-missable BLOCKED message" \
      || t_fail "secret_scan message missing"
    rm -f "$logf"; gg_rmrepo "$r"
  else
    t_skip "secret_scan: python absent (used elsewhere in suite; scan itself needs only git+grep)"
  fi

  # --- invalid JSON blocks (validate.json=block default) ---
  if gg_has_python; then
    r="$(gg_mktemp_repo)"
    gg_fixture_bad_json "$r"; ( cd "$r" && git add -A )
    logf="$(gg_tmp_log)"
    gg_run_gate_log "$r" "$logf"; rc=$?
    t_expect_rc 1 "$rc" "invalid JSON blocks"
    grep -q "invalid JSON" "$logf" 2>/dev/null \
      && t_ok "block message names invalid JSON" \
      || t_fail "block message missing invalid JSON"
    rm -f "$logf"; gg_rmrepo "$r"
  else
    t_skip "invalid JSON: python absent (JSON validation self-skips)"
  fi

  # --- invalid YAML blocks (needs validate.yaml=block override + pyyaml) ---
  if gg_has_python && gg_has_pyyaml; then
    r="$(gg_mktemp_repo)"
    gg_fixture_bad_yaml "$r"
    printf 'validate.yaml=block\n' > "$r/.qa-gate.conf"
    ( cd "$r" && git add -A )
    logf="$(gg_tmp_log)"
    gg_run_gate_log "$r" "$logf"; rc=$?
    t_expect_rc 1 "$rc" "invalid YAML blocks (validate.yaml=block)"
    grep -q "invalid YAML" "$logf" 2>/dev/null \
      && t_ok "block message names invalid YAML" \
      || t_fail "block message missing invalid YAML"
    rm -f "$logf"; gg_rmrepo "$r"
  else
    t_skip "invalid YAML: python+pyyaml required (pyyaml absent → YAML validation self-skips)"
  fi
}

# JSON/YAML are byte-encoded interchange formats. Valid UTF-8 and a UTF-8 BOM
# must not be rejected because the user's default text encoding is ASCII/cp1252.
# Malformed syntax and invalid bytes must still block under that same locale.
# Run the real QA gate, with process-local Python locale controls only; neither
# the installed hooks nor the machine/user environment is changed by this case.
t_case_structured_data_encoding() {
  t_begin "01 structured-data byte encodings (real gate, non-UTF-8 locale)"
  if ! gg_has_python; then
    t_skip "structured-data encoding: python absent"
    return
  fi
  for data_kind in json yaml; do
    if [ "$data_kind" = yaml ] && ! gg_has_pyyaml; then
      t_skip "structured-data encoding YAML: pyyaml absent"
      continue
    fi
    r="$(gg_mktemp_repo)"
    printf 'validate.json=block\nvalidate.yaml=block\nastgrep=off\n' > "$r/.qa-gate.conf"
    for data_variant in utf8 utf8-bom malformed-syntax malformed-bytes; do
      # ASCII Python source writes exact fixture bytes, regardless of the
      # interpreter's or shell's own encoding. U+201D includes 0x9D in UTF-8,
      # which is undefined in cp1252 and cannot decode as ASCII.
      if ! "$(gg_python)" - "$r/encoded.$data_kind" "$data_kind" "$data_variant" <<'PY'
import pathlib
import sys

target, kind, variant = sys.argv[1:]
if kind == "json":
    data = '{"label":"right \u201d quote"}\n'.encode("utf-8")
    broken_syntax = b'{"label": [1,}\n'
    broken_bytes = b'{"label":"\xff"}\n'
else:
    data = 'label: "right \u201d quote"\n'.encode("utf-8")
    broken_syntax = b'label: [unterminated\n'
    broken_bytes = b'label: "\xff"\n'
if variant == "utf8-bom":
    data = b"\xef\xbb\xbf" + data
elif variant == "malformed-syntax":
    data = broken_syntax
elif variant == "malformed-bytes":
    data = broken_bytes
pathlib.Path(target).write_bytes(data)
PY
      then
        t_fail "$data_kind $data_variant: fixture generation failed"
        continue
      fi
      ( cd "$r" && git add -A )
      logf="$(gg_tmp_log)"
      # Disables Python UTF-8/coercion overrides on Linux and Windows only for
      # this gate invocation. Locale-dependent open() then fails the positives;
      # byte readers let json/PyYAML perform their format-specific decoding.
      PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 LC_ALL=C gg_run_gate_log "$r" "$logf"; rc=$?
      case "$data_variant" in
        utf8|utf8-bom)
          t_expect_rc 0 "$rc" "$data_kind $data_variant valid bytes pass in non-UTF-8 locale"
          if grep -q 'invalid JSON\|invalid YAML' "$logf"; then
            t_fail "$data_kind $data_variant: valid data reported invalid"
          else
            t_ok "$data_kind $data_variant: no invalid-data warning"
          fi
          ;;
        *)
          t_expect_rc 1 "$rc" "$data_kind $data_variant invalid data blocks"
          case "$data_kind" in json) data_label=JSON ;; *) data_label=YAML ;; esac
          if grep -q "invalid $data_label: encoded.$data_kind" "$logf"; then
            t_ok "$data_kind $data_variant: diagnostic names the invalid file"
          else
            t_fail "$data_kind $data_variant: missing invalid-file diagnostic"
          fi
          ;;
      esac
      rm -f "$logf"
    done
    gg_rmrepo "$r"
  done
}
