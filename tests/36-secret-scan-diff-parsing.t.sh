#!/bin/sh
#
# git-guard tests -- secret_scan.sh reads the staged diff, and the file content it
# reads is untrusted. A line of CONTENT that merely looks like diff structure must
# not change how the rest of the diff is read.
#
# The scanner used to treat every diff line starting with "+++" as either a file
# header ("+++ b/path", "+++ /dev/null") or a stray header to skip. A content line
# that BEGINS with "++" shows up in the diff as "+++...", so:
#
#   ++<secret>          was skipped outright (never scanned, line counter not advanced)
#   ++ /dev/null        cleared the current file, so every later added line in the
#                       diff was skipped until the next real header
#   ++ b/other.rs       switched the file context mid-hunk, so a later unquoted
#                       credential was judged as source code (never a literal)
#
# Inside a hunk every line is content, whatever it looks like; "+++ " is a header
# only between "diff --git" and the first "@@".
#
# Planted secrets are ASSEMBLED FROM FRAGMENTS at run time (see 10-secret-scan.t.sh),
# and the second half is a deterministic generative test: it writes many files from
# a pool of lines that imitate diff structure, plants a secret in some of them, and
# requires the scan to block exactly those.

# _sd_scan REPO — run the scan in REPO; set _sd_rc and _sd_out.
_sd_scan() {
  _sd_out="$(cd "$1" && sh "$GG_ROOT/hooks/common/secret_scan.sh" 2>&1)"; _sd_rc=$?
}

# _sd_stage REPO FILE CONTENT — replace the staged state with one file.
_sd_stage() {
  ( cd "$1" && git rm -rq --cached . >/dev/null 2>&1; rm -f ./*.* ) 2>/dev/null
  printf '%s\n' "$3" > "$1/$2"
  ( cd "$1" && git add -A >/dev/null 2>&1 )
}

_sd_expect_block() {
  _sd_stage "$1" "$3" "$4"; _sd_scan "$1"
  if [ "$_sd_rc" = 1 ]; then t_ok "blocks: $2"; else t_fail "blocks: $2 (rc=$_sd_rc)"; fi
}

_sd_expect_allow() {
  _sd_stage "$1" "$3" "$4"; _sd_scan "$1"
  if [ "$_sd_rc" = 0 ]; then t_ok "allows: $2"; else t_fail "allows: $2 (rc=$_sd_rc)"; fi
}

# _sd_generate SEED FILE EXPECT_FILE — write a file of 1..12 lines drawn from a pool
# that includes diff-shaped content, and EXPECT_FILE = "block" or "allow".
# awk is used for the PRNG so the sequence is the same on every platform's awk
# for a given seed (only integer arithmetic below).
_sd_generate() {
  awk -v seed="$1" -v out="$2" -v expect_file="$3" '
    function next_rand(n) { state = (state * 16807) % 2147483647; return int(state / 128) % n }
    BEGIN {
      state = seed * 7919 + 13
      aws = "AKIA" "ABCDEFGHIJKLMNOP"
      gh = "ghp" "_" "0123456789abcdef0123456789abcdef0123"
      pragma = "  # pragma: allowlist secret"
      npool = 0
      pool[npool++] = "plain text"
      pool[npool++] = ""
      pool[npool++] = "++ b/other.rs"
      pool[npool++] = "++ /dev/null"
      pool[npool++] = "+++ b/x.py"
      pool[npool++] = "++"
      pool[npool++] = "+++"
      pool[npool++] = "@@ -1,2 +3,4 @@"
      pool[npool++] = "-- removed-looking"
      pool[npool++] = "--- a/old"
      pool[npool++] = "diff --git a/x b/x"
      pool[npool++] = "index 0000000..1111111 100644"
      pool[npool++] = "\\ No newline at end of file"
      pool[npool++] = " leading space"
      pool[npool++] = "-"
      pool[npool++] = "x:@@ y"
      pool[npool++] = "x:diff --git a b"
      pool[npool++] = "a:+b"
      pool[npool++] = "+"
      n = 1 + next_rand(12)
      plant_at = (next_rand(3) == 0) ? 0 : 1 + next_rand(n)
      block = 0
      for (i = 1; i <= n; i++) {
        if (i == plant_at) {
          kind = next_rand(8)
          secret = (next_rand(2) == 0) ? aws : gh
          prefix = (kind == 0) ? "++" : (kind == 1) ? "+++" : (kind == 2) ? "++ " : ""
          line = prefix "token = \"" secret "\""
          if (kind == 3) line = "x=" secret
          if (kind == 4) { line = secret; }
          if (kind == 5) line = "++ /dev/null"
          if (kind == 5) { print line > out; line = "key: " secret }
          if (kind == 6) line = "x=" secret " :@@ z"
          if (kind == 7) { print "x:diff --git a b" > out; print "++ /dev/null" > out; line = "key: " secret }
          if (next_rand(4) == 0) { line = line pragma } else { block = 1 }
          print line > out
        } else {
          print pool[next_rand(npool)] > out
        }
      }
      print (block ? "block" : "allow") > expect_file
    }'
}

t_case_secret_scan_diff_parsing() {
  t_begin "secret_scan: diff-shaped file content cannot hide or redirect a scan"

  if ! have git || ! have awk; then
    t_skip "secret_scan diff parsing: git or awk absent"
    return 0
  fi

  _r="$(gg_mktemp_repo)" || return 99
  _aws="AKIA";  _aws_b="ABCDEFGHIJKLMNOP"
  _key="${_aws}${_aws_b}"

  # ---- the three bypasses, one file each -----------------------------------
  _sd_expect_block "$_r" "secret on a line that begins with ++" a.txt "++token = \"${_key}\""
  _sd_expect_block "$_r" "secret after a '++ /dev/null' line" b.txt "++ /dev/null
token = \"${_key}\""
  _sd_expect_block "$_r" "secret after a '++ b/other.rs' line" c.txt "++ b/other.rs
token = \"${_key}\""
  _sd_expect_block "$_r" "secret after '+++' and '++' lines" d.txt "+++
++
token = \"${_key}\""

  # The hunk state is decided on the START of the diff line. A content line that merely
  # CONTAINS ":@@ " or ":diff --git " (or begins "a:+") must not be read as structure.
  _sd_expect_block "$_r" "secret followed by ' :@@ x' on the same line" i.txt "token = \"${_key}\" :@@ x"
  _sd_expect_block "$_r" "content line 'x:diff --git a b' does not end the hunk" j.txt "x:diff --git a b
++ /dev/null
token = \"${_key}\""
  _sd_expect_block "$_r" "content line 'a:+b' is still content" k.txt "a:+b
-a:+b
token = \"${_key}\""

  # An unquoted credential in a config file is a literal there but code in a source
  # file. A forged '++ b/x.rs' header must not switch the verdict.
  _pw="PASSWORD"; _pw_v="Zq81hT5xPw30LmN"
  _sd_expect_block "$_r" "unquoted config credential after a forged source header" e.env "++ b/x.rs
${_pw}=${_pw_v}"

  # ---- the pragma still exempts, and benign diff-shaped lines still pass ------
  _sd_expect_allow "$_r" "pragma line starting with ++" f.txt "++token = \"${_key}\"  # pragma: allowlist secret"
  _sd_expect_allow "$_r" "diff-shaped lines without a secret" g.txt "++ /dev/null
++ b/other.rs
+++
@@ -1 +1 @@
-- gone
plain"

  # ---- the finding names the right file and line ---------------------------------
  _sd_stage "$_r" h.txt "ok
++ /dev/null
++token = \"${_key}\""
  _sd_scan "$_r"
  case "$_sd_out" in
    *"h.txt:3"*) t_ok "line number counts the ++ lines" ;;
    *) t_fail "line number counts the ++ lines (got: $_sd_out)" ;;
  esac

  # ---- real headers still work: a secret in the SECOND of two staged files ---------
  printf 'clean\n' > "$_r/first.txt"
  printf '++ b/first.txt\ntoken = "%s"\n' "$_key" > "$_r/second.txt"
  ( cd "$_r" && git rm -rq --cached . >/dev/null 2>&1; git add first.txt second.txt >/dev/null 2>&1 )
  _sd_scan "$_r"
  case "$_sd_out" in
    *"second.txt:2"*) t_ok "two-file diff still attributes the hit to the second file" ;;
    *) t_fail "two-file diff still attributes the hit to the second file (rc=$_sd_rc: $_sd_out)" ;;
  esac
  rm -f "$_r/first.txt" "$_r/second.txt"

  # ---- generative: block exactly the files that carry an un-pragma'd secret --------
  _n="${GG_FUZZ_ITERATIONS:-40}"
  _bad=0
  _i=1
  while [ "$_i" -le "$_n" ]; do
    _gen="$GG_T_TMPROOT/sd-gen-$_i.txt"; _exp="$GG_T_TMPROOT/sd-exp-$_i.txt"
    rm -f "$_gen" "$_exp"
    _sd_generate "$((_i + ${GG_FUZZ_SEED_BASE:-0}))" "$_gen" "$_exp"
    ( cd "$_r" && git rm -rq --cached . >/dev/null 2>&1; rm -f ./*.* ) 2>/dev/null
    cp "$_gen" "$_r/gen.txt"
    ( cd "$_r" && git add -A >/dev/null 2>&1 )
    _sd_scan "$_r"
    _want="$(cat "$_exp")"
    if { [ "$_want" = block ] && [ "$_sd_rc" = 1 ]; } || { [ "$_want" = allow ] && [ "$_sd_rc" = 0 ]; }; then
      :
    else
      _bad=$((_bad + 1))
      t_fail "generated file seed=$((_i + ${GG_FUZZ_SEED_BASE:-0})) expected $_want, scan rc=$_sd_rc"
    fi
    rm -f "$_gen" "$_exp"
    _i=$((_i + 1))
  done
  if [ "$_bad" = 0 ]; then t_ok "generated diff-shaped files: $_n of $_n scanned correctly"; fi

  gg_rmrepo "$_r"
}
