#!/bin/sh
#
# git-guard quality mandate, native changed-line scan of staged Rust (POSIX sh, git, awk,
# ast-grep). No interpreter is run or probed (git-guard #118: clarius forbids executing
# Python, hooks included).
#
# Called by mandate_scan.sh --staged when no staged Python file is in scope, so every rule
# that can fire is a Rust rule (rust_panic, through ast-grep) or the comment check
# (suppression_reason). It is the same scan as mandate_scan.py changed_mode for that
# case: the policy is read from the index (repo conf, global defaults, machine overlay,
# through qa_gate.sh --get-prefix), the staged blobs are exported (the working tree is
# never read), findings are filtered for vendored and test paths and for suppressions,
# and BLOCK / CHANGED / WARN apply to the lines this commit adds. A merge keeps only the
# lines new against every parent. Output and exit status match the Python scanner:
# 0 PASSED, 1 BLOCKED, 2 TOOL ERROR (fail closed; never a clean scan).
#
# Usage: sh mandate_native.sh --staged

set -u

nm_dir="$(cd "$(dirname "$0")" && pwd -P)"
nm_rules="$nm_dir/../../rules-examples/mandate"
nm_tmp=""

nm_say() { printf '%s\n' "$*" >&2; }
nm_cleanup() { [ -n "$nm_tmp" ] && rm -rf "$nm_tmp"; }
trap nm_cleanup EXIT
trap 'exit 2' HUP INT TERM

# nm_tool_error TOOL DETAIL [COMMAND...]: the Python scanner's TOOL ERROR report; exit 2.
nm_tool_error() {
  nm_tool="$1" nm_detail="$2"; shift 2
  nm_say "git-guard mandate TOOL ERROR [$nm_tool]: $nm_detail"
  [ "$#" -gt 0 ] && nm_say "    command: $*"
  nm_say "git-guard mandate: TOOL ERROR — the quality mandate could not be evaluated, so the result is refused (fail closed); this is NOT a clean scan. Fix the tool or its configuration and retry."
  exit 2
}
nm_config_error() {
  nm_say "git-guard mandate TOOL ERROR [config]: $1"
  nm_say "git-guard mandate: TOOL ERROR — the quality mandate could not be evaluated, so the result is refused (fail closed)."
  exit 2
}

[ "${1:-}" = "--staged" ] || nm_tool_error usage "mandate_native.sh supports --staged only (got '${1:-}')"
nm_root="$(git rev-parse --show-toplevel 2>/dev/null)" || nm_tool_error git "not inside a git work tree" git rev-parse --show-toplevel
cd "$nm_root" || nm_tool_error git "cannot enter $nm_root"
nm_tmp="$(mktemp -d "${TMPDIR:-/tmp}/git-guard-mandate.XXXXXX")" || nm_tool_error tmp "cannot create a scratch directory"
nm_start="$(date +%s 2>/dev/null || echo 0)"

# --- rules this script knows (the mandate_scan.py RULES table) ------------------------
# key|default|ruff codes (comma-separated). Every key must be listed: an unknown
# mandate.* key in the policy is a TOOL ERROR, as in the Python scanner. Test 42 checks
# this list against mandate_scan.py's source, without running it.
NM_RULES='pydantic_v1|block|
pydantic_v1_ambiguous|warn|
bare_except|block|E722
blind_except|changed|BLE001
except_pass|changed|S110
except_continue|changed|S112
except_sentinel|warn|
broad_suppress|changed|
no_any|changed|ANN401
raise_from|changed|B904
bare_exception_raise|changed|TRY002
raise_without_message|changed|
unchecked_subprocess|changed|PLW1510
suppression_code|changed|PGH003,PGH004
suppression_reason|changed|
str_enum_param|warn|
literal_enum|warn|
magic_number|warn|PLR2004
python_syntax|changed|
rust_panic|changed|'

# --- policy from the index ---------------------------------------------------------------
nm_label=index
nm_repo_conf=""
nm_source="index, no repo conf"
for nm_cand in .qa-gate.conf .git-guard/qa-gate.conf; do
  if git cat-file blob ":$nm_cand" > "$nm_tmp/repo-conf" 2>/dev/null; then
    nm_repo_conf="$nm_tmp/repo-conf"
    nm_source="$nm_label $nm_cand"
    break
  fi
done
nm_conf_arg="$nm_repo_conf"
if [ -n "$nm_conf_arg" ] && command -v cygpath >/dev/null 2>&1; then nm_conf_arg="$(cygpath -m "$nm_conf_arg")"; fi
if ! sh "$nm_dir/qa_gate.sh" --get-prefix mandate. --repo-conf "$nm_conf_arg" > "$nm_tmp/policy" 2> "$nm_tmp/policy.err"; then
  [ -f "$nm_dir/qa-gate.conf.local" ] && nm_source="$nm_source + machine overlay $nm_dir/qa-gate.conf.local"
  cat "$nm_tmp/policy.err" >&2
  nm_config_error "qa_gate.sh could not read the mandate.* configuration of $nm_source (malformed conf; its own message is above)."
fi
[ -f "$nm_dir/qa-gate.conf.local" ] && nm_source="$nm_source + machine overlay $nm_dir/qa-gate.conf.local"

# Resolve every rule's severity, mandate.enabled and mandate.vendored. Prints
# "enabled=on|off", "vendored=<prefix>" lines and "sev <key> <severity>" lines, or an
# "error <message>" line.
printf '%s\n' "$NM_RULES" > "$nm_tmp/rules"
awk -F'|' -v src="$nm_source" '
  FNR == NR { def[$1] = $2; codes[$1] = $3; order[++n] = $1; next }
  {
    eq = index($0, "="); if (eq == 0) next
    k = substr($0, 1, eq - 1); v = substr($0, eq + 1)
    gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
    val[k] = v; seen[k] = 1
  }
  END {
    en = ("mandate.enabled" in val && val["mandate.enabled"] != "") ? val["mandate.enabled"] : "on"
    if (en != "on" && en != "off") { print "error mandate.enabled=" en " is not one of: on, off (policy: " src ")"; exit }
    print "enabled=" en
    raw = ("mandate.vendored" in val) ? val["mandate.vendored"] : ""
    m = split(raw, items, ",")
    for (i = 1; i <= m; i++) {
      item = items[i]; gsub(/^[ \t]+|[ \t]+$/, "", item)
      if (item == "") continue
      p = item; gsub(/^\/+|\/+$/, "", p)
      bad = (p == "" || substr(item, 1, 1) == "/")
      q = split(p, segs, "/"); for (j = 1; j <= q; j++) if (segs[j] == "..") bad = 1
      if (bad) { print "error mandate.vendored entry \047" item "\047 must be a repo-relative directory without \047..\047 (comma-separated, e.g. mandate.vendored=qobi/chumpy,src/cardiac/usgr)"; exit }
      print "vendored=" p
    }
    unknown = ""
    for (k in seen) {
      if (k == "mandate.enabled" || k == "mandate.vendored") continue
      r = substr(k, 9)
      if (!(r in def)) unknown = unknown (unknown == "" ? "" : ", ") k
    }
    if (unknown != "") { print "error qa_gate.sh knows mandate keys this scanner does not: " unknown ". QA_KNOWN_KEYS and the mandate RULES have drifted; reinstall git-guard."; exit }
    for (i = 1; i <= n; i++) {
      r = order[i]; s = ("mandate." r in val && val["mandate." r] != "") ? val["mandate." r] : def[r]
      if (s != "off" && s != "warn" && s != "changed" && s != "block") { print "error mandate." r "=" s " is not one of: off, warn, changed, block (policy: " src ")"; exit }
      print "sev " r " " s " " codes[r]
    }
  }' "$nm_tmp/rules" "$nm_tmp/policy" > "$nm_tmp/resolved" || nm_tool_error awk "cannot resolve the mandate policy"
nm_err="$(sed -n 's/^error //p' "$nm_tmp/resolved" | head -n 1)"
[ -z "$nm_err" ] || nm_config_error "$nm_err"
grep -q '^enabled=off$' "$nm_tmp/resolved" && exit 0
sed -n 's/^vendored=//p' "$nm_tmp/resolved" > "$nm_tmp/vendored"
nm_sev() { awk -v k="$1" '$1 == "sev" && $2 == k { print $3 }' "$nm_tmp/resolved"; }
nm_panic_sev="$(nm_sev rust_panic)"
nm_reason_sev="$(nm_sev suppression_reason)"
# Ruff codes of enabled rules: a `noqa` naming one in a comment needs a recorded reason.
nm_codes="$(awk '$1 == "sev" && $3 != "off" && $4 != "" { print $4 }' "$nm_tmp/resolved" | tr ',' ' ')"

# --- changed lines of the staged content -----------------------------------------------
nm_diff() {
  git -c core.quotePath=false -c diff.interHunkContext=0 diff -U0 --no-color --no-ext-diff \
    --no-textconv --text --src-prefix=a/ --dst-prefix=b/ -M --diff-filter=d "$@"
}
# nm_changes OUT DIFF-ARGS... : "path<TAB>line" records, plus "path<TAB>0" for every
# changed path (a pure rename has no +++ header but stays in scope for BLOCK rules).
nm_changes() {
  nm_out="$1"; shift
  nm_diff "$@" > "$nm_tmp/diff" || nm_tool_error git "git diff failed" git diff --cached "$@"
  nm_diff --name-only -z "$@" > "$nm_tmp/names" || nm_tool_error git "git diff --name-only failed" git diff --cached --name-only "$@"
  awk '
    function unq(s,   out, i, c, n, o) {
      if (substr(s, 1, 1) != "\"" || substr(s, length(s), 1) != "\"") return s
      s = substr(s, 2, length(s) - 2); out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < length(s)) {
          n = substr(s, i + 1, 1)
          if (n == "n") { out = out "\n"; i++; continue }
          if (n == "t") { out = out "\t"; i++; continue }
          if (n == "r") { out = out "\r"; i++; continue }
          if (n == "\"" || n == "\\") { out = out n; i++; continue }
          if (n == "a") { out = out "\007"; i++; continue }
          if (n == "b") { out = out "\b"; i++; continue }
          if (n == "f") { out = out "\f"; i++; continue }
          if (n == "v") { out = out "\v"; i++; continue }
          o = substr(s, i + 1, 3)
          if (o ~ /^[0-7][0-7][0-7]$/) {
            out = out sprintf("%c", (substr(o,1,1) * 64) + (substr(o,2,1) * 8) + substr(o,3,1)); i += 3; continue
          }
        }
        out = out c
      }
      return out
    }
    /^diff --git / { cur = ""; hdr = 1; next }
    hdr && /^\+\+\+ / {
      t = substr($0, 5); sub(/\t$/, "", t); t = unq(t)
      if (t == "/dev/null") { cur = ""; next }
      cur = (substr(t, 1, 2) == "b/") ? substr(t, 3) : t
      print cur "\t0"; next
    }
    /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
      hdr = 0
      if (cur == "") next
      h = $0; sub(/^@@ -[0-9]+(,[0-9]+)? \+/, "", h); sub(/ @@.*/, "", h)
      cnt = 1; c = index(h, ",")
      if (c) { start = substr(h, 1, c - 1) + 0; cnt = substr(h, c + 1) + 0 } else start = h + 0
      for (l = start; l < start + cnt; l++) print cur "\t" l
    }' "$nm_tmp/diff" > "$nm_out" || nm_tool_error awk "cannot parse the staged diff"
  tr '\000' '\n' < "$nm_tmp/names" | awk 'NF { print $0 "\t0" }' >> "$nm_out"
}

nm_merge_head="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)" || nm_tool_error git "cannot locate MERGE_HEAD" git rev-parse --git-path MERGE_HEAD
if [ -f "$nm_merge_head" ]; then
  nm_parents="$(tr -s ' \t\r' '\n\n\n' < "$nm_merge_head" | awk 'NF')" || nm_config_error "cannot read merge parent metadata"
  [ -n "$nm_parents" ] || nm_config_error "merge parent metadata contains no commits"
  nm_head="$(git rev-parse --verify -q 'HEAD^{commit}')" || nm_tool_error git "cannot resolve HEAD" git rev-parse HEAD
  nm_changes "$nm_tmp/changes" --cached "$nm_head"
  for nm_p in $nm_parents; do
    nm_pc="$(git rev-parse --verify -q "$nm_p^{commit}")" || nm_tool_error git "cannot resolve merge parent $nm_p" git rev-parse "$nm_p"
    nm_changes "$nm_tmp/changes-other" --cached "$nm_pc"
    # Keep a line only when it is new against this parent too; keep every path.
    awk -F'\t' 'FNR == NR { other[$0] = 1; if ($2 == 0) paths[$1] = 1; next }
                $2 == 0 || ($0 in other) { print; paths[$1] = 1 }
                END { for (p in paths) print p "\t0" }' \
      "$nm_tmp/changes-other" "$nm_tmp/changes" > "$nm_tmp/changes-merged"
    mv "$nm_tmp/changes-merged" "$nm_tmp/changes"
  done
else
  nm_changes "$nm_tmp/changes" --cached
fi

# --- scannable regular Rust files in the index -------------------------------------------
git ls-files -s -z > "$nm_tmp/ls" || nm_tool_error git "git ls-files failed" git ls-files -s -z
tr '\000' '\n' < "$nm_tmp/ls" | awk '
  { tab = index($0, "\t"); if (!tab) next
    split(substr($0, 1, tab - 1), m, " ")
    if (m[3] == "0" && (m[1] == "100644" || m[1] == "100755")) print m[2] "\t" substr($0, tab + 1) }' > "$nm_tmp/index"
awk -F'\t' '
  FILENAME == ARGV[1] { vend[++nv] = $0; next }
  FILENAME == ARGV[2] { oid[$2] = $1; next }
  { if (!($1 in oid) || ($1 !~ /\.rs$/) || done[$1]++) next
    n = split($1, parts, "/"); v = 0
    for (i = 1; i < n; i++) if (parts[i] ~ /^(vendor|_vendor|third_party|node_modules|\.venv|site-packages)$/ || parts[i] ~ /^external/) v = 1
    for (i = 1; i <= nv; i++) if ($1 == vend[i] || index($1, vend[i] "/") == 1) v = 1
    if (!v) print oid[$1] "\t" $1 }' "$nm_tmp/vendored" "$nm_tmp/index" "$nm_tmp/changes" | sort -t "$(printf '\t')" -k2 > "$nm_tmp/files"
[ -s "$nm_tmp/files" ] || exit 0

# --- export the staged blobs --------------------------------------------------------------
mkdir -p "$nm_tmp/tree"
while IFS="$(printf '\t')" read -r nm_oid nm_path; do
  mkdir -p "$nm_tmp/tree/$(dirname "$nm_path")"
  git cat-file blob "$nm_oid" > "$nm_tmp/tree/$nm_path" || nm_tool_error git "index file unavailable: '$nm_path'" git cat-file blob "$nm_oid"
  # A lone CR makes changed-line coordinates ambiguous (git and ast-grep count lines differently).
  if awk '{ sub(/\r$/, "") } index($0, "\r") { bad = 1; exit } END { exit !bad }' "$nm_tmp/tree/$nm_path"; then
    nm_tool_error git "lone CR line endings make changed-line coordinates ambiguous; convert to LF or CRLF before scanning" "$nm_path"
  fi
done < "$nm_tmp/files"
cut -f2 "$nm_tmp/files" > "$nm_tmp/paths"
nm_count="$(wc -l < "$nm_tmp/paths" | tr -d ' ')"

# --- rust_panic through ast-grep ------------------------------------------------------------
: > "$nm_tmp/findings"   # path<TAB>line<TAB>end<TAB>key<TAB>origin<TAB>message
nm_skipped=""
if [ "$nm_panic_sev" != "off" ]; then
  nm_sg=""
  if command -v ast-grep >/dev/null 2>&1; then
    nm_sg="$(command -v ast-grep)"
    nm_ver="$("$nm_sg" --version 2>"$nm_tmp/sg.err")"; nm_rc=$?
    case "$(printf '%s' "$nm_ver" | tr 'A-Z' 'a-z')" in
      *ast-grep*) [ "$nm_rc" -eq 0 ] || nm_tool_error ast-grep "version probe failed (exit $nm_rc, stdout '$nm_ver'). An installed ast-grep that cannot report its version cannot be trusted to scan." "$nm_sg" --version ;;
      *) nm_tool_error ast-grep "version probe failed (exit $nm_rc, stdout '$nm_ver'). An installed ast-grep that cannot report its version cannot be trusted to scan." "$nm_sg" --version ;;
    esac
  elif command -v sg >/dev/null 2>&1; then
    nm_c="$(command -v sg)"
    case "$("$nm_c" --version 2>/dev/null | tr 'A-Z' 'a-z')" in *ast-grep*) nm_sg="$nm_c" ;; esac
  fi
  if [ -z "$nm_sg" ]; then
    nm_skipped="rust_panic"
  else
    nm_ruledir="$(cd "$nm_rules/rust" 2>/dev/null && pwd -P)" || nm_tool_error ast-grep "mandate rule directory missing: $nm_rules/rust"
    grep -q '^id: mandate-rust-panic$' "$nm_ruledir/mandate-rust-panic.yml" 2>/dev/null ||
      nm_tool_error ast-grep "mandate rule inventory under $nm_rules does not match the RULES table (missing: mandate-rust-panic)"
    nm_ruledir_arg="$nm_ruledir"
    command -v cygpath >/dev/null 2>&1 && nm_ruledir_arg="$(cygpath -m "$nm_ruledir")"
    printf '# generated by mandate_native.sh\nruleDirs:\n  - %s\n' "$nm_ruledir_arg" > "$nm_tmp/sgconfig.yml"
    nm_cfg="$nm_tmp/sgconfig.yml"
    command -v cygpath >/dev/null 2>&1 && nm_cfg="$(cygpath -m "$nm_cfg")"
    # One argv per file list; xargs would split on whitespace, so pass the list directly.
    set --
    while IFS= read -r nm_path; do set -- "$@" "$nm_path"; done < "$nm_tmp/paths"
    ( cd "$nm_tmp/tree" && "$nm_sg" scan -c "$nm_cfg" --filter '^(mandate-rust-panic)$' --format github -- "$@" ) \
      > "$nm_tmp/sg.out" 2> "$nm_tmp/sg.err"
    nm_rc=$?
    [ "$nm_rc" -eq 0 ] || nm_tool_error ast-grep "exited $nm_rc; stderr: $(tail -n 12 "$nm_tmp/sg.err" | tr '\n' ' ')" "$nm_sg" scan --format github
    # ::warning file=<path>,line=<n>,endLine=<n>,title=<rule id>::<message>
    awk -v OFS='\t' '
      FILENAME == ARGV[1] { want[$0] = 1; next }
      /^[[:space:]]*$/ { next }
      {
        if (!match($0, /^::(warning|error|notice) file=/)) { bad = "unparseable ast-grep line " FNR; exit }
        rest = substr($0, RLENGTH + 1)
        if (!match(rest, /,line=[0-9]+,endLine=[0-9]+,title=[^:]*::/)) { bad = "unparseable ast-grep line " FNR; exit }
        file = substr(rest, 1, RSTART - 1); meta = substr(rest, RSTART + 1, RLENGTH - 3); msg = substr(rest, RSTART + RLENGTH)
        split(meta, kv, ","); line = substr(kv[1], 6) + 0; endl = substr(kv[2], 9) + 0; id = substr(kv[3], 7)
        gsub(/\\/, "/", file)
        # GitHub workflow-command escapes in the message.
        gsub(/%0A/, "\n", msg); gsub(/%0D/, "\r", msg); gsub(/%25/, "%", msg)
        if (!(file in want)) { bad = "ast-grep reported a file that was not scanned: " file; exit }
        if (id != "mandate-rust-panic") {
          if (id ~ /^mandate-/) { bad = "unknown mandate rule id " id; exit }
          next
        }
        print file, line, endl, "rust_panic", "ast-grep:" id, msg
      }
      END { if (bad != "") { print "error\t" bad > "/dev/stderr"; exit 3 } }' "$nm_tmp/paths" "$nm_tmp/sg.out" >> "$nm_tmp/findings" 2> "$nm_tmp/sg.parse"
    [ "$?" -eq 0 ] || nm_tool_error ast-grep "$(cut -f2 "$nm_tmp/sg.parse" | head -n 1)" "$nm_sg" scan --format github
  fi
fi

# --- comments, suppressions and the suppression_reason check ---------------------------
# Comment text per line: one-line "..." string literals are blanked, then the text from
# the first // on (mandate_scan.py marker_comments with RUST_STRING_RE).
while IFS= read -r nm_path; do
  awk -v p="$nm_path" -v OFS='\t' '
    { line = $0; sub(/\r$/, "", line); bare = ""
      i = 1; L = length(line)
      while (i <= L) {
        c = substr(line, i, 1)
        if (c == "\"") {
          j = i + 1; closed = 0
          while (j <= L) { d = substr(line, j, 1); if (d == "\\") { j += 2; continue } if (d == "\"") { closed = 1; break } j++ }
          if (closed) { for (k = i; k <= j; k++) bare = bare " "; i = j + 1; continue }
        }
        bare = bare c; i++
      }
      at = index(bare, "//")
      # A line counts as comment-only when it starts with # or // (mandate_scan.py suppressed()).
      s = line; sub(/^[ \t\f\v]+/, "", s)
      lead = (substr(s, 1, 1) == "#" || substr(s, 1, 2) == "//") ? 1 : 0
      if (at) print p, NR, substr(line, at), lead
    }' "$nm_tmp/tree/$nm_path"
done < "$nm_tmp/paths" > "$nm_tmp/comments"   # path<TAB>line<TAB>comment<TAB>comment-only

if [ "$nm_reason_sev" != "off" ]; then
  # Every mandate ast-grep id (the rule inventory; mandate_scan.py SG_TO_KEY).
  nm_sgids="$(grep -rh '^id:' "$nm_rules" 2>/dev/null | sed 's/^id:[[:space:]]*//; s/[[:space:]]*$//' | tr '\n' ' ')"
  [ -n "$nm_sgids" ] || nm_tool_error ast-grep "mandate rule directory missing: $nm_rules"
  awk -F'\t' -v OFS='\t' -v codes=" $nm_codes " -v sgids=" $nm_sgids " '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      c = $3; lc = tolower(c); problem = ""
      # NOQA_RE: #, optional ruff:/flake8:, noqa:, then codes (case-insensitive).
      named = ""
      if (match(lc, /#[ \t]*((ruff|flake8)[ \t]*:[ \t]*)?noqa[ \t]*:[ \t]*[a-z]+[0-9]+([ \t,]+[a-z]+[0-9]+)*/)) {
        seg = substr(c, RSTART, RLENGTH); sub(/^.*[Nn][Oo][Qq][Aa][ \t]*:[ \t]*/, "", seg)
        n = split(toupper(seg), cs, /[ \t,]+/)
        for (i = 1; i <= n; i++) if (cs[i] != "") named = named " " cs[i]
        named = named " "
      }
      guard = ""
      if (index(named, " PGH003 ") && index(codes, " PGH003 ")) guard = "PGH003"
      if (index(named, " PGH004 ") && index(codes, " PGH004 ")) guard = guard (guard == "" ? "" : ", ") "PGH004"
      if (guard != "") problem = "suppression checks cannot suppress themselves: " guard
      else if (c ~ /(#|\/\/)[ \t]*(SAFETY|best-effort)[ \t]*:[ \t]*[^ \t]/) problem = ""
      else {
        if (named != "") {
          hit = ""; m = split(trim(named), ns, " ")
          for (i = 1; i <= m; i++) if (index(codes, " " ns[i] " ") && !dup[NR, ns[i]]++) hits[++h] = ns[i]
          if (h) {
            # sorted, comma-joined
            for (i = 1; i <= h; i++) for (j = i + 1; j <= h; j++) if (hits[j] < hits[i]) { t = hits[i]; hits[i] = hits[j]; hits[j] = t }
            for (i = 1; i <= h; i++) hit = hit (i > 1 ? ", " : "") hits[i]
            problem = "`# noqa: " hit "` suppresses a mandate rule with no reason"
          }
          h = 0
        }
        if (problem == "" && match(c, /ast-grep-ignore/)) {
          rest = substr(c, RSTART + RLENGTH)
          if (rest ~ /^[ \t]*:[ \t]*[A-Za-z0-9_-]+/) {
            sub(/^[ \t]*:[ \t]*/, "", rest)
            ids = ""; while (match(rest, /^[A-Za-z0-9_-]+/)) { ids = ids " " substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1); if (!match(rest, /^[ \t]*,[ \t]*/)) break; rest = substr(rest, RLENGTH + 1) }
            hit = ""; m = split(trim(ids), is, " ")
            for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (is[j] < is[i]) { t = is[i]; is[i] = is[j]; is[j] = t }
            for (i = 1; i <= m; i++) if (index(sgids, " " is[i] " ") && !((NR, is[i]) in seenid)) { seenid[NR, is[i]] = 1; hit = hit (hit == "" ? "" : ", ") is[i] }
            if (hit != "") problem = "`ast-grep-ignore: " hit "` suppresses a mandate rule with no reason"
          } else problem = "blanket `ast-grep-ignore` suppresses every mandate rule with no reason"
        }
      }
      if (problem != "") print $1, $2, $2, "suppression_reason", "text", problem
    }' "$nm_tmp/comments" >> "$nm_tmp/findings" || nm_tool_error awk "cannot read suppression comments"
fi

# --- postprocess: test paths, suppressions, de-duplication; then severities --------------
sort -t "$(printf '\t')" -k1,1 -k2,2n -k4,4 -k5,5 "$nm_tmp/findings" | awk -F'\t' -v OFS='\t' \
  -v psev="$nm_panic_sev" -v rsev="$nm_reason_sev" '
  FILENAME == ARGV[1] { if ($2 != 0) chg[$1, $2] = 1; next }
  FILENAME == ARGV[2] { com[$1, $2] = $3; only[$1, $2] = $4; next }
  {
    path = $1; line = $2 + 0; endl = $3 + 0; key = $4
    if (key == "rust_panic") {
      n = split(path, parts, "/"); name = parts[n]; t = 0
      for (i = 1; i < n; i++) if (parts[i] == "tests" || parts[i] == "benches" || parts[i] == "examples") t = 1
      if (name ~ /_test\.rs$/ || name == "tests.rs" || name == "build.rs") t = 1
      if (t) next
      # ast-grep-ignore, bare or naming the rule, on the line or a comment-only line above.
      sup = 0
      for (w = 0; w <= 1 && !sup; w++) {
        ln = line - w; if (w == 1 && !((path, ln) in only && only[path, ln] == 1)) continue
        if (!((path, ln) in com)) continue
        s = com[path, ln]
        while (match(s, /ast-grep-ignore/)) {
          rest = substr(s, RSTART + RLENGTH); s = rest
          if (rest ~ /^[ \t]*:[ \t]*[A-Za-z0-9_-]+/) {
            sub(/^[ \t]*:[ \t]*/, "", rest)
            while (match(rest, /^[A-Za-z0-9_-]+/)) {
              if (substr(rest, 1, RLENGTH) == "mandate-rust-panic") sup = 1
              rest = substr(rest, RLENGTH + 1); if (!match(rest, /^[ \t]*,[ \t]*/)) break; rest = substr(rest, RLENGTH + 1)
            }
          } else sup = 1
        }
      }
      if (sup) next
      sev = psev
    } else sev = rsev
    if (seen[key, path, line]++) next
    on = 0; for (l = line; l <= endl; l++) if ((path, l) in chg) on = 1
    if (sev == "block" || (sev == "changed" && on)) print "BLOCK", $0
    else if (sev == "warn" && on) print "WARN", $0
  }' "$nm_tmp/changes" "$nm_tmp/comments" - > "$nm_tmp/verdicts" || nm_tool_error awk "cannot classify findings"

# --- report -----------------------------------------------------------------------------------
nm_print() {
  NM_TREE="$nm_tmp/tree" awk -F'\t' -v want="$1" '
    $1 != want { next }
    {
      verdict = $1; path = $2; line = $3; key = $5; origin = $6; msg = $7
      text = ""; f = ENVIRON["NM_TREE"] "/" path; n = 0
      while ((getline l < f) > 0) { if (++n == line) { text = l; break } }
      close(f); sub(/\r$/, "", text); gsub(/^[ \t]+|[ \t]+$/, "", text)
      if (key == "rust_panic") {
        policy = "RS-01"
        why = "unwrap/expect/panic!/todo!/unimplemented! abort the process instead of returning an error the caller can handle. [clarius CLAUDE.md:57; vigil-audio AGENTS.md:31-38; agent-hub CLAUDE.md:253]"
        fix = "Return a typed error (`ok_or(Error::...)?`, `map_err(...)?`)."
        id = origin; sub(/^ast-grep:/, "", id)
        debt = "append `  // ast-grep-ignore: " id "  // SAFETY: <why this is correct>` to line " line "."
      } else {
        policy = "PY-09"
        why = WHY_REASON
        fix = FIX_REASON
        debt = "a suppression cannot itself be suppressed; add the code / reason as shown."
      }
      printf "git-guard mandate %s [%s] %s %s:%s (%s)\n", verdict, key, policy, path, line, origin
      printf "    >> %s\n    what: %s\n    why:  %s\n    fix:  %s\n    debt: %s\n", text, msg, why, fix, debt
    }' WHY_REASON="$NM_WHY_REASON" FIX_REASON="$NM_FIX_REASON" "$nm_tmp/verdicts" >&2
}
# suppression_reason's why/source/fix, as in mandate_scan.py RULES.
NM_WHY_REASON="A suppression of a mandate rule with no recorded reason is unreviewable debt. [vigil-ai-tpm RULES.md:83-86; vigil-ai-tpm pyproject.toml:80-87]"
NM_FIX_REASON="Add the reason on the same line: \`# noqa: CODE  # SAFETY: <why this is correct>\` (or \`# best-effort: <why>\`)."
nm_print WARN
nm_print BLOCK
[ -n "$nm_skipped" ] && nm_say "git-guard mandate WARN: ast-grep is not installed, so these rules were NOT evaluated: $nm_skipped. Install: npm install -g @ast-grep/cli"

nm_end="$(date +%s 2>/dev/null || echo 0)"
nm_scope="$nm_count file(s), $((nm_end - nm_start)).0s, policy: $nm_source"
nm_blocks="$(awk -F'\t' '$1 == "BLOCK"' "$nm_tmp/verdicts" | wc -l | tr -d ' ')"
if [ "$nm_blocks" -gt 0 ]; then
  nm_keys="$(awk -F'\t' '$1 == "BLOCK" { n[$5]++ } END { for (k in n) print k " (" n[k] ")" }' "$nm_tmp/verdicts" | sort | awk '{ s = s (NR > 1 ? ", " : "") $0 } END { print s }')"
  nm_say "git-guard mandate: BLOCKED — $nm_blocks finding(s) on $nm_scope: $nm_keys. Fix each as shown, or record justified debt on the line with the noqa / ast-grep-ignore form plus \`SAFETY: <reason>\`."
  exit 1
fi
nm_warns="$(awk -F'\t' '$1 == "WARN"' "$nm_tmp/verdicts" | wc -l | tr -d ' ')"
nm_note=""; [ "$nm_warns" -gt 0 ] && nm_note=", $nm_warns warning(s)"
nm_tail=""; [ -n "$nm_skipped" ] && nm_tail="; 1 rule(s) NOT evaluated (see WARN above)"
nm_say "git-guard mandate: PASSED — 0 blocking findings on $nm_scope$nm_note$nm_tail."
exit 0
