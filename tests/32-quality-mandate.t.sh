#!/bin/sh
# Category 32 — the owner's quality mandate (hooks/common/mandate_scan.sh).
#
# Behaviour protected:
#   * --staged blocks a mandate finding on a line the commit adds or modifies,
#     and lets pre-existing debt in the same file through untouched; the line
#     mapping is exact at the first line of a file (ast-grep ranges are 0-based,
#     git and ruff are 1-based).
#   * pydantic v1, explicit Any, silent excepts, Rust panics block; test files
#     are exempt from the no-Any / silent-failure / panic rules but NOT from the
#     pydantic rule; vendored trees are exempt entirely.
#   * a mandate suppression needs a recorded reason (`SAFETY:`); with one, the
#     suppressed finding passes.
#   * per-rule `mandate.<rule>=off|warn|changed|block` takes effect, and an
#     unknown value is a TOOL ERROR, not a default.
#   * the debt register (.git-guard/mandate-baseline.json) blocks MALFORMED,
#     REGRESSION, UNRATCHETED, UNDECLARED and STALE, passes when it holds, and is
#     wired into hooks/pre-push only for commits that carry it.
#   * a scanner that exits 2 or prints unparseable output is a TOOL ERROR that
#     blocks, and so is an installed `ast-grep` whose version probe fails; a
#     scanner that is not installed (or a util-linux `sg`) is a WARN naming the
#     unevaluated rules (the anti-brick rule).
#   * repository policy (.qa-gate.conf) is read from the snapshot being checked:
#     the index at pre-commit, each pushed commit at pre-push.
#   * qa_gate.sh calls the scanner at pre-commit; QA_KNOWN_KEYS, the
#     qa-gate.conf defaults and the scanner's RULES table name the same keys.
#
# What a failure means: a mandate rule that cannot fail (a gate that reports
# clean on the code it exists to refuse), a rule that blocks old debt and so
# bricks every edit to a legacy file, a tool failure read as "no findings", or
# a ratchet that silently lets the backlog grow.
#
# Requirement: owner quality mandate 2026-10-14 (docs/QA_TOOLING.md "Quality
# mandate"); dtm-claude docs/reference/DOCUMENTATION_AND_TEST_STANDARD.md §1
# (every rule ships with an input that must fail and one that must pass).
# Needs ruff and a genuine ast-grep; each part self-SKIPs naming the missing
# tool. Fixtures are generated in the suite temp root at run time.
# shellcheck shell=sh

_QM_SCAN="$GG_ROOT/hooks/common/mandate_scan.sh"

# Restricted PATH fixtures must launch the original executable in its original
# runtime layout. MSYS ln may copy executables, losing adjacent DLLs; native
# Python subprocesses also cannot execute an extensionless shell payload.
# Protects: absence/error controls reach the intended guard, not a loader error.
# Needs: the original shell, cygpath on native Windows, and allowlisted tools only.
_QM_SHELL="$(command -v sh)"
# A native mktemp may return C:/...; drive colons are not MSYS PATH separators.
_qm_path_dir() {
  if gg_is_windows; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}
_qm_forward() {
  _qm_dest="$1"; _qm_real="$2"
  if gg_is_windows; then
    _qm_posix="$(cygpath -u "$_qm_real")"
    _qm_quote="$(printf '%s' "$_qm_posix" | sed "s/'/'\\\\''/g")"
    printf '#!/bin/sh\nexec '\''%s'\'' "$@"\n' "$_qm_quote" > "$_qm_dest"
    _qm_native="$(cygpath -m "$_qm_real" | sed 's/%/%%/g')"
    printf '@"%s" %%*\r\n' "$_qm_native" > "$_qm_dest.cmd"
    chmod +x "$_qm_dest"
  else
    ln -sf "$_qm_real" "$_qm_dest"
  fi
}

# Preserve the real injected shell payload on every host. A paired CMD adapter
# lets native Windows Python launch it through the original absolute shell.
_qm_payload() {
  printf '%b' "$2" > "$1"
  chmod +x "$1"
  if gg_is_windows; then
    _qm_cmd_shell="$(cygpath -m "$_QM_SHELL" | sed 's/%/%%/g')"
    _qm_cmd_payload="$(cygpath -m "$1" | sed 's/%/%%/g')"
    printf '@"%s" "%s" %%*\r\n' "$_qm_cmd_shell" "$_qm_cmd_payload" > "$1.cmd"
  fi
}

_qm_min_bin() {
  _qm_target_bin="$1"; shift
  mkdir -p "$_qm_target_bin"
  for _qm_tool in "$@"; do
    _qm_original="$(command -v "$_qm_tool" 2>/dev/null)" &&
      _qm_forward "$_qm_target_bin/$_qm_tool" "$_qm_original"
  done
  if gg_is_windows; then
    # Bare Git and policy-shell subprocesses use CreateProcess, which does not
    # search PATHEXT for CMD adapters. Admit their genuine PEs and runtime DLLs
    # only, never either tool directory. No conflicting DLL may be overwritten.
    _qm_git_runtime="$(cygpath -u "$(git --exec-path)")/../../bin"
    _qm_sh_runtime="/usr/bin"
    # A git.exe copied into a flat directory cannot derive its runtime prefix
    # and falls back to the build machine's, reading D:/git-sdk-64/etc/gitconfig.
    # Where D: is a removable drive with no media (dtm-p1gen7's card reader)
    # that read fails with EACCES, which Git treats as fatal, so every
    # restricted run became "TOOL ERROR [git]: exit 128". Hand the copy the
    # system config the real git reads (none if it reads none).
    _qm_sysconf="$(git config --system --list --show-origin 2>/dev/null |
      awk -F '\t' 'NR == 1 { sub(/^file:/, "", $1); print $1 }')"
    if [ -n "$_qm_sysconf" ]; then GIT_CONFIG_SYSTEM="$_qm_sysconf"; export GIT_CONFIG_SYSTEM
    else GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_NOSYSTEM; fi
    "$(gg_python)" -I -c '
import hashlib, json, pathlib, shutil, sys
git_source, sh_source, target = map(pathlib.Path, sys.argv[1:4])
files = [git_source / "git.exe", sh_source / "sh.exe",
         *sorted(git_source.glob("*.dll")), *sorted(sh_source.glob("*.dll"))]
# Present Rust tools need their real PE too: CMD would reparse regex pipes.
expected_exes = ["git.exe", "sh.exe"]
for tool in ("ast-grep", "ruff"):
    if tool in sys.argv[4:]:
        resolved = shutil.which(tool)
        assert resolved, tool
        original = pathlib.Path(resolved)
        assert original.suffix.lower() == ".exe", original
        assert original.read_bytes()[:2] == b"MZ", original
        files.append(original)
        expected_exes.append(tool + ".exe")
manifest = {}
for original in files:
    before = hashlib.sha256(original.read_bytes()).hexdigest()
    key = original.name.lower()
    assert manifest.get(key, before) == before, original.name
    destination = target / key
    if destination.exists():
        assert hashlib.sha256(destination.read_bytes()).hexdigest() == before, key
    else:
        shutil.copyfile(original, destination)
    after = hashlib.sha256(destination.read_bytes()).hexdigest()
    assert before == after, key
    manifest[key] = before
assert sorted(p.name.lower() for p in target.glob("*.exe")) == sorted(expected_exes)
print(json.dumps({"git_source_sha256": manifest["git.exe"],
                  "git_copy_sha256": manifest["git.exe"],
                  "sh_source_sha256": manifest["sh.exe"],
                  "sh_copy_sha256": manifest["sh.exe"],
                  "dlls_verified": sum(name.lower().endswith(".dll") for name in manifest),
                  "runtime_manifest_sha256": hashlib.sha256(
                      json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
                  "present_tool_sha256": {name: manifest[name] for name in expected_exes},
                  "only_native_executables": sorted(expected_exes)}))
' "$(cygpath -m "$_qm_git_runtime")" "$(cygpath -m "$_qm_sh_runtime")" "$(cygpath -m "$_qm_target_bin")" "$@"
    rc=$?
    t_expect_rc 0 "$rc" "restricted runtimes match trusted hashes and admit only the declared EXE set"
  fi
}

# _qm_repo — a fresh fixture repo (path on stdout).
_qm_repo() { gg_mktemp_repo; }

# _qm_put REPO PATH CONTENT — write CONTENT (printf %b) to REPO/PATH and stage it.
_qm_put() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%b' "$3" > "$1/$2"
  ( cd "$1" && git add -- "$2" )
}

# _qm_commit REPO MSG — record fixture history. core.hooksPath points at an
# empty directory so the machine's installed hooks (a global core.hooksPath)
# cannot judge fixture setup commits; the code under test is run explicitly.
_qm_commit() {
  mkdir -p "$GG_T_TMPROOT/qm-no-hooks"
  ( cd "$1" && git add -A && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit -q -m "$2" )
}

# _qm_conf REPO TEXT — write TEXT (printf %b) as the repo's .qa-gate.conf and
# STAGE it: the scanner reads policy from the snapshot it scans (the index at
# pre-commit), so an unstaged conf deliberately has no effect.
_qm_conf() {
  printf '%b' "$2" > "$1/.qa-gate.conf"
  ( cd "$1" && git add .qa-gate.conf )
}

# _qm_scan REPO LOG ARGS... — run the scanner in REPO, stderr to LOG.
_qm_scan() {
  _qm_r="$1"; _qm_l="$2"; shift 2
  ( cd "$_qm_r" && sh "$_QM_SCAN" "$@" ) >/dev/null 2>"$_qm_l"
}

# _qm_push REPO LOG — run hooks/pre-push for the ref list in $GG_T_TMPROOT/qm-refs.
# The downstream chain is pinned to a no-op so an installed lefthook cannot
# change the result.
_qm_push() {
  printf '#!/bin/sh\nexit 0\n' > "$GG_T_TMPROOT/qm-noop-downstream"
  chmod +x "$GG_T_TMPROOT/qm-noop-downstream"
  ( cd "$1" && GIT_GUARD_DOWNSTREAM_PRE_PUSH="$GG_T_TMPROOT/qm-noop-downstream" \
      sh "$GG_ROOT/hooks/pre-push" origin git@example ) <"$GG_T_TMPROOT/qm-refs" >"$2" 2>&1
}

# _qm_has LOG TEXT MSG — assert LOG contains TEXT (fixed string).
_qm_has() {
  if grep -qF -- "$2" "$1"; then t_ok "$3"; else
    t_fail "$3 (expected '$2' in output)"; sed 's/^/           /' "$1" | head -20 >&2
  fi
}

# _qm_lacks LOG TEXT MSG — assert LOG does not contain TEXT.
_qm_lacks() {
  if grep -qF -- "$2" "$1"; then
    t_fail "$3 (unexpected '$2' in output)"; sed 's/^/           /' "$1" | head -20 >&2
  else t_ok "$3"; fi
}

# _qm_swallow — a new except-pass handler (except_pass + blind_except).
_QM_SWALLOW='def probe():\n    try:\n        connect()\n    except Exception:\n        pass\n'
# _qm_narrow_swallow — narrow except-pass (except_pass only, no BLE001).
_QM_NARROW='def probe():\n    try:\n        connect()\n    except OSError:\n        pass\n'
_QM_CLEAN='\n\ndef added(value: int) -> int:\n    return value + 1\n'

# Protects: proven Pydantic receivers still block, plain APIs clear, unknowns warn.
# Detects: treating every parse_file name as Pydantic, or disabling true positives.
# Needs: real ast-grep and ruff; owned staged Git fixtures, no imported code execution.
# Breadcrumb: hooks/common/mandate_scan.py; mandate/python/mandate-pydantic-v1*.yml.
_qm_receiver_case() {
  _qmr_label="$1"; _qmr_code="$2"; _qmr_rc="$3"; _qmr_kind="$4"
  _qmr_repo="$(_qm_repo)"; _qmr_log="$GG_T_TMPROOT/receiver.log"
  _qm_put "$_qmr_repo" src/model.py "$_qmr_code"
  [ "$#" -lt 5 ] || _qm_conf "$_qmr_repo" "$5"
  _qm_scan "$_qmr_repo" "$_qmr_log" --staged; _qmr_actual=$?
  t_expect_rc "$_qmr_rc" "$_qmr_actual" "receiver: $_qmr_label"
  case "$_qmr_kind" in
    model) _qm_has "$_qmr_log" '[pydantic_v1]' "$_qmr_label names proven model rule" ;;
    unknown)
      _qm_has "$_qmr_log" '[pydantic_v1_ambiguous]' "$_qmr_label reports unresolved receiver"
      _qm_lacks "$_qmr_log" '[pydantic_v1]' "$_qmr_label never claims a proven model" ;;
    plain)
      _qm_lacks "$_qmr_log" '[pydantic_v1]' "$_qmr_label is not a model"
      _qm_lacks "$_qmr_log" '[pydantic_v1_ambiguous]' "$_qmr_label is proven plain" ;;
  esac
  gg_rmrepo "$_qmr_repo"
}

_qm_receiver_models() {
  _qmr_model='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\n'
  _qm_receiver_case 'model class' "${_qmr_model}Model.parse_file('m.json')\n" 1 model
  for _qmr_method in parse_obj parse_raw from_orm; do
    _qm_receiver_case "model $_qmr_method" "${_qmr_model}Model.${_qmr_method}('payload')\n" 1 model
  done
  _qm_receiver_case 'class and base aliases' \
    'from pydantic import BaseModel as BM\nclass M(BM):\n    pass\nAlias = M\nAlias.parse_file("m.json")\n' 1 model
  _qm_receiver_case 'module alias and constructed instance' \
    'import pydantic as pd\nclass M(pd.BaseModel):\n    pass\nm = M()\nm.parse_file("m.json")\n' 1 model
  _qm_receiver_case 'model parameter annotation' \
    "${_qmr_model}def probe(model: Model):\n    return model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'BaseSettings import and subclass' \
    'from pydantic_settings import BaseSettings\nclass Settings(BaseSettings):\n    pass\nSettings.parse_file("m.json")\n' 1 model
  _qm_receiver_case 'ambiguous off retains proven block' \
    "${_qmr_model}Model.parse_file('m.json')\n" 1 model 'mandate.pydantic_v1_ambiguous=off\n'
  _qm_receiver_case 'v1 namespace unchanged' 'from pydantic.v1 import BaseModel\n' 1 model
  _qm_receiver_case 'v1 decorator unchanged' \
    'from pydantic import validator\n@validator("value")\ndef clean(value):\n    return value\n' 1 model
  _qm_receiver_case 'v1 Config unchanged' \
    'from pydantic import BaseModel\nclass M(BaseModel):\n    class Config:\n        extra = "forbid"\n' 1 model
  _qm_receiver_case 'Config remains strong with unresolved method inside' \
    'from pydantic import BaseModel\nclass M(BaseModel):\n    class Config:\n        setting = external.parse_file("m.json")\n' 1 model
}

_qm_receiver_plain_and_unknown() {
  _qmr_plain='class MarkdownParser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'plain Markdown parser' \
    "${_qmr_plain}parser = MarkdownParser()\nparser.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'model name rebound to plain class' \
    "from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\n${_qmr_plain}Model = MarkdownParser\nModel.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'unannotated parameter shadows class' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\ndef probe(Model):\n    return Model.parse_file("notes.md")\n' 0 unknown
  _qm_receiver_case 'plain annotation shadows model name' \
    "from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\n${_qmr_plain}def probe(Model: MarkdownParser):\n    return Model.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'cross-file receiver unresolved' \
    'from external_models import Model\nModel.parse_file("notes.md")\n' 0 unknown
  _qm_receiver_case 'relative pydantic-named module is unresolved' \
    'from .pydantic import BaseModel\nBaseModel.parse_file("notes.md")\n' 0 unknown
  _qm_receiver_case 'unknown factory receiver' 'factory().parse_file("notes.md")\n' 0 unknown
  _qm_receiver_case 'conditional receiver merge unresolved' \
    "from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\n${_qmr_plain}parser = Model()\nif choice:\n    parser = MarkdownParser()\nparser.parse_file('notes.md')\n" 0 unknown
  _qm_receiver_case 'function globals rebound later are unresolved' \
    "from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\n${_qmr_plain}def probe():\n    return Model.parse_file('notes.md')\nModel = MarkdownParser\n" 0 unknown
  _qm_receiver_case 'comprehension receiver shadows global class' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nresults = [Model.parse_file("m.json") for Model in parsers]\n' 0 unknown
  _qm_receiver_case 'dynamic method decorator is unresolved' \
    'class MarkdownParser:\n    @decorate\n    def parse_file(self, path):\n        return path\nparser = MarkdownParser()\nparser.parse_file("m.json")\n' 0 unknown
  _qm_receiver_case 'decorated custom constructor is unresolved' \
    'class Parser:\n    @decorate\n    def __new__(cls):\n        return factory()\n    def parse_file(self, path):\n        return path\nParser().parse_file("m.json")\n' 0 unknown
  _qm_receiver_case 'custom attribute dispatch is unresolved' \
    'class Parser:\n    def __getattribute__(self, name):\n        return factory()\n    def parse_file(self, path):\n        return path\nParser().parse_file("m.json")\n' 0 unknown
}

# Protects: plain receiver certainty expires after explicit method mutation.
# Detects: aliases/deferred functions or shadowed decorators hiding model calls.
# Needs: real scanner/exported Git source; fixture classes are never imported.
# Breadcrumb: hooks/common/mandate_scan.py PydanticReceivers assignment/scope handling.
_qm_receiver_attribute_mutations() {
  _qmr_classes='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls, path):\n        return path\n'
  _qm_receiver_case 'class method rebind loses plain proof' \
    "${_qmr_classes}Parser.parse_file = Model.parse_file\nParser.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'instance method rebind loses plain proof' \
    "${_qmr_classes}parser = Parser()\nparser.parse_file = Model.parse_file\nparser.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'alias method rebind invalidates original receiver' \
    "${_qmr_classes}Alias = Parser\nAlias.parse_file = Model.parse_file\nParser.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'deferred function sees later class mutation' \
    "${_qmr_classes}def probe():\n    return Parser.parse_file('m.json')\nParser.parse_file = Model.parse_file\n" 0 unknown
  _qm_receiver_case 'deferred function sees later alias mutation' \
    "${_qmr_classes}def probe():\n    return Parser.parse_file('m.json')\nAlias = Parser\nAlias.parse_file = Model.parse_file\n" 0 unknown
  _qm_receiver_case 'unrelated parser mutation retains known model block' \
    "${_qmr_classes}Parser.parse_file = external\nModel.parse_file('m.json')\n" 1 model
  for _qmr_decorator in classmethod staticmethod; do
    _qm_receiver_case "builtin $_qmr_decorator stays plain" \
      "class Parser:\n    @${_qmr_decorator}\n    def parse_file(path):\n        return path\nParser().parse_file('notes.md')\n" 0 plain
    _qm_receiver_case "shadowed $_qmr_decorator is not a builtin proof" \
      "def ${_qmr_decorator}(method):\n    return factory()\nclass Parser:\n    @${_qmr_decorator}\n    def parse_file(path):\n        return path\nParser().parse_file('m.json')\n" 0 unknown
  done
  _qm_receiver_case 'deferred class method sees later mutation' \
    "${_qmr_classes}    @classmethod\n    def probe(cls):\n        return cls.parse_file('m.json')\nParser.parse_file = Model.parse_file\n" 0 unknown
}

# Protects: ordinary configuration/data writes cannot weaken model enforcement.
# Detects: conflating stable model type, plain method proof and type replacement.
# Needs: real scanner on staged source; no execution of fixture model constructors.
# Breadcrumb: hooks/common/mandate_scan.py receiver mutation classification.
_qm_receiver_data_members() {
  _qmr_model='from pydantic import BaseModel\nclass Model(BaseModel):\n    count: int = 0\n'
  _qm_receiver_case 'model config write retains model block' \
    "${_qmr_model}Model.model_config = {}\nModel.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'model class data write retains model block' \
    "${_qmr_model}Model.label = 'ready'\nModel.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'model instance data write retains model block' \
    "${_qmr_model}model = Model()\nmodel.count = 1\nmodel.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'model initialization retains self type' \
    "${_qmr_model}    def __init__(self):\n        super().__init__()\n        self.count = 1\n        self.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'plain field write retains declared method proof' \
    'class Parser:\n    def parse_file(self, path):\n        return path\n    def probe(self, path):\n        self.path = path\n        return self.parse_file(path)\n' 0 plain
  _qm_receiver_case 'explicit model base change remains unresolved' \
    "${_qmr_model}Model.__bases__ = external_bases\nModel.parse_file('m.json')\n" 0 unknown
}

# Protects: the trusted settings namespace retains known BaseSettings enforcement.
# Detects: module aliases losing type evidence or modules becoming plain receivers.
# Needs: real staged scanner; no import or execution of fixture framework code.
# Breadcrumb: hooks/common/mandate_scan.py import/value namespace handling.
_qm_receiver_settings_namespace() {
  _qm_receiver_case 'settings module alias retains model block' \
    'import pydantic_settings as settings\nclass Settings(settings.BaseSettings):\n    pass\nSettings.parse_file("m.json")\n' 1 model
  _qm_receiver_case 'settings module constructor retains model block' \
    'import pydantic_settings\nclass Settings(pydantic_settings.BaseSettings):\n    pass\nSettings().parse_file("m.json")\n' 1 model
  _qm_receiver_case 'settings module itself remains unresolved' \
    'import pydantic_settings as settings\nsettings.parse_file("m.json")\n' 0 unknown
}

# Protects: expression/deferred/control contexts cannot silently clear model calls.
# Detects: missed target/default execution, conditional binds and stale methods.
# Needs: actual staged scanner, UTF-8 BOM bytes and owned Git fixtures only.
# Breadcrumb: hooks/common/mandate_scan.py receiver visitors and UTF-8 decoding.
_qm_receiver_review_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    id: int = 1\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  for _qmr_operator in and or; do
    _qm_receiver_case "$_qmr_operator walrus merges receiver paths" \
      "${_qmr_types}receiver = Model\ncondition ${_qmr_operator} (receiver := Parser())\nreceiver.parse_file('m.json')\n" 0 unknown
  done
  _qm_receiver_case 'conditional expression merges receiver paths' \
    "${_qmr_types}receiver = Model\n(receiver := Parser()) if condition else None\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'comprehension walrus cannot retain outer plain proof' \
    "${_qmr_types}receiver = Parser()\n[(receiver := Model) for item in items]\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'comprehension stable model binding remains strong' \
    "${_qmr_types}receiver = Model\n[(receiver := Model) for item in items]\nreceiver.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'lambda capture observes later name rebound' \
    "${_qmr_types}receiver = Parser()\nload = lambda: receiver.parse_file('m.json')\nreceiver = Model\n" 0 unknown
  _qm_receiver_case 'lambda capture observes later method replacement' \
    "${_qmr_types}load = lambda: Parser.parse_file('m.json')\nParser.parse_file = Model.parse_file\n" 0 unknown
  _qm_receiver_case 'lambda default executes known model call' \
    "${_qmr_types}load = lambda value=Model.parse_file('m.json'): value\n" 1 model
  _qm_receiver_case 'lambda local binding does not weaken global model' \
    "${_qmr_types}load = lambda: (Model := Parser())\ndef probe():\n    return Model.parse_file('m.json')\n" 1 model
  for _qmr_target in 'cache[Model.parse_obj(payload).id] = 1' 'cache[Model.parse_obj(payload).id]: int = 1' 'cache[Model.parse_obj(payload).id] += 1' 'del cache[Model.parse_obj(payload).id]'; do
    _qm_receiver_case "executable target $_qmr_target" \
      "${_qmr_types}cache = {}\npayload = {'id': 1}\n${_qmr_target}\n" 1 model
  done
  _qm_receiver_case 'loop mutation cannot retain plain method proof' \
    "${_qmr_types}for item in range(1):\n    Parser.parse_file = Model.parse_file\nParser.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'with mutation cannot retain plain method proof' \
    "${_qmr_types}with manager:\n    Parser.parse_file = Model.parse_file\nParser.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'known model loop header remains strong before base write' \
    "${_qmr_types}for item in Model.parse_obj({'id': 1}):\n    Model.__bases__ = external_bases\n" 1 model
  _qm_receiver_case 'class body replacement removes declared method proof' \
    "${_qmr_types}class Changed:\n    def parse_file(self, path):\n        return path\n    parse_file = Model.parse_file\nChanged().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'class body replacement removes inherited method proof' \
    "${_qmr_types}class Changed(Parser):\n    parse_file = Model.parse_file\nChanged().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'class local decorator shadow cannot establish plain proof' \
    "${_qmr_types}class Changed:\n    classmethod = lambda method: Model.parse_file\n    @classmethod\n    def parse_file(path):\n        return path\nChanged().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'class body constructor replacement cannot establish type' \
    "${_qmr_types}class Changed:\n    __new__ = lambda cls: Model()\n    def parse_file(self, path):\n        return path\nChanged().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'BOM encoded model retains strong finding' \
    '\0357\0273\0277from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nModel.parse_file("m.json")\n' 1 model
}

_qm_receiver_modes() {
  _qmr_repo="$(_qm_repo)"; _qmr_log="$GG_T_TMPROOT/receiver-modes.log"
  _qm_put "$_qmr_repo" src/model.py 'marker = 1\n'
  _qm_commit "$_qmr_repo" 'receiver baseline'
  _qmr_base="$(git -C "$_qmr_repo" rev-parse HEAD)"
  _qm_put "$_qmr_repo" src/model.py 'from external_models import Model\nModel.parse_file("m.json")\n'
  _qm_scan "$_qmr_repo" "$_qmr_log" --staged; _qmr_rc=$?
  t_expect_rc 0 "$_qmr_rc" 'unresolved staged receiver warns without blocking'
  _qm_has "$_qmr_log" '[pydantic_v1_ambiguous]' 'staged receiver ambiguity is explicit'
  _qm_commit "$_qmr_repo" 'unresolved receiver'
  _qm_scan "$_qmr_repo" "$_qmr_log" --range "$_qmr_base..HEAD"; _qmr_rc=$?
  t_expect_rc 0 "$_qmr_rc" 'range classification matches staged result'
  _qm_has "$_qmr_log" '[pydantic_v1_ambiguous]' 'range receiver ambiguity is explicit'
  ( cd "$_qmr_repo" && sh "$_QM_SCAN" --all ) >"$GG_T_TMPROOT/receiver-census.json" 2>"$_qmr_log"
  t_expect_rc 0 "$?" 'receiver census executes successfully'
  _qm_has "$GG_T_TMPROOT/receiver-census.json" '"pydantic_v1": 0' 'census has no false proven-model count'
  _qm_has "$GG_T_TMPROOT/receiver-census.json" '"pydantic_v1_ambiguous": 1' 'census retains unresolved count'
  gg_rmrepo "$_qmr_repo"
}

# Protects: receiver evidence follows the selected Git snapshot, not unstaged bytes.
# Detects: model/plain divergence being classified from the wrong source tree.
# Needs: real staged Git blobs, commits and scanner; no imported fixture execution.
# Breadcrumb: hooks/common/mandate_scan.py export_index/export_rev/census.
_qm_receiver_snapshot_case() {
  _qms_repo="$(_qm_repo)"; _qms_log="$GG_T_TMPROOT/receiver-snapshot.log"
  _qms_model='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nModel.parse_file("m.json")\n'
  _qms_plain='class Parser:\n    def parse_file(self, path):\n        return path\nParser().parse_file("notes.md")\n'
  case "$1" in
    model) _qms_chosen="$_qms_model"; _qms_other="$_qms_plain"; _qms_rc=1; _qms_count=1 ;;
    plain) _qms_chosen="$_qms_plain"; _qms_other="$_qms_model"; _qms_rc=0; _qms_count=0 ;;
  esac
  _qm_put "$_qms_repo" src/model.py 'marker = 1\n'
  _qm_commit "$_qms_repo" 'snapshot base'
  _qms_base="$(git -C "$_qms_repo" rev-parse HEAD)"
  _qm_put "$_qms_repo" src/model.py "$_qms_chosen"
  printf '%b' "$_qms_other" >"$_qms_repo/src/model.py"
  _qm_scan "$_qms_repo" "$_qms_log" --staged; _qms_actual=$?
  t_expect_rc "$_qms_rc" "$_qms_actual" "$1 staged receiver ignores opposite worktree"
  ( cd "$_qms_repo" && sh "$_QM_SCAN" --all ) >"$GG_T_TMPROOT/snapshot-census.json" 2>"$_qms_log"
  t_expect_rc 0 "$?" "$1 index census runs with opposite worktree"
  _qm_has "$GG_T_TMPROOT/snapshot-census.json" "\"pydantic_v1\": $_qms_count" "$1 index census follows staged source"
  _qm_put "$_qms_repo" src/model.py "$_qms_chosen"
  _qm_commit "$_qms_repo" 'selected snapshot'
  printf '%b' "$_qms_other" >"$_qms_repo/src/model.py"
  _qm_scan "$_qms_repo" "$_qms_log" --range "$_qms_base..HEAD"; _qms_actual=$?
  t_expect_rc "$_qms_rc" "$_qms_actual" "$1 range receiver ignores opposite worktree"
  ( cd "$_qms_repo" && sh "$_QM_SCAN" --all --rev HEAD ) >"$GG_T_TMPROOT/snapshot-revision.json" 2>"$_qms_log"
  t_expect_rc 0 "$?" "$1 selected-revision census runs"
  _qm_has "$GG_T_TMPROOT/snapshot-revision.json" "\"pydantic_v1\": $_qms_count" "$1 revision census follows committed source"
  gg_rmrepo "$_qms_repo"
}

# Protects: proven model enforcement and the exact Git source selected by each mode.
# Detects: false parser rejection, lost model blocks and unstaged-source leakage.
# Needs: real ast-grep/ruff and owned temporary Git repositories; no fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py and the two mandate/python/pydantic rules.
t_case_pydantic_receiver_classification() {
  t_begin '32 receiver-aware Pydantic classification (staged, range, census)'
  if ! gg_has_astgrep || ! command -v ruff >/dev/null 2>&1; then
    t_skip 'receiver classification needs actual ast-grep and ruff'
    return 0
  fi
  _qm_receiver_models
  _qm_receiver_plain_and_unknown
  _qm_receiver_attribute_mutations
  _qm_receiver_data_members
  _qm_receiver_settings_namespace
  _qm_receiver_modes
  _qm_receiver_snapshot_case model
  _qm_receiver_snapshot_case plain
}

# Protects: declared headers/annotations retain known legacy model findings.
# Detects: custom visitors dropping calls outside executable statement bodies.
# Needs: real scanner/source fixtures; annotations are scanned, never evaluated.
# Breadcrumb: hooks/common/mandate_scan.py class/function/annotated visitors.
_qm_receiver_header_contexts() {
  _qmr_model='from pydantic import BaseModel\nclass Model(BaseModel):\n    id: int = 1\n'
  _qm_receiver_case 'class base expression retains known model finding' \
    "${_qmr_model}class Child(Model.parse_obj({'id': 1}).__class__):\n    pass\n" 1 model
  _qm_receiver_case 'variable annotation retains known model finding' \
    "${_qmr_model}value: Model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'argument annotation retains known model finding' \
    "${_qmr_model}def probe(value: Model.parse_file('m.json')):\n    return value\n" 1 model
  _qm_receiver_case 'return annotation retains known model finding' \
    "${_qmr_model}def probe() -> Model.parse_file('m.json'):\n    return None\n" 1 model
  _qm_receiver_case 'ordinary model class config keyword retains strong type' \
    "${_qmr_model}class Configured(Model, extra='allow'):\n    pass\nConfigured.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'explicit metaclass remains uncertain' \
    "${_qmr_model}class Configured(Model, metaclass=opaque_factory):\n    pass\nConfigured.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'unpacked class options may contain a metaclass' \
    "${_qmr_model}class Configured(Model, **options):\n    pass\nConfigured.parse_file('m.json')\n" 0 unknown
}

# Protects: deferred generators/counts/comparisons/class effects retain uncertainty.
# Detects: four review-proven stale-proof paths plus eager/ordinary-write guards.
# Needs: actual staged scanner and owned source fixtures; no fixture execution.
# Breadcrumb: hooks/common/mandate_scan.py binding events/deferred/class visitors.
_qm_receiver_followup_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    id: int = 1\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'generator capture observes later rebound' \
    "${_qmr_types}receiver = Parser()\nloads = (receiver.parse_file('m.json') for item in [0])\nreceiver = Model\nlist(loads)\n" 0 unknown
  _qm_receiver_case 'compound statement retains both binding events' \
    "${_qmr_types}if condition:\n    receiver = Parser()\n    load = lambda: receiver.parse_file('m.json')\n    receiver = Model\n    load()\n" 0 unknown
  _qm_receiver_case 'one expression retains both binding events' \
    "${_qmr_types}((receiver := Parser()), (load := lambda: receiver.parse_file('m.json')), (receiver := Model), load())\n" 0 unknown
  _qm_receiver_case 'chained comparison merges conditional assignment' \
    "${_qmr_types}receiver = Model\n0 > 1 == (receiver := Parser())\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'immediate class body propagates external method mutation' \
    "${_qmr_types}class Patch:\n    Parser.parse_file = Model.parse_file\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'generator first iterator remains eager and strong' \
    "${_qmr_types}loads = (item for item in Model.parse_obj({'id': 1}))\n" 1 model
  _qm_receiver_case 'class body ordinary config retains model type' \
    "${_qmr_types}class Patch:\n    Model.model_config = {}\nModel.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'class body resolves old class name before publication' \
    "${_qmr_types}class Model:\n    @classmethod\n    def parse_file(cls, path):\n        return path\n    captured = Model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'initializer method replacement cannot retain plain proof' \
    "${_qmr_types}class Changed:\n    def __init__(self):\n        self.parse_file = Model.parse_file\n    def parse_file(self, path):\n        return path\nChanged().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'initializer callback remains unsupported and uncertain' \
    "${_qmr_types}class Changed:\n    def __init__(self):\n        self.install()\n    def install(self):\n        self.parse_file = Model.parse_file\n    def parse_file(self, path):\n        return path\nChanged().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'ordinary initializer data preserves plain proof' \
    "${_qmr_types}class Safe:\n    def __init__(self, path):\n        self.path = path\n    def parse_file(self, path):\n        return path\nSafe('root').parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'deferred method mutation is not an immediate class effect' \
    "${_qmr_types}class Patch:\n    def mutate(self):\n        Parser.parse_file = Model.parse_file\nParser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'nested immediate class mutation reaches outer proof' \
    "${_qmr_types}class Outer:\n    class Inner:\n        Parser.parse_file = Model.parse_file\nParser().parse_file('m.json')\n" 0 unknown
}

# Protects: reviewed expression/closure contexts preserve model policy boundaries.
# Detects: execution/scope contexts missed by basic receiver classification.
# Needs: real ast-grep/ruff, helper fixtures and UTF-8 source; no fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py receiver visitors and class inventory.
t_case_pydantic_receiver_contexts() {
  t_begin '32 receiver expression and closure review contexts'
  if ! gg_has_astgrep || ! command -v ruff >/dev/null 2>&1; then
    t_skip 'receiver contexts need actual ast-grep and ruff'
    return 0
  fi
  _qm_receiver_review_contexts
  _qm_receiver_header_contexts
  _qm_receiver_followup_contexts
  _qm_receiver_namespace_contexts
  _qm_receiver_lambda_scope_contexts
  _qm_receiver_annotation_effect_contexts
  _qm_receiver_nested_class_contexts
  _qm_receiver_declared_binding_contexts
  _qm_receiver_target_and_class_capture_contexts
  _qm_receiver_call_effect_composition_contexts
  _qm_receiver_class_declared_write_contexts
  _qm_receiver_callable_result_contexts
  _qm_receiver_store_boundary_contexts
  _qm_receiver_evaluation_order_contexts
  _qm_receiver_opaque_target_contexts
  _qm_receiver_initializer_boundary_contexts
  _qm_receiver_container_evaluation_contexts
  _qm_receiver_subscript_return_contexts
  _qm_receiver_control_flow_contexts
  _qm_receiver_iteration_target_contexts
  _qm_receiver_lambda_local_contexts
  _qm_receiver_bare_decorator_contexts
  _qm_receiver_decorator_order_contexts
  _qm_receiver_annotated_target_contexts
  _qm_receiver_unpacked_order_contexts
  _qm_receiver_parameter_annotation_contexts
  _qm_receiver_annotated_store_order_contexts
  _qm_receiver_mixed_annotation_contexts
  _qm_receiver_quoted_annotation_contexts
  _qm_receiver_class_base_capture_contexts
  _qm_receiver_quoted_root_controls
  _qm_receiver_base_revalidation_controls
  _qm_receiver_inner_base_owner_controls
  _qm_receiver_inner_base_effect_controls
  _qm_receiver_header_subscript_contexts
  _qm_receiver_legacy_annotation_inventory
  _qm_receiver_comprehension_scope_contexts
  _qm_receiver_parameter_hook_contexts
  _qm_receiver_data_hook_contexts
  _qm_receiver_projection_join_contexts
  _qm_receiver_effect_preservation_contexts
  _qm_receiver_callback_code_contexts
  _qm_receiver_initializer_descriptor_contexts
  _qm_receiver_descriptor_presence_contexts
  _qm_receiver_descriptor_eager_contexts
  _qm_receiver_descriptor_hash_contexts
  _qm_receiver_descriptor_eager_branch_contexts
  _qm_receiver_stored_class_contexts
  _qm_receiver_eager_prefix_contract_contexts
  _qm_receiver_eager_prefix_completion_contexts
  _qm_receiver_eager_prefix_prepare_contexts
  _qm_receiver_opaque_namespace_contexts
  _qm_receiver_binding_frames_contexts
  _qm_receiver_global_formals_contexts
  _qm_receiver_stored_owner_contexts
  _qm_receiver_comprehension_variants_contexts
  _qm_receiver_stored_field_horizon_contexts
  _qm_receiver_field_call_boundaries_contexts
  _qm_receiver_field_call_captures_contexts
  _qm_receiver_field_call_entry_contexts
  _qm_receiver_field_call_reentry_contexts
  _qm_receiver_field_call_annotations_contexts
  _qm_receiver_field_constructor_proofs_contexts
  _qm_receiver_field_stored_int_contexts
  _qm_receiver_field_namespace_calls_contexts
  _qm_receiver_field_model_prefix_contexts
  _qm_receiver_protocol_consumer_contexts
  _qm_receiver_protocol_modes_contract
  _qm_receiver_protocol_lifecycle_contract
}

# Protects: A base subscript captures its owner before evaluating its index.
# Detects: Own-index name changes inventing or dropping Model ancestry.
# Needs: real staged scanner,315compile-valid fixtures; no MRO/type mutation runs.
# Breadcrumb: hooks/common/mandate_scan.py capture_class_base/revalidate_binding.
_qm_receiver_inner_base_owner_controls() {
  _qmr_types='from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return "Parser"\n    def __class_getitem__(cls,item):\n        return cls\n'
  _qm_receiver_case 'plain generic owner is captured before index model rebind' \
    "${_qmr_types}Receiver=Parser\nclass Child(Receiver[(Receiver:=Model)]):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'model generic owner survives index parser name rebind' \
    "${_qmr_types}Receiver=Model\nclass Child(Receiver[(Receiver:=Parser)]):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'stable model generic base retains model ancestry' \
    "${_qmr_types}class Child(Model[int]):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'stable plain generic base stays unsupported' \
    "${_qmr_types}class Child(Parser[int]):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'own index type mutation invalidates captured model proof' \
    "${_qmr_types}def alter():\n    Model.__bases__=(external,)\n    return int\nclass Child(Model[alter()]):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'own index method-only mutation preserves model ancestry' \
    "${_qmr_types}def alter():\n    Model.parse_file=Parser.parse_file\n    return int\nclass Child(Model[alter()]):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
}

# Protects: Base snapshots retain data/no-call and independent index findings.
# Detects: Nested owner rereads or lost mutation/eager-call boundaries.
# Needs: real staged scanner,315compile-valid fixtures; no MRO/type mutation runs.
# Breadcrumb: hooks/common/mandate_scan.py capture_class_base/visit_ClassDef.
_qm_receiver_inner_base_effect_controls() {
  _qmr_types='from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return "Parser"\n    def __class_getitem__(cls,item):\n        return cls\n'
  _qm_receiver_case 'own index ordinary data preserves model ancestry' \
    "${_qmr_types}def alter():\n    Model.label='notes'\n    return int\nclass Child(Model[alter()]):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'uncalled index mutator does not change model base' \
    "${_qmr_types}def alter():\n    Model.__bases__=(external,)\n    return int\nclass Child(Model[int]):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'nested plain generic owner cannot become model ancestry' \
    "${_qmr_types}Receiver=Parser\nclass Child(Receiver[(Receiver:=Model)][int]):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'nested model generic owner survives name-only index writes' \
    "${_qmr_types}Receiver=Model\nclass Child(Receiver[((Receiver:=Parser),T)[1]][int]):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'generic base index retains independent model call evidence' \
    "${_qmr_types}class Child(Parser[Model.parse_file('x')]):\n    pass\n" 1 model
  _qm_receiver_case 'uncalled mutator does not invent plain generic return proof' \
    "${_qmr_types}def alter():\n    Parser.parse_file=Model.parse_file\n    return int\nclass Child(Parser[int]):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
}

# Protects: Quoted root guards preserve generic ancestry and ordinary data.
# Detects: Overbroad type-argument invalidation or malformed-string crashes.
# Needs: staged scanner/current315compile fixtures; type-mutation input never runs.
# Breadcrumb: hooks/common/mandate_scan.py receiver_annotation_root/value/stable_binding.
_qm_receiver_quoted_root_controls() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return "Parser"\n'
  _qm_receiver_case 'quoted generic model ignores unrelated type argument rebind' \
    "${_qmr_types}from pydantic import RootModel\nT=int\ndef load(receiver:'RootModel[T]'):\n    return receiver.parse_file('x')\nT=str\nanswer=load(RootModel[str]('x'))\n" 1 model
  _qm_receiver_case 'quoted plain proof survives ordinary data write' \
    "${_qmr_types}def load(receiver:'Parser'):\n    return receiver.parse_file('x')\nParser.label='notes'\nanswer=load(Parser())\n" 0 plain
  _qm_receiver_case 'malformed quoted annotation remains unresolved' \
    "${_qmr_types}def load(receiver:'???'):\n    return receiver.parse_file('x')\n" 0 unknown
}

# Protects: Captured bases separate later name writes from method/type effects.
# Detects: Stale ancestry after a type mutation or erased captured class objects.
# Needs: staged scanner/current315compile fixtures; type-mutation input never runs.
# Breadcrumb: hooks/common/mandate_scan.py visit_ClassDef/revalidate_binding.
_qm_receiver_base_revalidation_controls() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return "Parser"\n'
  _qm_receiver_case 'captured model survives later keyword name rebind' \
    "${_qmr_types}Receiver=Model\nclass Child(Receiver,extra=((Receiver:=Parser) and 'allow')):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'captured model loses proof after later base type mutation' \
    "${_qmr_types}def alter():\n    Model.__bases__=(external,)\n    return object\nclass Child(Model,alter()):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'captured model retains ancestry after method-only mutation' \
    "${_qmr_types}def alter():\n    Model.parse_file=Parser.parse_file\n    return object\nclass Child(Model,alter()):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
}

# Protects: Quoted annotation roots share existing capture invalidation.
# Detects: Stale quoted/nested/namespace proof after name rebinding.
# Needs: actual staged scanner, compile-valid315 fixtures; no imports/execution.
# Breadcrumb: hooks/common/mandate_scan.py receiver_annotation_root/visit_FunctionDef.
_qm_receiver_quoted_annotation_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return "Parser"\n'
  _qm_receiver_case 'quoted plain annotation cannot survive later model rebind' \
    "${_qmr_types}def load(receiver:'Parser'):\n    return receiver.parse_file('x')\nParser=Model\nanswer=load(Parser())\n" 0 unknown
  _qm_receiver_case 'quoted model annotation cannot survive later parser rebind' \
    "${_qmr_types}def load(receiver:'Model'):\n    return receiver.parse_file('x')\nModel=Parser\nanswer=load(Model())\n" 0 unknown
  _qm_receiver_case 'stable quoted plain annotation remains plain' \
    "${_qmr_types}def load(receiver:'Parser'):\n    return receiver.parse_file('x')\nanswer=load(Parser())\n" 0 plain
  _qm_receiver_case 'stable quoted model annotation remains strong' \
    "${_qmr_types}def load(receiver:'Model'):\n    return receiver.parse_file('x')\nanswer=load(Model())\n" 1 model
  _qm_receiver_case 'unquoted rebound annotation retains existing uncertainty' \
    "${_qmr_types}def load(receiver:Parser):\n    return receiver.parse_file('x')\nParser=Model\nanswer=load(Parser())\n" 0 unknown
  _qm_receiver_case 'nested quoted annotation cannot retain rebound plain proof' \
    "${_qmr_types}def load(receiver:\"'Parser'\"):\n    return receiver.parse_file('x')\nParser=Model\nanswer=load(Parser())\n" 0 unknown
  _qm_receiver_case 'quoted namespace annotation cannot retain rebound model proof' \
    "${_qmr_types}import pydantic as pd\ndef load(receiver:'pd.BaseModel'):\n    return receiver.parse_file('x')\nclass Namespace:\n    BaseModel=Parser\npd=Namespace\nanswer=load(pd.BaseModel())\n" 0 unknown
}

# Protects: Class bases retain evidence captured at each expression.
# Detects: Later name rebinding inventing or discarding model ancestry.
# Needs: actual staged scanner, compile-valid315 fixtures; no imports/execution.
# Breadcrumb: hooks/common/mandate_scan.py visit_ClassDef/revalidate_binding.
_qm_receiver_class_base_capture_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return "Parser"\n'
  _qm_receiver_case 'class base captures plain before later name rebind' \
    "${_qmr_types}Receiver=Parser\nclass Child(Receiver,(Receiver:=Model) and object):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'class base captures model before later name rebind' \
    "${_qmr_types}Receiver=Model\nclass Child(Receiver,(Receiver:=Parser) and object):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'stable single plain base remains plain' \
    "${_qmr_types}class Child(Parser):\n    pass\nanswer=Child().parse_file('x')\n" 0 plain
  _qm_receiver_case 'stable single model base remains strong' \
    "${_qmr_types}class Child(Model):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
  _qm_receiver_case 'later base mutator invalidates captured plain proof' \
    "${_qmr_types}Receiver=Parser\ndef install():\n    Parser.parse_file=Model.parse_file\n    return object\nclass Child(Receiver,install()):\n    pass\nanswer=Child().parse_file('x')\n" 0 unknown
  _qm_receiver_case 'later base name call preserves captured model object' \
    "${_qmr_types}Receiver=Model\ndef change():\n    global Receiver\n    Receiver=Parser\n    return object\nclass Child(Receiver,change()):\n    pass\nanswer=Child().parse_file('x')\n" 1 model
}

# Protects: Both observed mixed parameter annotation orders retain evidence.
# Detects: Order-sensitive plain exemptions or loss of a possible model call.
# Needs: actual staged scanner and315compile-valid fixtures;310/315 proof separate.
# Breadcrumb: hooks/common/mandate_scan.py visit_parameter_annotations/cache.
_qm_receiver_mixed_annotation_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'mixed order cannot exempt initial plain posonly call' \
    "${_qmr_types}receiver=Parser()\ndef change():\n    global receiver\n    receiver=Model\ndef load(a: receiver.parse_file('m.json'), /, b: change()):\n    pass\n" 0 unknown
  _qm_receiver_case 'mixed order retains initial model posonly call' \
    "${_qmr_types}receiver=Model\ndef change():\n    global receiver\n    receiver=Parser()\ndef load(a: receiver.parse_file('m.json'), /, b: change()):\n    pass\n" 1 model
  _qm_receiver_case 'mixed order retains initial model normal call' \
    "${_qmr_types}receiver=Model\ndef change():\n    global receiver\n    receiver=Parser()\ndef load(a: change(), /, b: receiver.parse_file('m.json')):\n    pass\n" 1 model
  _qm_receiver_case 'mixed order cannot exempt initial plain normal call' \
    "${_qmr_types}receiver=Parser()\ndef change():\n    global receiver\n    receiver=Model\ndef load(a: change(), /, b: receiver.parse_file('m.json')):\n    pass\n" 0 unknown
  _qm_receiver_case 'mixed stable model annotations retain strong evidence' \
    "${_qmr_types}def load(a: Model.parse_file('m.json'), /, b: Model.parse_file('m.json')):\n    pass\n" 1 model
  _qm_receiver_case 'mixed stable plain annotations remain plain' \
    "${_qmr_types}def load(a: Parser().parse_file('notes.md'), /, b: Parser().parse_file('notes.md')):\n    pass\n" 0 plain
  _qm_receiver_case 'unmixed annotation call precedes return write' \
    "${_qmr_types}receiver=Model\ndef change():\n    global receiver\n    receiver=Parser()\ndef load(a: receiver.parse_file('m.json')) -> change():\n    pass\n" 1 model
}

# Protects: Annotated assignment stores precede annotation-source inspection.
# Detects: Stale receiver proof in name/member annotations and inverse blocks.
# Needs: actual staged scanner, compile-valid315 fixtures; legacy310 order separate.
# Breadcrumb: hooks/common/mandate_scan.py visit_AnnAssign.
_qm_receiver_annotated_store_order_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'annotated name stores model before scanning annotation' \
    "${_qmr_types}receiver = Parser()\nreceiver: receiver.parse_file('m.json') = Model\n" 1 model
  _qm_receiver_case 'annotated name stores parser before scanning annotation' \
    "${_qmr_types}receiver = Model\nreceiver: receiver.parse_file('notes.md') = Parser()\n" 0 plain
  _qm_receiver_case 'annotated method store precedes annotation call' \
    "${_qmr_types}Parser.parse_file: Parser().parse_file('m.json') = Model.parse_file\n" 0 unknown
  _qm_receiver_case 'annotated ordinary data preserves plain call' \
    "${_qmr_types}Parser.label: Parser().parse_file('notes.md') = 'label'\n" 0 plain
  _qm_receiver_case 'annotation without value preserves existing model' \
    "${_qmr_types}receiver = Model\nreceiver: receiver.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'simple declaration retains known model evidence' \
    "${_qmr_types}receiver: Model = None\nreceiver.parse_file('m.json')\n" 1 model
}

# Protects: Only actual annotated names acquire declaration evidence.
# Detects: Walrus bindings in loaded target expressions must retain their own values.
# Needs: actual staged scanner and compile-valid315 fixtures; no fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py AnnAssign and receiver_target_leaves.
_qm_receiver_annotated_target_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'annotated subscript walrus keeps model binding' \
    "${_qmr_types}cache[(receiver := Model)]: Parser = None\nreceiver.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'annotated subscript walrus keeps plain binding' \
    "${_qmr_types}cache[(receiver := Parser())]: Model = None\nreceiver.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'simple annotated name retains declared model evidence' \
    "${_qmr_types}receiver: Model = None\nreceiver.parse_file('m.json')\n" 1 model
}

# Protects: Assignment leaves take effect left to right across nested/starred targets.
# Detects: Later target expressions must observe prior method writes or name stores.
# Needs: actual staged scanner and compile-valid315 fixtures; no fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py visit_Assign, target traversal and invalidation.
_qm_receiver_unpacked_order_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'unpacked earlier mutation reaches later target call' \
    "${_qmr_types}Parser.parse_file, cache[Parser().parse_file('x')] = Model.parse_file, 0\n" 0 unknown
  _qm_receiver_case 'unpacked ordinary data preserves later plain target' \
    "${_qmr_types}Parser.label, cache[Parser().parse_file('notes.md')] = 'label', 0\n" 0 plain
  _qm_receiver_case 'unpacked name store cannot retain previous plain value' \
    "${_qmr_types}receiver = Parser()\nreceiver, cache[receiver.parse_file('m.json')] = Model, 0\n" 0 unknown
  _qm_receiver_case 'nested unpacked mutation precedes nested target call' \
    "${_qmr_types}Parser.parse_file, (other, cache[Parser().parse_file('x')]) = Model.parse_file, (0, 1)\n" 0 unknown
  _qm_receiver_case 'starred unpacked mutation precedes later target call' \
    "${_qmr_types}Parser.parse_file, *other, cache[Parser().parse_file('x')] = Model.parse_file, 0, 1\n" 0 unknown
}

# Protects: Function defaults and parameter annotations precede return annotations.
# Detects: Return-header effects cannot rewrite earlier parameter-call evidence.
# Needs: actual staged scanner and compile-valid315 fixtures; no fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py visit_FunctionDef eager header traversal.
_qm_receiver_parameter_annotation_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'parameter model annotation precedes return declared write' \
    "${_qmr_types}receiver = Model\ndef change():\n    global receiver\n    receiver = Parser()\ndef load(value: receiver.parse_file('m.json')) -> change():\n    pass\n" 1 model
  _qm_receiver_case 'parameter plain annotation precedes return declared write' \
    "${_qmr_types}receiver = Parser()\ndef change():\n    global receiver\n    receiver = Model\ndef load(value: receiver.parse_file('notes.md')) -> change():\n    pass\n" 0 plain
  _qm_receiver_case 'unchanged parameter model annotation remains strong' \
    "${_qmr_types}receiver = Model\ndef load(value: receiver.parse_file('m.json')) -> None:\n    pass\n" 1 model
  _qm_receiver_case 'default evaluation precedes parameter annotation' \
    "${_qmr_types}receiver = Model\ndef load(value: receiver.parse_file('notes.md') = (receiver := Parser())):\n    pass\n" 0 plain
  _qm_receiver_case 'parameter declared write precedes return model evidence' \
    "${_qmr_types}receiver = Model\ndef change():\n    global receiver\n    receiver = Parser()\ndef load(value: change()) -> receiver.parse_file('m.json'):\n    pass\n" 0 unknown
  _qm_receiver_case 'parameter declared write precedes return plain evidence' \
    "${_qmr_types}receiver = Parser()\ndef change():\n    global receiver\n    receiver = Model\ndef load(value: change()) -> receiver.parse_file('m.json'):\n    pass\n" 0 unknown
}

# Protects: nested lambda captures account for their enclosing lambda's writes.
# Detects: stale plain exemptions and stale model blocks across local rebinding.
# Needs: actual staged scanner and syntax-valid fixtures; no fixture execution.
# Breadcrumb: hooks/common/mandate_scan.py visit_Lambda/deferred_bindings.
_qm_receiver_lambda_local_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'lambda local later model invalidates nested capture' \
    "${_qmr_types}run = lambda: ((receiver := Parser()), (load := lambda: receiver.parse_file('notes.md')), (receiver := Model), load())\n" 0 unknown
  _qm_receiver_case 'lambda local later parser cannot retain initial model capture' \
    "${_qmr_types}run = lambda: ((receiver := Model), (load := lambda: receiver.parse_file('notes.md')), (receiver := Parser()), load())\n" 0 unknown
  _qm_receiver_case 'lambda stable plain local remains plain' \
    "${_qmr_types}run = lambda: ((receiver := Parser()), (load := lambda: receiver.parse_file('notes.md')), load())\n" 0 plain
  _qm_receiver_case 'lambda stable model local remains strong' \
    "${_qmr_types}run = lambda: ((receiver := Model), (load := lambda: receiver.parse_file('m.json')), load())\n" 1 model
}

# Protects: executing known bare decorators invalidates affected receiver proof.
# Detects: omitted implicit calls and future effects missing from captures.
# Needs: actual staged scanner and owned fixtures; decorators are never executed.
# Breadcrumb: hooks/common/mandate_scan.py immediate_call_names/decorator effects.
_qm_receiver_bare_decorator_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qmr_install='def install(fn):\n    Parser.parse_file = Model.parse_file\n    return fn\n'
  _qm_receiver_case 'bare function decorator applies known mutation' \
    "${_qmr_types}${_qmr_install}@install\ndef decorated():\n    pass\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'bare class decorator applies known mutation' \
    "${_qmr_types}${_qmr_install}@install\nclass Decorated:\n    pass\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'earlier lambda capture sees later bare decorator' \
    "${_qmr_types}${_qmr_install}load = lambda: Parser().parse_file('m.json')\n@install\ndef decorated():\n    pass\nload()\n" 0 unknown
  _qm_receiver_case 'earlier function capture sees later bare decorator' \
    "${_qmr_types}${_qmr_install}def load():\n    return Parser().parse_file('m.json')\n@install\ndef decorated():\n    pass\nload()\n" 0 unknown
  _qm_receiver_case 'data-only decorator preserves plain parser' \
    "${_qmr_types}def install(fn):\n    Parser.label = 'notes'\n    return fn\n@install\ndef decorated():\n    pass\nParser().parse_file('notes.md')\n" 0 plain
}

# Protects: decorator application follows eager expressions and class suites.
# Detects: effects applied too early or to uncalled/data-only/model consumers.
# Needs: real staged scanner; fixtures describe evaluation without running it.
# Breadcrumb: hooks/common/mandate_scan.py FunctionDef/ClassDef effect ordering.
_qm_receiver_decorator_order_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qmr_install='def install(fn):\n    Parser.parse_file = Model.parse_file\n    return fn\n'
  _qm_receiver_case 'uncalled decorator preserves plain parser' \
    "${_qmr_types}${_qmr_install}Parser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'function decorator effects follow all eager expressions' \
    "${_qmr_types}${_qmr_install}def wrap(value):\n    return lambda fn: fn\n@install\n@wrap(Parser().parse_file('notes.md'))\ndef decorated():\n    pass\n" 0 plain
  _qm_receiver_case 'class decorator effects follow immediate class suite' \
    "${_qmr_types}${_qmr_install}@install\nclass Decorated:\n    value = Parser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'bare method mutation preserves unrelated model type' \
    "${_qmr_types}${_qmr_install}@install\ndef decorated():\n    pass\nModel.parse_file('m.json')\n" 1 model
}

# Protects: annotations and class/import namespaces cannot invent plain proof.
# Detects: no-value annotations, inherited overrides and class-scope leakage.
# Needs: real staged scanner, declared model/parser fixtures; no fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py AnnAssign, ClassDef and comprehensions.
_qm_receiver_namespace_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'annotation-only preserves existing model' \
    "${_qmr_types}receiver = Model\nreceiver: Parser\nreceiver.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'annotation-only preserves existing plain method' \
    "${_qmr_types}class Child(Parser):\n    parse_file: object\nChild().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'multiple inheritance cannot borrow later plain proof' \
    "${_qmr_types}class Left:\n    parse_file = Model.parse_file\nclass Child(Left, Parser):\n    pass\nChild().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'single-base plain inheritance remains supported' \
    "${_qmr_types}class Child(Parser):\n    pass\nChild().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'multiple model bases retain known-model enforcement' \
    "${_qmr_types}class Child(Model, Parser):\n    pass\nChild.parse_file('m.json')\n" 1 model
  for _qmr_comp in \
    "[Model.parse_file('m.json') for item in [0]]" \
    "{Model.parse_file('m.json') for item in [0]}" \
    "{item: Model.parse_file('m.json') for item in [0]}" \
    "(Model.parse_file('m.json') for item in [0])"; do
    _qm_receiver_case "class comprehension global model: $_qmr_comp" \
      "${_qmr_types}class Scope:\n    Model = Parser\n    values = $_qmr_comp\n" 1 model
  done
  _qm_receiver_case 'class comprehension eager iterator sees class locals' \
    "${_qmr_types}class Scope:\n    Model = Parser\n    values = [item for item in Model.parse_file('notes.md')]\n" 0 plain
  _qm_receiver_case 'wildcard import invalidates earlier plain proof' \
    "${_qmr_types}from external_models import *\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'wildcard import cannot retain deferred plain capture' \
    "${_qmr_types}def load():\n    return Parser().parse_file('m.json')\nfrom external_models import *\n" 0 unknown
  _qm_receiver_case 'wildcard strict ambiguity still blocks' \
    "${_qmr_types}from external_models import *\nParser().parse_file('m.json')\n" 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'generator walrus cannot retain enclosing plain binding' \
    "${_qmr_types}receiver = Parser()\nloads = ((receiver := Model) for item in [0])\nnext(loads)\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'called method mutation cannot retain outer plain proof' \
    "${_qmr_types}class Patch:\n    def mutate(self):\n        Parser.parse_file = Model.parse_file\nPatch().mutate()\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'called instance installer cannot retain plain method' \
    "${_qmr_types}class Changed:\n    def install(self):\n        self.parse_file = Model.parse_file\n    def parse_file(self, path):\n        return path\nreceiver = Changed()\nreceiver.install()\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'class generator cannot restore proof before future star import' \
    "${_qmr_types}class Scope:\n    loads = (Parser().parse_file('m.json') for item in [0])\nfrom external_models import *\nlist(Scope.loads)\n" 0 unknown
  _qm_receiver_case 'class comprehension cannot restore proof after method mutation' \
    "${_qmr_types}class Scope:\n    Parser.parse_file = Model.parse_file\n    values = [Parser().parse_file('m.json') for item in [0]]\n" 0 unknown
}

# Protects: lambda parameters override class/global names in nested expressions.
# Detects: comprehension scope accidentally borrowing the enclosing class view.
# Needs: staged scanner; real lexical fixtures and eager-default counterpart.
# Breadcrumb: hooks/common/mandate_scan.py visit_Lambda and comprehension.
_qm_receiver_lambda_scope_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'class lambda comprehension retains parameter scope' \
    "${_qmr_types}class Scope:\n    load = lambda Model: [Model.parse_file('m.json') for item in [0]]\n" 0 unknown
  _qm_receiver_case 'class lambda generator retains parameter scope' \
    "${_qmr_types}class Scope:\n    load = lambda Model: (Model.parse_file('m.json') for item in [0])\n" 0 unknown
  _qm_receiver_case 'class lambda comprehension still sees global model' \
    "${_qmr_types}class Scope:\n    Model = Parser\n    load = lambda: [Model.parse_file('m.json') for item in [0]]\n" 1 model
  _qm_receiver_case 'class lambda default still sees immediate class namespace' \
    "${_qmr_types}class Scope:\n    Model = Parser\n    load = lambda value=Model.parse_file('notes.md'): value\n" 0 plain
}

# Protects: annotations without values do not become writes in effect scans.
# Detects: false capture rebinding and false method/type mutation barriers.
# Needs: staged scanner; declared model/parser and deferred-call controls.
# Breadcrumb: hooks/common/mandate_scan.py receiver_binding_events/mutated_names.
_qm_receiver_annotation_effect_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'annotation-only method target does not mutate deferred parser' \
    "${_qmr_types}Parser.parse_file: object\ndef load():\n    return Parser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'annotation-only bases target does not erase model ancestry' \
    "${_qmr_types}Model.__bases__: tuple\ndef load():\n    return Model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'annotation-only name does not rebind deferred parser' \
    "${_qmr_types}receiver = Parser()\nload = lambda: receiver.parse_file('notes.md')\nreceiver: Model\n" 0 plain
}

# Protects: nested-class free names skip enclosing class-local namespaces.
# Detects: class-body locals and nested publication leaking into method globals.
# Needs: staged scanner, known model, plain classmethod and eager-header control.
# Breadcrumb: hooks/common/mandate_scan.py visit_ClassDef lexical/deferred views.
_qm_receiver_nested_class_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls, path):\n        return object\n'
  _qm_receiver_case 'nested class method skips enclosing class-local model name' \
    "${_qmr_types}class Outer:\n    Model = Parser\n    class Inner:\n        def load(self):\n            return Model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'nested class body skips enclosing class-local model name' \
    "${_qmr_types}class Outer:\n    Model = Parser\n    class Inner:\n        value = Model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'nested class name is not published into module globals' \
    "${_qmr_types}class Outer:\n    class Model:\n        @classmethod\n        def parse_file(cls, path):\n            return path\n        def load(self):\n            return Model.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'nested class base expression uses immediate outer class namespace' \
    "${_qmr_types}class Outer:\n    Model = Parser\n    class Inner(Model.parse_file('notes.md')):\n        pass\n" 0 plain
}

# Protects: called global/nonlocal rebindings cannot preserve obsolete proof.
# Detects: ignoring declared-name writes or treating them as object mutation.
# Needs: staged scanner and no-write/config/unrelated-model counterparts.
# Breadcrumb: hooks/common/mandate_scan.py declared-name summaries and visit_Call.
_qm_receiver_declared_binding_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'called global binding change cannot retain plain receiver' \
    "${_qmr_types}receiver = Parser()\ndef change():\n    global receiver\n    receiver = Model\nchange()\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'called nonlocal binding change cannot retain plain receiver' \
    "${_qmr_types}def outer():\n    receiver = Parser()\n    def change():\n        nonlocal receiver\n        receiver = Model\n    change()\n    return receiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'global declaration without write preserves plain receiver' \
    "${_qmr_types}receiver = Parser()\ndef inspect():\n    global receiver\n    return receiver\ninspect()\nreceiver.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'called global receiver change preserves unrelated model' \
    "${_qmr_types}receiver = Parser()\ndef change():\n    global receiver\n    receiver = Model\nchange()\nModel.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'global declaration and model config write preserve model type' \
    "${_qmr_types}def configure():\n    global Model\n    Model.model_config = {}\nconfigure()\nModel.parse_file('m.json')\n" 1 model
}

# Protects: unpacked mutations and immediate class suites invalidate captures.
# Detects: mutation summaries stopping at tuple/list/starred targets or classes.
# Needs: staged scanner; deferred/no-call/model/data-write counterparts.
# Breadcrumb: hooks/common/mandate_scan.py target mutation leaves and scope prepass.
_qm_receiver_target_and_class_capture_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'tuple unpacking invalidates changed method slot' \
    "${_qmr_types}Parser.parse_file, unused = Model.parse_file, None\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'list unpacking invalidates changed method slot' \
    "${_qmr_types}[Parser.parse_file, unused] = [Model.parse_file, None]\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'starred target cannot retain callable method proof' \
    "${_qmr_types}*Parser.parse_file, unused = Model.parse_file, None\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'deferred function sees later immediate class mutation' \
    "${_qmr_types}def load():\n    return Parser().parse_file('m.json')\nclass Patch:\n    Parser.parse_file = Model.parse_file\nload()\n" 0 unknown
  _qm_receiver_case 'deferred lambda sees later immediate class mutation' \
    "${_qmr_types}load = lambda: Parser().parse_file('m.json')\nclass Patch:\n    Parser.parse_file = Model.parse_file\nload()\n" 0 unknown
  _qm_receiver_case 'class inside uncalled function is not an immediate mutation' \
    "${_qmr_types}def define_patch():\n    class Patch:\n        Parser.parse_file = Model.parse_file\nParser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'class parser mutation preserves unrelated deferred model' \
    "${_qmr_types}def load():\n    return Model.parse_file('m.json')\nclass Patch:\n    Parser.parse_file = Model.parse_file\nload()\n" 1 model
  _qm_receiver_case 'unpacked ordinary data write preserves plain method proof' \
    "${_qmr_types}[Parser.label, unused] = ['notes', None]\nParser().parse_file('notes.md')\n" 0 plain
}

# Protects: modeled local call effects compose with captures, classes and loops.
# Detects: effects discarded by scope copies or deferred generator consumption.
# Needs: staged scanner; no-call/data/eager-iterator model counterparts.
# Breadcrumb: hooks/common/mandate_scan.py eager call-name summaries and scope views.
_qm_receiver_call_effect_composition_contexts() {
  _qmr_effect_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\nclass Patch:\n    def mutate(self):\n        Parser.parse_file = Model.parse_file\n'
  _qm_receiver_case 'immediate class calls local sensitive mutator' \
    "${_qmr_effect_types}class Run:\n    Patch().mutate()\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'deferred capture sees later local mutator call' \
    "${_qmr_effect_types}load = lambda: Parser().parse_file('m.json')\nPatch().mutate()\nload()\n" 0 unknown
  _qm_receiver_case 'deferred capture sees later declared global call effect' \
    "${_qmr_effect_types}receiver = Parser()\ndef change():\n    global receiver\n    receiver = Model\nload = lambda: receiver.parse_file('m.json')\nchange()\nload()\n" 0 unknown
  _qm_receiver_case 'generator body local mutator may change outer method' \
    "${_qmr_effect_types}changes = (Patch().mutate() for item in [0])\nnext(changes)\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'generator body declared call may change outer binding' \
    "${_qmr_effect_types}receiver = Parser()\ndef change():\n    global receiver\n    receiver = Model\nchanges = (change() for item in [0])\nnext(changes)\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'loop call effects survive discarded scope copies' \
    "${_qmr_effect_types}for item in [0]:\n    Patch().mutate()\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'uncalled mutator leaves deferred plain capture intact' \
    "${_qmr_effect_types}load = lambda: Parser().parse_file('notes.md')\nload()\n" 0 plain
  _qm_receiver_case 'generator ordinary data call preserves plain method' \
    "${_qmr_effect_types}def store():\n    Parser.label = 'notes'\nchanges = (store() for item in [0])\nnext(changes)\nParser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'generator first iterator remains eager before body effects' \
    "${_qmr_effect_types}changes = (Patch().mutate() for item in Model.parse_file('m.json'))\n" 1 model
}

# Protects: only declared writes escape copied class namespaces.
# Detects: lost globals and declarations conflated with unrelated outer stores.
# Needs: staged scanner, deferred reader and no-write/config counterparts.
# Breadcrumb: hooks/common/mandate_scan.py receiver_declared_writes and scope effects.
_qm_receiver_class_declared_write_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'class global write invalidates enclosing receiver' \
    "${_qmr_types}receiver = Parser()\nclass Patch:\n    global receiver\n    receiver = Model\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'deferred capture sees class global write' \
    "${_qmr_types}receiver = Parser()\nload = lambda: receiver.parse_file('m.json')\nclass Patch:\n    global receiver\n    receiver = Model\nload()\n" 0 unknown
  _qm_receiver_case 'class global declaration without write preserves receiver' \
    "${_qmr_types}receiver = Parser()\nclass Inspect:\n    global receiver\n    value = 'notes'\nload = lambda: receiver.parse_file('notes.md')\nload()\n" 0 plain
  _qm_receiver_case 'class global config write preserves model type' \
    "${_qmr_types}class Configure:\n    global Model\n    Model.model_config = {}\nModel.parse_file('m.json')\n" 1 model
}

# Protects: constructor proof does not become callable-instance return proof.
# Detects: repeated calls, parameter/self confusion and ownership-join regression.
# Needs: staged scanner; real class/instance/classmethod and known-model fixtures.
# Breadcrumb: hooks/common/mandate_scan.py ReceiverBinding instance flag and value.
_qm_receiver_callable_result_contexts() {
  _qmr_factory='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Factory:\n    def parse_file(self, path):\n        return path\n    def __call__(self):\n        return Model\n'
  _qm_receiver_case 'callable instance result is not constructor proof' \
    "${_qmr_factory}factory = Factory()\nfactory().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'constructor result still owns declared plain method' \
    "${_qmr_factory}Factory().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'annotated callable parameter is an instance' \
    "${_qmr_factory}def load(factory: Factory):\n    return factory().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'implicit self callable result remains unresolved' \
    "${_qmr_factory}class Child(Factory):\n    def load(self):\n        return self().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'implicit cls still constructs a plain instance' \
    "${_qmr_factory}class Child(Factory):\n    @classmethod\n    def load(cls):\n        return cls().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'model class and instance join retain model ownership' \
    "${_qmr_factory}receiver = Model\nif choice:\n    receiver = Model()\nreceiver.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'model instance call result is not proven model' \
    "${_qmr_factory}class CallableModel(Model):\n    def __call__(self):\n        return Factory()\ninstance = CallableModel()\ninstance().parse_file('notes.md')\n" 0 unknown
  _qm_receiver_case 'shadowed classmethod does not prove constructor cls' \
    "${_qmr_factory}classmethod = lambda fn: fn\nclass Child(Factory):\n    @classmethod\n    def load(cls):\n        return cls().parse_file('m.json')\n" 0 unknown
}

# Protects: explicit Store targets and unresolved mutation aliases lose proof.
# Detects: loop/context targets omitted or annotations restoring unsafe captures.
# Needs: staged scanner; ordinary-data and known-model mutation counterparts.
# Breadcrumb: hooks/common/mandate_scan.py receiver_mutated_names/invalidate_binding.
_qm_receiver_store_boundary_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'for attribute target changes method slot' \
    "${_qmr_types}for Parser.parse_file in [Model.parse_file]:\n    pass\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'async-for attribute target changes method slot' \
    "${_qmr_types}async def load(values):\n    async for Parser.parse_file in values:\n        pass\n    return Parser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'comprehension attribute target changes method slot' \
    "${_qmr_types}values = [None for Parser.parse_file in [Model.parse_file]]\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'context optional target changes method slot' \
    "from contextlib import nullcontext\n${_qmr_types}with nullcontext(Model.parse_file) as Parser.parse_file:\n    pass\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'unknown unpacked alias mutation invalidates deferred proof' \
    "${_qmr_types}Alias, unused = Parser, None\ndef load():\n    return Parser().parse_file('m.json')\nAlias.parse_file = Model.parse_file\nload()\n" 0 unknown
  _qm_receiver_case 'annotation cannot restore proof across unresolved mutation' \
    "${_qmr_types}Alias, unused = Parser, None\ndef load(parser: Parser):\n    return parser.parse_file('m.json')\nAlias.parse_file = Model.parse_file\nload(Parser())\n" 0 unknown
  _qm_receiver_case 'ordinary unknown-alias data write preserves plain method' \
    "${_qmr_types}Alias, unused = Parser, None\nAlias.label = 'notes'\nload = lambda: Parser().parse_file('notes.md')\nload()\n" 0 plain
  _qm_receiver_case 'unknown method mutation preserves unrelated known model' \
    "${_qmr_types}Alias, unused = Parser, None\nAlias.parse_file = Model.parse_file\nModel.parse_file('m.json')\n" 1 model
}

# Protects: receiver evaluation effects apply before method ownership is read.
# Detects: constructor argument mutation cleared before the argument is visited.
# Needs: real staged scanner, data-only and method-lookup-before-args controls.
# Breadcrumb: hooks/common/mandate_scan.py PydanticReceivers.visit_Call.
_qm_receiver_evaluation_order_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def __init__(self, marker=None):\n        self.marker = marker\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'constructor argument mutation precedes method ownership' \
    "${_qmr_types}def install():\n    Parser.parse_file = Model.parse_file\nParser(install()).parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'constructor keyword mutation precedes method ownership' \
    "${_qmr_types}def install():\n    Parser.parse_file = Model.parse_file\nParser(marker=install()).parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'constructor data-only argument preserves plain ownership' \
    "${_qmr_types}def store():\n    Parser.label = 'notes'\nParser(store()).parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'method lookup precedes mutation in call argument' \
    "${_qmr_types}def install():\n    Parser.parse_file = Model.parse_file\nParser().parse_file(install())\n" 0 plain
}

# Protects: unsupported mutation roots cannot silently preserve plain proof.
# Detects: type/call/container roots ignored by the same mutation prepass.
# Needs: actual staged scanner; ordinary-data, capture and known-model controls.
# Breadcrumb: hooks/common/mandate_scan.py receiver_target_mutation.
_qm_receiver_opaque_target_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'type-call mutation root forfeits plain instance proof' \
    "${_qmr_types}parser = Parser()\ntype(parser).parse_file = Model.parse_file\nparser.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'container mutation root forfeits plain proof' \
    "${_qmr_types}[Parser][0].parse_file = Model.parse_file\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'opaque mutation root invalidates deferred capture' \
    "${_qmr_types}parser = Parser()\nload = lambda: parser.parse_file('m.json')\ntype(parser).parse_file = Model.parse_file\nload()\n" 0 unknown
  _qm_receiver_case 'type-call ordinary data target preserves plain method' \
    "${_qmr_types}parser = Parser()\ntype(parser).label = 'notes'\nparser.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'opaque method mutation preserves unrelated known model' \
    "${_qmr_types}parser = Parser()\ntype(parser).parse_file = Model.parse_file\nModel.parse_file('m.json')\n" 1 model
}

# Protects: unsupported constructor and class-creation hooks cannot prove plain.
# Detects: alias/decorated initializers or inherited hooks replacing methods.
# Needs: staged scanner; supported data-only constructor/inheritance controls.
# Breadcrumb: hooks/common/mandate_scan.py plain_initializer_supported/ClassDef.
_qm_receiver_initializer_boundary_contexts() {
  _qmr_model='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\n'
  _qm_receiver_case 'aliased initializer cannot retain plain proof' \
    "${_qmr_model}def install(self):\n    Parser.parse_file = Model.parse_file\nclass Parser:\n    __init__ = install\n    def parse_file(self, path):\n        return path\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'decorated initializer cannot retain plain proof' \
    "${_qmr_model}def install(self):\n    Parser.parse_file = Model.parse_file\ndef wrap(method):\n    return install\nclass Parser:\n    @wrap\n    def __init__(self):\n        pass\n    def parse_file(self, path):\n        return path\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'inherited class-creation hook cannot retain plain proof' \
    "${_qmr_model}class Base:\n    def __init_subclass__(cls):\n        cls.parse_file = Model.parse_file\nclass Parser(Base):\n    def parse_file(self, path):\n        return path\nParser().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'data-only initializer and ordinary base remain plain' \
    "${_qmr_model}class Base:\n    def __init__(self):\n        self.label = 'notes'\nclass Parser(Base):\n    def parse_file(self, path):\n        return path\nParser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'annotation-only initializer retains plain proof' \
    "${_qmr_model}class Parser:\n    __init__: object\n    def parse_file(self, path):\n        return path\nParser().parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'model class-creation hook preserves known ancestry' \
    "${_qmr_model}class Child(Model):\n    def __init_subclass__(cls):\n        cls.label = 'model'\nChild.parse_file('m.json')\n" 1 model
}

# Protects: executable comprehension targets and dictionary pair order.
# Detects: target calls omitted, or all keys evaluated before preceding values.
# Needs: real staged scanner; model/plain order reversals and unpacking controls.
# Breadcrumb: hooks/common/mandate_scan.py comprehension/visit_Dict.
_qm_receiver_container_evaluation_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'comprehension target executes known model' \
    "${_qmr_types}[None for results[Model.parse_obj(data).id] in values]\n" 1 model
  _qm_receiver_case 'comprehension target executes plain parser' \
    "${_qmr_types}[None for results[Parser().parse_file('notes.md')] in values]\n" 0 plain
  _qm_receiver_case 'dictionary value rebinding precedes later key' \
    "${_qmr_types}receiver = Parser()\nresult = {0: (receiver := Model), receiver.parse_file('m.json'): 1}\n" 1 model
  _qm_receiver_case 'dictionary value parser precedes later key' \
    "${_qmr_types}receiver = Model\nresult = {0: (receiver := Parser()), receiver.parse_file('notes.md'): 1}\n" 0 plain
  _qm_receiver_case 'dictionary unpacking precedes later key' \
    "${_qmr_types}receiver = Parser()\nresult = {**{0: (receiver := Model)}, receiver.parse_file('m.json'): 1}\n" 1 model
}

# Protects: model instance lookup returns do not inherit model ownership.
# Detects: unrelated lookup results falsely blocked as deprecated model calls.
# Needs: real staged scanner; generic-class/model/plain direct-call counterparts.
# Breadcrumb: hooks/common/mandate_scan.py PydanticReceivers.value Subscript.
_qm_receiver_subscript_return_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls, path):\n        return "Parser"\n'
  _qm_receiver_case 'model instance lookup return is unresolved' \
    "${_qmr_types}class Holder(BaseModel):\n    def __getitem__(self, key):\n        return Parser\nresult = Holder()[0].parse_file('x')\n" 0 unknown
  _qm_receiver_case 'plain instance lookup return is unresolved' \
    "${_qmr_types}class Holder:\n    def __getitem__(self, key):\n        return Model\n    def parse_file(self, path):\n        return path\nHolder()[0].parse_file('x')\n" 0 unknown
  _qm_receiver_case 'annotated model instance lookup return is unresolved' \
    "${_qmr_types}class Holder(BaseModel):\n    def __getitem__(self, key):\n        return Parser\ndef load(holder: Holder):\n    return holder[0].parse_file('x')\n" 0 unknown
  _qm_receiver_case 'known generic model class subscription remains model' \
    "${_qmr_types}from typing import Generic, TypeVar\nT = TypeVar('T')\nclass GenericModel(BaseModel, Generic[T]):\n    pass\nGenericModel[int].parse_file('x')\n" 1 model
  _qm_receiver_case 'direct model instance retains known ancestry' \
    "${_qmr_types}Model().parse_file('x')\n" 1 model
  _qm_receiver_case 'direct plain parser remains plain' \
    "${_qmr_types}Parser().parse_file('x')\n" 0 plain
}

# Protects: captured callees, repeated headers and sequential binding targets.
# Detects: name-rebound constructors, stale loop/with proof and annotation classes.
# Needs: staged scanner; first-model, reverse-callee and ordinary-data controls.
# Breadcrumb: hooks/common/mandate_scan.py visit_Call/conservative_control/AnnAssign.
_qm_receiver_control_flow_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def __init__(self, marker=None):\n        self.marker = marker\n    def parse_file(self, path):\n        return path\n'
  _qmr_factory='class Factory:\n    def __call__(self):\n        return Model\n    def parse_file(self, path):\n        return path\n'
  _qm_receiver_case 'constructor preserves captured model callee' \
    "${_qmr_types}receiver = Model\nreceiver(marker=(receiver := Parser)).parse_file('m.json')\n" 1 model
  _qm_receiver_case 'constructor preserves captured plain callee' \
    "${_qmr_types}receiver = Parser\nreceiver(marker=(receiver := Model)).parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'while header accounts for next iteration rebind' \
    "${_qmr_types}receiver = Parser()\nwhile receiver.parse_file('m.json'):\n    receiver = Model\n" 0 unknown
  _qm_receiver_case 'while initial known model survives later parser rebind' \
    "${_qmr_types}receiver = Model\nwhile receiver.parse_file('m.json'):\n    receiver = Parser()\n" 1 model
  _qm_receiver_case 'while known model header survives ordinary data' \
    "${_qmr_types}while Model.parse_file('m.json'):\n    Model.label = 'data'\n" 1 model
  _qm_receiver_case 'while plain header survives ordinary data' \
    "${_qmr_types}receiver = Parser()\nwhile receiver.parse_file('notes.md'):\n    receiver.label = 'data'\n" 0 plain
  _qm_receiver_case 'later with item cannot use overwritten plain binding' \
    "${_qmr_types}from contextlib import nullcontext\nreceiver = Parser()\nwith nullcontext(Model) as receiver, nullcontext(receiver.parse_file('m.json')):\n    pass\n" 0 unknown
  _qm_receiver_case 'unrelated with target preserves plain receiver' \
    "${_qmr_types}from contextlib import nullcontext\nreceiver = Parser()\nwith nullcontext(Model) as other, nullcontext(receiver.parse_file('notes.md')):\n    pass\n" 0 plain
  _qm_receiver_case 'annotated callable instance return is unresolved' \
    "${_qmr_types}${_qmr_factory}factory: Factory = make_factory()\nfactory().parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'annotated plain direct method remains plain' \
    "${_qmr_types}${_qmr_factory}factory: Factory = make_factory()\nfactory.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'annotated model direct method remains model' \
    "${_qmr_types}model: Model = make_model()\nmodel.parse_file('m.json')\n" 1 model
}

# Protects: repeated comprehension bindings and captured RHS ownership.
# Detects: later iteration effects or assignment targets restoring stale proof.
# Needs: staged scanner; initial-model, eager/data/name-rebind/no-call controls.
# Breadcrumb: hooks/common/mandate_scan.py comprehension/visit_Assign.
_qm_receiver_iteration_target_contexts() {
  _qmr_types='from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self, path):\n        return path\n'
  _qmr_install='cache = {}\ndef install():\n    Parser.parse_file = Model.parse_file\n    return 0\n'
  _qm_receiver_case 'comprehension later iteration cannot retain plain receiver' \
    "${_qmr_types}receiver = Parser()\n[(receiver.parse_file('m.json'), (receiver := Model)) for item in range(2)]\n" 0 unknown
  _qm_receiver_case 'comprehension first model retains known violation' \
    "${_qmr_types}receiver = Model\n[(receiver.parse_file('m.json'), (receiver := Parser())) for item in range(2)]\n" 1 model
  _qm_receiver_case 'stable plain comprehension remains plain' \
    "${_qmr_types}receiver = Parser()\n[receiver.parse_file('notes.md') for item in range(2)]\n" 0 plain
  _qm_receiver_case 'eager plain-method iterator retains ownership' \
    "${_qmr_types}receiver = Parser()\n[receiver.parse_file('notes.md') for item in Parser().parse_file('items')]\n" 0 plain
  _qm_receiver_case 'per-iteration target call effects forfeit plain proof' \
    "${_qmr_types}receiver = Parser()\ndef update():\n    global receiver\n    receiver = Model\n    return 0\n[None for table[(receiver.parse_file('m.json'), update())] in range(2)]\n" 0 unknown
  _qm_receiver_case 'target mutation cannot restore captured RHS proof' \
    "${_qmr_types}${_qmr_install}cache[install()] = receiver = Parser()\nreceiver.parse_file('m.json')\n" 0 unknown
  _qm_receiver_case 'ordinary target data write preserves captured RHS' \
    "${_qmr_types}cache = {}\ndef store():\n    Parser.label = 'notes'\n    return 0\ncache[store()] = receiver = Parser()\nreceiver.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'target name rebinding preserves captured object' \
    "${_qmr_types}cache = {}\ndef rename():\n    global Parser\n    Parser = Model\n    return 0\ncache[rename()] = receiver = Parser()\nreceiver.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'plain target mutation preserves captured model type' \
    "${_qmr_types}${_qmr_install}cache[install()] = receiver = Model()\nreceiver.parse_file('m.json')\n" 1 model
  _qm_receiver_case 'uncalled target mutator preserves captured RHS' \
    "${_qmr_types}${_qmr_install}cache[0] = receiver = Parser()\nreceiver.parse_file('notes.md')\n" 0 plain
  _qm_receiver_case 'later target mutation invalidates already assigned receiver' \
    "${_qmr_types}${_qmr_install}receiver = cache[install()] = Parser()\nreceiver.parse_file('m.json')\n" 0 unknown
}

t_case_quality_mandate() {
  t_begin "32 quality mandate: changed lines, rules, suppressions, debt register"
  log="$(gg_tmp_log)"

  if ! gg_has_python; then
    t_skip "quality mandate: no Python interpreter (the scanner needs python3)"
    return 0
  fi

  # ---- key inventory: one source of truth, three places ----------------------
  _qm_rules="$(sh "$_QM_SCAN" --list-rules | cut -f1 | sort | tr '\n' ' ')"
  _qm_conf="$(sed -n 's/^mandate\.\([a-z0-9_]*\)=.*/\1/p' "$GG_ROOT/hooks/common/qa-gate.conf" \
    | grep -vxE 'enabled|vendored' | sort | tr '\n' ' ')"
  # shellcheck disable=SC2016  # the sed pattern matches a literal "$QA_KNOWN_KEYS"
  _qm_known="$(sed -n 's/^QA_KNOWN_KEYS="\$QA_KNOWN_KEYS \(.*\)"$/\1/p' "$GG_ROOT/hooks/common/qa_gate.sh" \
    | tr ' ' '\n' | sed -n 's/^mandate\.//p' | grep -vxE 'enabled|vendored' | sort | tr '\n' ' ')"
  if [ -n "$_qm_rules" ] && [ "$_qm_rules" = "$_qm_conf" ] && [ "$_qm_rules" = "$_qm_known" ]; then
    t_ok "RULES, qa-gate.conf and QA_KNOWN_KEYS name the same mandate keys"
  else
    t_fail "mandate key drift: RULES='$_qm_rules' conf='$_qm_conf' known='$_qm_known'"
  fi
  _qm_defaults_rules="$(sh "$_QM_SCAN" --list-rules | cut -f1,2 | tr '\t' '=' | sort | tr '\n' ' ')"
  _qm_defaults_conf="$(sed -n 's/^mandate\.\([a-z0-9_]*\)=\([a-z]*\).*/\1=\2/p' \
    "$GG_ROOT/hooks/common/qa-gate.conf" | grep -v '^enabled=' | sort | tr '\n' ' ')"
  if [ "$_qm_defaults_rules" = "$_qm_defaults_conf" ]; then
    t_ok "qa-gate.conf defaults match the scanner's built-in defaults"
  else
    t_fail "default drift: RULES='$_qm_defaults_rules' conf='$_qm_defaults_conf'"
  fi

  if ! gg_has_ruff || ! gg_has_astgrep; then
    t_skip "quality mandate scans: need ruff and a genuine ast-grep (ruff=$(gg_has_ruff && echo y || echo n))"
    return 0
  fi

  # Protects: valid open-text commands and classification predicates stay usable.
  # Detects: name/return-shape heuristics silently promoted to account-wide vetoes.
  # Needs: genuine ast-grep/ruff above; isolated index, range and actual hook calls.
  # Breadcrumb: hooks/common/qa-gate.conf and mandate_scan.py RULES; agent-hooks#11.
  r="$(_qm_repo)"
  _qm_put "$r" README.md 'classifier fixture\n'
  _qm_commit "$r" "classification base"
  _qm_advisory_base="$(git -C "$r" rev-parse HEAD)"
  _qm_classifier='import shlex\n\n\ndef is_classifiable(command: str) -> bool:\n    """An unmatched quote means unclassified, not an operational failure."""\n    try:\n        shlex.split(command, posix=True)\n    except ValueError:\n        return False\n    return True\n'
  _qm_put "$r" src/classify.py "$_qm_classifier"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "default staged heuristics allow open command text and an intentional False predicate"
  _qm_has "$log" "WARN [except_sentinel]" "default sentinel heuristic remains visible as a warning"
  _qm_has "$log" "WARN [str_enum_param]" "default parameter-name heuristic remains visible as a warning"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "actual pre-commit permits the valid classifier under packaged defaults"
  _qm_has "$log" "WARN [except_sentinel]" "pre-commit retains the predicate advisory"
  _qm_has "$log" "WARN [str_enum_param]" "pre-commit retains the open-text advisory"
  for _qm_level in changed block; do
    for _qm_rule in except_sentinel str_enum_param; do
      _qm_conf "$r" "mandate.$_qm_rule=$_qm_level\n"
      _qm_scan "$r" "$log" --staged; rc=$?
      t_expect_rc 1 "$rc" "explicit staged $_qm_rule=$_qm_level still enforces the selected heuristic"
      _qm_has "$log" "BLOCK [$_qm_rule]" "the staged opt-in names $_qm_rule"
    done
  done
  _qm_conf "$r" ''
  _qm_commit "$r" "valid classifier under default advisory policy"
  _qm_scan "$r" "$log" --range "$_qm_advisory_base..HEAD"; rc=$?
  t_expect_rc 0 "$rc" "default range heuristics allow the same valid classifier"
  _qm_has "$log" "WARN [except_sentinel]" "range sentinel heuristic remains visible"
  _qm_has "$log" "WARN [str_enum_param]" "range open-text heuristic remains visible"
  for _qm_level in changed block; do
    for _qm_rule in except_sentinel str_enum_param; do
      _qm_conf "$r" "mandate.$_qm_rule=$_qm_level\n"
      _qm_commit "$r" "explicit range $_qm_rule=$_qm_level"
      _qm_scan "$r" "$log" --range "$_qm_advisory_base..HEAD"; rc=$?
      t_expect_rc 1 "$rc" "explicit range $_qm_rule=$_qm_level still enforces the selected heuristic"
      _qm_has "$log" "BLOCK [$_qm_rule]" "the range opt-in names $_qm_rule"
    done
  done
  _qm_conf "$r" ''
  _qm_put "$r" src/failure.py 'def catches_control_flow() -> bool:\n    try:\n        return True\n    except:\n        return False\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an unrelated actual bare-except violation still blocks with advisory defaults"
  _qm_has "$log" "BLOCK [bare_except]" "the positive blocking control retains its own rule"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 1 "$rc" "actual pre-commit still rejects the unrelated bare-except violation"
  gg_rmrepo "$r"

  # Protects: upgrading these defaults cannot replace a false veto with STALE.
  # Detects: legacy ceilings re-imposing a now-advisory rule at real pre-push.
  # Needs: a genuine old-policy baseline and snapshot policy; same scanners above.
  # Breadcrumb: mandate_scan.py check_baseline/evaluate_baseline; config defaults.
  r="$(_qm_repo)"
  _qm_put "$r" src/classify.py "$_qm_classifier"
  _qm_conf "$r" 'mandate.except_sentinel=changed\nmandate.str_enum_param=changed\n'
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "a legacy strict-policy baseline is generated by the real scanner"
  _qm_commit "$r" "legacy strict heuristic baseline"
  _qm_legacy_base="$(git -C "$r" rev-parse HEAD)"
  _qm_conf "$r" ''
  _qm_commit "$r" "adopt advisory defaults without rewriting legacy ceilings"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 0 "$rc" "legacy ceilings for the two WARN heuristics are advisory"
  _qm_has "$log" "WARN legacy baseline [except_sentinel]" "legacy predicate ceiling is reported honestly"
  _qm_has "$log" "WARN legacy baseline [str_enum_param]" "legacy command ceiling is reported honestly"
  _qm_tip="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_legacy_base" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "actual pre-push accepts the default-WARN legacy-baseline migration"
  _qm_put "$r" src/second.py "$_qm_classifier"
  _qm_commit "$r" "another valid classifier under advisory defaults"
  for _qm_level in changed block; do
    for _qm_rule in except_sentinel str_enum_param; do
      _qm_parent="$(git -C "$r" rev-parse HEAD)"
      _qm_conf "$r" "mandate.$_qm_rule=$_qm_level\n"
      _qm_commit "$r" "restore strict ratchet $_qm_rule=$_qm_level"
      _qm_scan "$r" "$log" --check-baseline; rc=$?
      t_expect_rc 1 "$rc" "explicit $_qm_rule=$_qm_level retains its legacy ratchet"
      _qm_has "$log" "BLOCK REGRESSION $_qm_rule" "the strict baseline names its actual new finding"
      _qm_tip="$(git -C "$r" rev-parse HEAD)"
      printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_parent" > "$GG_T_TMPROOT/qm-refs"
      _qm_push "$r" "$log"; rc=$?
      t_expect_rc 1 "$rc" "actual pre-push preserves the explicit $_qm_rule=$_qm_level ratchet"
    done
  done
  _qm_conf "$r" ''
  _qm_put "$r" src/second.py '\n'
  _qm_commit "$r" "restore valid advisory source"
  for _qm_negative in literal_enum unknown_rule malformed; do
    case "$_qm_negative" in
      literal_enum) _qm_register='{"version":1,"policy_revision":"git-guard-mandate-1","measured_at_commit":"fixture","rules":{"literal_enum":{"src/classify.py":1}}}'; _qm_problem=STALE ;;
      unknown_rule) _qm_register='{"version":1,"policy_revision":"git-guard-mandate-1","measured_at_commit":"fixture","rules":{"unknown_rule":{}}}'; _qm_problem=STALE ;;
      malformed) _qm_register='{"version":1,"policy_revision":"git-guard-mandate-1","measured_at_commit":"fixture","rules":{"except_sentinel":{"src/classify.py":0}}}'; _qm_problem=MALFORMED ;;
    esac
    _qm_parent="$(git -C "$r" rev-parse HEAD)"
    _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register\n"
    _qm_commit "$r" "negative legacy migration $_qm_negative"
    _qm_tip="$(git -C "$r" rev-parse HEAD)"
    printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_parent" > "$GG_T_TMPROOT/qm-refs"
    _qm_push "$r" "$log"; rc=$?
    t_expect_rc 1 "$rc" "actual pre-push still rejects unrelated $_qm_negative register state"
    _qm_has "$log" "BLOCK $_qm_problem" "the $_qm_negative control retains its original $_qm_problem failure"
  done
  gg_rmrepo "$r"

  # ---- changed lines: new swallow blocks, old debt does not -------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_SWALLOW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a staged new 'except Exception: pass' blocks"
  _qm_has "$log" "[except_pass]" "the block names the except_pass rule"
  _qm_has "$log" "fix:" "the block says how to fix it"
  _qm_has "$log" "SAFETY: <why this is correct>" "the block says how to record justified debt"
  _qm_has "$log" "git-guard mandate: BLOCKED" "the run ends in a determined BLOCKED summary"
  _qm_commit "$r" "debt"
  printf '%b' "$_QM_CLEAN" >> "$r/src/app.py"
  ( cd "$r" && git add src/app.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "pre-existing debt in a touched file + a clean added line passes"
  _qm_has "$log" "git-guard mandate: PASSED" "the pass is stated, not silent"
  gg_rmrepo "$r"

  # Actual Audio #118/main 04765ec: registry merges inherited widgets.py:83
  # Mapping[str, Any]. Protects: merge resolutions are new only versus ALL
  # parents; Detects: main-side debt falsely blocks an unrelated merge, or a
  # last-merge filter hides earlier unpublished branch debt in --range.
  # Needs: Git, ruff, ast-grep; Breadcrumb: mandate_scan.py staged_changes/range_changes.
  r="$(_qm_repo)"
  _qm_put "$r" widgets.py 'def guidance_html(data: str) -> str:\n    return str(data)\n'
  _qm_commit "$r" "clean merge base"
  _qm_merge_base="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && git checkout -qb topic )
  _qm_put "$r" registry.txt 'registry-only topic change\n'
  _qm_put "$r" topic.py "$_QM_NARROW"
  _qm_commit "$r" "unpublished topic debt before merge"
  ( cd "$r" && git checkout -qb main-side "$_qm_merge_base" )
  _qm_audio_main='from typing import Any, Mapping\n\ndef guidance_html(data: Mapping[str, Any], *, include_heading: bool = True) -> str:\n    return str(data)\n'
  _qm_put "$r" widgets.py "$_qm_audio_main"
  _qm_commit "$r" "Audio main-side Mapping[str, Any]"
  ( cd "$r" && git checkout -q topic && \
    git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" merge --no-ff --no-commit main-side ) >"$log" 2>&1
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "an Audio main-side Any inherited by a staged registry merge passes"
  printf '%b' "\n$_QM_NARROW" >> "$r/widgets.py"
  ( cd "$r" && git add widgets.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a genuinely new merge-resolution swallow still blocks"
  _qm_has "$log" "[except_pass]" "the merge resolution retains its new except_pass finding"
  _qm_put "$r" widgets.py "$_qm_audio_main"
  _qm_commit "$r" "merge main without new resolution debt"
  _qm_scan "$r" "$log" --range "$_qm_merge_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "a last merge cannot hide earlier unpublished branch debt from range scanning"
  _qm_has "$log" "topic.py" "the range still scans the earlier unpublished topic file"
  _qm_has "$log" "[except_pass]" "the earlier unpublished swallow remains blocked in the range"
  gg_rmrepo "$r"

  # PR #72 actual review: inter-hunk context joined clean edits across old debt.
  r="$(_qm_repo)"
  _qm_put "$r" app.py 'value = 1\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        pass\n\nvalue2 = 1\n'
  _qm_commit "$r" "existing debt between clean edits"
  _qm_put "$r" app.py 'value = 2\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        pass\n\nvalue2 = 2\n'
  ( cd "$r" && git config diff.interHunkContext 20 )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "inter-hunk context cannot turn unchanged debt into staged findings"
  gg_rmrepo "$r"

  # PR #72 actual review: Git LF rows and Ruff CR rows disagreed and passed debt.
  r="$(_qm_repo)"
  ( cd "$r" && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit --allow-empty -qm "base" )
  _qm_cr_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" app.py 'import subprocess\rsubprocess.run(["false"])\r'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "lone-CR staged source is a tool error, never a clean scan"
  _qm_has "$log" "lone CR line endings" "the staged error explains ambiguous line coordinates"
  _qm_commit "$r" "CR source"
  _qm_scan "$r" "$log" --range "$_qm_cr_base..HEAD"; rc=$?
  t_expect_rc 2 "$rc" "lone-CR range source is a tool error, never a clean scan"
  _qm_has "$log" "lone CR line endings" "the range error explains ambiguous line coordinates"
  gg_rmrepo "$r"

  # Pure renames have no +++ header, but their destinations still need BLOCK rules.
  r="$(_qm_repo)"
  _qm_put "$r" legacy.txt 'from pydantic.v1 import BaseModel\n'
  _qm_put "$r" literal.txt 'from typing import Literal\n\n\ndef f(c: Literal["a", "b"]) -> None:\n    print(c)\n'
  _qm_commit "$r" "non-source inputs"
  _qm_rename_base="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && git mv legacy.txt app.py && git mv literal.txt literal.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a pure staged rename into Python still enforces whole-file BLOCK rules"
  _qm_lacks "$log" "[literal_enum]" "a pure rename adds no lines to warn on"
  _qm_commit "$r" "source renames"
  _qm_scan "$r" "$log" --range "$_qm_rename_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "a pure range rename into Python still enforces whole-file BLOCK rules"
  gg_rmrepo "$r"

  # ---- line mapping is exact on line 1 (ast-grep 0-based vs git 1-based) -------
  r="$(_qm_repo)"
  _qm_put "$r" src/types_.py 'from typing import Optional\n\n\ndef f(x: Optional[int]) -> int:\n    return x or 0\n'
  _qm_commit "$r" "base"
  _qm_put "$r" src/types_.py 'from typing import Any, Optional\n\n\ndef f(x: Optional[int]) -> int:\n    return x or 0\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an Any import introduced on line 1 is caught on line 1"
  _qm_has "$log" "src/types_.py:1 " "the finding is reported at line 1, not 0 or 2"
  gg_rmrepo "$r"

  # An added "++ 1" is valid Python but its diff line starts "+++ ". It must
  # not redirect a later hunk's finding to a made-up path (PR #72 review 6200036532).
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py 'value = 1\n\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        raise\n'
  _qm_commit "$r" "header-like source base"
  _qm_header_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py '++ 1\nvalue = 1\n\n\ndef probe():\n    try:\n        connect()\n    except OSError:\n        pass\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "header-like added source does not hide a later staged violation"
  _qm_has "$log" "[except_pass]" "the staged later hunk retains its except_pass finding"
  _qm_commit "$r" "header-like source with later violation"
  _qm_scan "$r" "$log" --range "$_qm_header_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "header-like added source does not hide a later range violation"
  _qm_has "$log" "[except_pass]" "the range later hunk retains its except_pass finding"
  gg_rmrepo "$r"

  # ---- pydantic v1: blocks, including in test files ----------------------------
  r="$(_qm_repo)"
  # Exercise changed-line policy: BLOCK would find the violation regardless of hunks.
  _qm_conf "$r" 'mandate.pydantic_v1=changed\n'
  # Git records are LF-delimited; a source U+2028 must not reset the later hunk.
  _qm_model_path='vendor\model.py'
  if gg_is_windows; then _qm_model_path="vendor model café's.py"; fi
  _qm_put "$r" "$_qm_model_path" 'marker = "old"\n\nfrom pydantic import BaseModel\n'
  _qm_commit "$r" "clean pydantic fixture"
  _qm_put "$r" "$_qm_model_path" 'marker = "prefix diff --git a/fake b/fake"\n\nfrom pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "'from pydantic.v1 import BaseModel' blocks"
  _qm_has "$log" "[pydantic_v1]" "the block names pydantic_v1"
  gg_rmrepo "$r"
  # PR #72 actual review: this tracked filename was parsed as an ast-grep option.
  r="$(_qm_repo)"
  ( cd "$r" && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit --allow-empty -qm "base" )
  _qm_option_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" './--globs=!*.py' 'from pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an option-shaped filename cannot hide staged pydantic v1"
  _qm_has "$log" "[pydantic_v1]" "the option-shaped staged file retains its finding"
  ( cd "$r" && sh "$_QM_SCAN" --all ) >"$log.json" 2>"$log"
  "$(gg_python)" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["totals"]["pydantic_v1"] != 1)' "$log.json"; rc=$?
  t_expect_rc 0 "$rc" "whole-tree counts retain pydantic v1 in the option-shaped file"
  _qm_commit "$r" "option-shaped source"
  _qm_scan "$r" "$log" --range "$_qm_option_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "an option-shaped filename cannot hide range pydantic v1"
  _qm_has "$log" "[pydantic_v1]" "the option-shaped range file retains its finding"
  gg_rmrepo "$r"
  # PR #72 actual review: both scanners silently skipped valid Latin-1 Python.
  r="$(_qm_repo)"
  ( cd "$r" && git -c core.hooksPath="$GG_T_TMPROOT/qm-no-hooks" commit --allow-empty -qm "base" )
  _qm_scan "$r" "$log" --write-baseline
  _qm_commit "$r" "clean encoding baseline"
  _qm_encoding_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" app.py '# coding: latin-1\n# \351\nfrom pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 staged source is a tool error, never a clean scan"
  _qm_has "$log" "is not UTF-8" "the source error names the required conversion"
  _qm_scan "$r" "$log" --all; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 census cannot report falsely clean counts"
  _qm_scan "$r" "$log" --write-baseline; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 source cannot create a falsely clean baseline"
  _qm_commit "$r" "Latin-1 source"
  _qm_scan "$r" "$log" --range "$_qm_encoding_base..HEAD"; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 range source is a tool error, never a clean scan"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 2 "$rc" "Latin-1 source cannot pass a falsely clean baseline"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" tests/test_model.py 'from pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "pydantic v1 in a test file still blocks (tests are not exempt)"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" src/model.py 'from pydantic import BaseModel, ConfigDict\n\n\nclass M(BaseModel):\n    model_config = ConfigDict(extra="forbid")\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a v2 model with model_config passes"
  gg_rmrepo "$r"

  # ---- no explicit Any; test files exempt ---------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/f.py 'from typing import Any\n\n\ndef f(x: Any) -> None:\n    print(x)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an added 'def f(x: Any) -> None' blocks"
  _qm_has "$log" "[no_any]" "the block names no_any"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" tests/test_f.py 'from typing import Any\n\n\ndef f(x: Any) -> None:\n    print(x)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "explicit Any in tests/ is exempt"
  gg_rmrepo "$r"

  # ---- vendored trees are exempt entirely ---------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" vendor/lib/app.py "$_QM_SWALLOW"
  _qm_put "$r" external_systems/x/app.py "$_QM_SWALLOW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "vendor/ and external*/ are exempt"
  _qm_put "$r" qobi/chumpy/ch.py "$_QM_SWALLOW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "control: an undeclared third-party tree is scanned"
  _qm_conf "$r" 'mandate.vendored=qobi/chumpy\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.vendored=qobi/chumpy exempts the declared tree"
  _qm_conf "$r" 'mandate.vendored=../outside\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "a mandate.vendored entry escaping the repo is a config TOOL ERROR"
  gg_rmrepo "$r"

  # ---- suppressions need a reason ----------------------------------------------
  r="$(_qm_repo)"
  # Preserve physical lines after U+2028 so a later changed suppression cannot vanish.
  _qm_put "$r" src/s.py 'import subprocess\n\nprint(1)\n'
  _qm_commit "$r" "clean suppression fixture"
  _qm_put "$r" src/s.py '# note x\nimport subprocess\nsubprocess.run(["true"])  # noqa: PLW1510\n\nprint(1)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "'# noqa: PLW1510' with no SAFETY reason blocks"
  _qm_has "$log" "[suppression_reason]" "the block names suppression_reason"
  _qm_lacks "$log" "[unchecked_subprocess]" "the noqa itself still suppresses PLW1510"
  _qm_put "$r" src/s.py '# note x\nimport subprocess\nsubprocess.run(["true"])  # noqa: PLW1510  # SAFETY: best-effort child status is intentionally ignored\n\nprint(1)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "the same noqa with '# SAFETY: <reason>' passes"
  _qm_put "$r" src/s.py '# ruff: noqa: E722\n\ndef probe():\n    try:\n        connect()\n    except:\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a file-level Ruff suppression without a reason blocks"
  ( cd "$r" && sh "$_QM_SCAN" --all ) >"$log.json" 2>"$log"
  "$(gg_python)" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["totals"]["suppression_reason"] != 1)' "$log.json"; rc=$?
  t_expect_rc 0 "$rc" "whole-tree counts retain the unjustified file-level suppression"
  _qm_put "$r" src/s.py '# ruff: noqa: E722  # SAFETY: all exceptions are immediately re-raised\n\ndef probe():\n    try:\n        connect()\n    except:\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a justified file-level Ruff suppression still passes"
  _qm_put "$r" src/s.py '# ruff: noqa: E722  # best-effort: all exceptions are immediately re-raised\n\ndef probe():\n    try:\n        connect()\n    except:\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a file-level Ruff suppression accepts the existing best-effort reason"
  _qm_put "$r" src/s.py '# ruff: noqa: PGH004\n\ndef probe():\n    try:\n        connect()\n    except:  # noqa\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a file-level PGH004 suppression cannot hide a blanket noqa"
  ( cd "$r" && sh "$_QM_SCAN" --all ) >"$log.json" 2>"$log"
  "$(gg_python)" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["totals"]["suppression_reason"] != 1)' "$log.json"; rc=$?
  t_expect_rc 0 "$rc" "whole-tree counts retain an attempted suppression of the suppression guard"
  _qm_put "$r" src/s.py '# ruff: noqa: PGH004  # SAFETY: reviewed suppression\n\ndef probe():\n    try:\n        connect()\n    except:  # noqa\n        raise\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a reason cannot make the suppression guard self-suppressible"
  _qm_put "$r" src/s.py 'def probe():\n    try:\n        connect()\n    except OSError:  # ast-grep-ignore: mandate-except-pass  # SAFETY: optional probe\n        pass\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a same-line ast-grep-ignore with a reason suppresses on every ast-grep version"
  # Only comments count: a string that MENTIONS a suppression neither needs a
  # reason nor suppresses anything (found by running the gate on mandate_scan.py).
  _qm_put "$r" src/s.py 'HELP = "write # noqa: BLE001 or ast-grep-ignore on the line"\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "a string literal mentioning '# noqa: BLE001' is not a suppression"
  _qm_put "$r" src/s.py 'def probe():\n    try:\n        connect()\n    except OSError:\n        x = "ast-grep-ignore: mandate-except-pass"\n        pass\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an ast-grep-ignore inside a string does not suppress a finding"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic\nfn probe() { panic!("failed"); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a Rust-only mandate suppression without a reason blocks"
  _qm_has "$log" "[suppression_reason]" "the Rust-only block names suppression_reason"
  _qm_put "$r" src/lib.rs '// ast-grep-ignore: mandate-rust-panic  # SAFETY: fixture exercises a deliberate panic\nfn probe() { panic!("failed"); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "the same Rust-only suppression with a reason passes"
  gg_rmrepo "$r"

  # ---- per-rule severity ---------------------------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/n.py "$_QM_NARROW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "control: a narrow except-pass blocks at the default severity"
  _qm_conf "$r" 'mandate.except_pass=off\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.except_pass=off lets it through"
  _qm_conf "$r" 'mandate.except_pass=warn\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.except_pass=warn does not block"
  _qm_has "$log" "WARN [except_pass]" "warn still reports the finding"
  _qm_conf "$r" 'mandate.except_pass=sometimes\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "an unknown severity value is a TOOL ERROR, not a default"
  _qm_has "$log" "mandate.except_pass=sometimes is not one of" "the error names the bad value"
  _qm_conf "$r" 'mandate.enabled=off\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "mandate.enabled=off switches the layer off"
  gg_rmrepo "$r"

  # ---- whole-file `block` reaches old debt; `changed` does not -----------------
  r="$(_qm_repo)"
  _qm_put "$r" src/old.py "$_QM_NARROW"
  _qm_commit "$r" "debt"
  printf '%b' "$_QM_CLEAN" >> "$r/src/old.py"
  ( cd "$r" && git add src/old.py )
  _qm_conf "$r" 'mandate.except_pass=block\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "mandate.except_pass=block refuses old debt anywhere in a staged file"
  gg_rmrepo "$r"

  # ---- Rust panics: production blocks, test code passes ------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap()\n}\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an added .unwrap() in non-test Rust blocks"
  _qm_has "$log" "[rust_panic]" "the block names rust_panic"
  _qm_put "$r" src/lib.rs 'pub fn f(x: Option<u8>) -> u8 {\n    x.unwrap_or(0)\n}\n\n#[cfg(test)]\n#[allow(dead_code)]\nmod tests {\n    fn helper() { Some(1).unwrap(); }\n}\n'
  _qm_put "$r" tests/it.rs 'fn t() { Some(1).unwrap(); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" ".unwrap() inside stacked #[cfg(test)] attributes and under tests/ passes"
  _qm_put "$r" src/lib.rs '#[test]\n#[ignore]\nfn t() { Some(1).unwrap(); }\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" ".unwrap() inside stacked #[test] attributes passes"
  printf '%b' '\npub fn production() { Some(1).unwrap(); }\n' >> "$r/src/lib.rs"
  ( cd "$r" && git add src/lib.rs )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a preceding test attribute does not exempt the next production item"
  gg_rmrepo "$r"

  # Actual review #72: untracked attributes must not smudge scanned source.
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  _qm_commit "$r" "clean source"
  _qm_scan "$r" "$log" --write-baseline
  _qm_commit "$r" "clean baseline"
  _qm_before_diff="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "raw staged source contains the except-pass before attributes"
  printf '*.py -diff\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "untracked binary attributes cannot hide a staged source finding"
  _qm_smudge="$GG_T_TMPROOT/qm-smudge"
  printf '#!/bin/sh\ncat >/dev/null\nprintf "value = 1\\n"\n' > "$_qm_smudge"
  chmod +x "$_qm_smudge"
  ( cd "$r" && git config filter.qm-smudge.clean cat && git config filter.qm-smudge.smudge "$_qm_smudge" )
  printf '*.py filter=qm-smudge\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "untracked checkout attributes cannot hide a staged except-pass"
  rm "$r/.gitattributes"
  _qm_commit "$r" "source regression"
  printf '*.py -diff\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --range "$_qm_before_diff..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "untracked binary attributes cannot hide a range source finding"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "raw committed source exceeds its baseline before attributes"
  printf '*.py filter=qm-smudge\n' > "$r/.gitattributes"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "untracked checkout attributes cannot hide committed baseline regression"
  gg_rmrepo "$r"

  # ---- warn-level rule (Literal-as-enum) reports and passes --------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/l.py 'from typing import Literal\n\n\ndef f(c: Literal["a", "b"]) -> None:\n    print(c)\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "Literal[\"a\", \"b\"] warns by default, does not block"
  _qm_has "$log" "WARN [literal_enum]" "the Literal enum warning is printed"
  gg_rmrepo "$r"

  # ---- tool failures fail closed; a missing tool warns -------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  mkdir -p "$r/.venv/bin"   # after staging; POSIX also exercises repo-venv precedence
  _qm_ruff="$r/.venv/bin/ruff"
  _qm_ruff_path="$PATH"
  if gg_is_windows; then
    # Native resolution requires .cmd; use supported PATH discovery rather than
    # pretending an extensionless shell file is a Windows executable.
    _qm_ruff="$r/.venv/bin/ruff-payload"
    _qm_ruff_path="$(_qm_path_dir "$r/.venv/bin"):$PATH"
  fi
  GG_QM_MARKER="$GG_T_TMPROOT/qm-tool-invocations"
  export GG_QM_MARKER
  : > "$GG_QM_MARKER"
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_ruff" '#!/bin/sh\nprintf "ruff-exit2\\n" >> "$GG_QM_MARKER"\necho "error: injected selector failure" >&2\nexit 2\n'
  if gg_is_windows; then cp "$_qm_ruff.cmd" "$r/.venv/bin/ruff.cmd"; fi
  PATH="$_qm_ruff_path" _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "ruff exit 2 is a TOOL ERROR that blocks"
  _qm_has "$log" "TOOL ERROR [ruff]" "the TOOL ERROR names ruff"
  _qm_has "$log" "injected selector failure" "the TOOL ERROR carries ruff's stderr"
  _qm_has "$GG_QM_MARKER" "ruff-exit2" "the injected exit-2 payload actually ran"
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_ruff" '#!/bin/sh\nprintf "ruff-json\\n" >> "$GG_QM_MARKER"\necho "this is not json"\nexit 1\n'
  if gg_is_windows; then cp "$_qm_ruff.cmd" "$r/.venv/bin/ruff.cmd"; fi
  PATH="$_qm_ruff_path" _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 2 "$rc" "unparseable ruff output is a TOOL ERROR, never zero findings"
  _qm_has "$log" "unparseable JSON" "the TOOL ERROR says the output could not be parsed"
  _qm_has "$GG_QM_MARKER" "ruff-json" "the malformed-JSON payload actually ran"
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_ruff" '#!/bin/sh\nprintf "ruff-timeout\\n" >> "$GG_QM_MARKER"\nsleep 30\n'
  if gg_is_windows; then cp "$_qm_ruff.cmd" "$r/.venv/bin/ruff.cmd"; fi
  ( cd "$r" && GIT_GUARD_MANDATE_TIMEOUT=2 PATH="$_qm_ruff_path" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 2 "$rc" "a scanner that hangs past GIT_GUARD_MANDATE_TIMEOUT is a TOOL ERROR"
  _qm_has "$log" "did not finish within 2s" "the TOOL ERROR says the scanner hung"
  _qm_has "$GG_QM_MARKER" "ruff-timeout" "the hanging payload started before the timeout"
  rm -rf "$r/.venv"
  _qm_bin="$(_qm_path_dir "$GG_T_TMPROOT/qm-noruff-bin")"
  _qm_min_bin "$_qm_bin" sh git dirname env ast-grep sort tr
  # The base installation's interpreter, not a shim or relocated copy that needs PATH
  # to start (gg_python_exe).
  _qm_p="$(gg_python_exe 2>/dev/null)" &&
    _qm_forward "$_qm_bin/python3" "$_qm_p"
  ( PATH="$_qm_bin" python3 -I -c 'import shutil; assert shutil.which("ruff") is None' ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 0 "$rc" "the restricted interpreter runs and cannot discover ruff"
  ( cd "$r" && VIRTUAL_ENV='' PATH="$_qm_bin" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 0 "$rc" "ruff not installed warns and does not block"
  _qm_has "$log" "ruff is not installed, so these rules were NOT evaluated" \
    "the warning names the unevaluated rules"
  # A python3 that is on PATH but cannot start (an unconfigured version-manager
  # shim) must read as "no interpreter", not as BLOCKED or TOOL ERROR.
  _qm_shim="$(_qm_path_dir "$GG_T_TMPROOT/qm-shim-bin")"
  _qm_min_bin "$_qm_shim" sh git dirname
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_shim/python3" '#!/bin/sh\nprintf "python-shim\\n" >> "$GG_QM_MARKER"\necho "shim ERROR No version is set" >&2\nexit 1\n'
  ( cd "$r" && PATH="$_qm_shim" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 0 "$rc" "a python3 shim that cannot start warns and does not block"
  _qm_has "$log" "quality mandate was NOT evaluated" "the warning says the mandate did not run"
  _qm_has "$GG_QM_MARKER" "python-shim" "the deliberately unconfigured interpreter shim actually ran"
  gg_rmrepo "$r"

  # ---- debt register -----------------------------------------------------------
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_scan "$r" "$log" --write-baseline; rc=$?
  t_expect_rc 0 "$rc" "--write-baseline records the existing debt"
  _qm_commit "$r" "baseline"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 0 "$rc" "the register holds at the commit it was written for"
  _qm_has "$log" "debt register holds" "the hold is stated"
  printf '%b' "\n\ndef second():\n    try:\n        connect()\n    except OSError:\n        pass\n" >> "$r/src/app.py"
  _qm_commit "$r" "regress"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "a file whose count rose blocks (REGRESSION)"
  _qm_has "$log" "REGRESSION except_pass src/app.py: 2 finding(s), ceiling 1" "REGRESSION names rule, file and counts"
  printf '%b' "def probe():\n    return 1\n" > "$r/src/app.py"
  _qm_commit "$r" "fixed but not ratcheted"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "a count that fell without lowering the ceiling blocks (UNRATCHETED)"
  _qm_has "$log" 'delete rules.except_pass["src/app.py"]' "UNRATCHETED gives the exact JSON edit"
  # pre-push hook: the same register is enforced for a pushed commit.
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    0000000000000000000000000000000000000000 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "hooks/pre-push refuses a commit whose register does not hold"
  _qm_has "$log" "debt register does not hold" "pre-push says why"
  _qm_before_ratchet="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >/dev/null 2>&1
  _qm_commit "$r" "ratchet"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    "$_qm_before_ratchet" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "the ratchet commit passes when earlier debt is already remote"
  _qm_fault_bin="$(_qm_path_dir "$GG_T_TMPROOT/qm-buffer-fault")"
  mkdir -p "$_qm_fault_bin"
  # shellcheck disable=SC2016  # marker expands in the injected child
  printf '#!/bin/sh\nprintf "mktemp-fault\\n" >> "$GG_QM_MARKER"\nexit 1\n' > "$_qm_fault_bin/mktemp"
  chmod +x "$_qm_fault_bin/mktemp"
  PATH="$_qm_fault_bin:$PATH" _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "failed mandatory ref-buffer creation refuses the push"
  _qm_has "$GG_QM_MARKER" "mktemp-fault" "the pre-push scratch allocation fault actually ran"
  rm "$_qm_fault_bin/mktemp"
  # shellcheck disable=SC2016  # marker expands in the injected child
  printf '#!/bin/sh\nprintf "cat-fault\\n" >> "$GG_QM_MARKER"\nexit 1\n' > "$_qm_fault_bin/cat"
  chmod +x "$_qm_fault_bin/cat"
  PATH="$_qm_fault_bin:$PATH" _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "failed ref-buffer write refuses the push"
  _qm_has "$GG_QM_MARKER" "cat-fault" "the pre-push ref capture fault actually ran"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json '{"version": 1, "rules": []}\n'
  _qm_commit "$r" "malformed"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "a malformed register blocks"
  _qm_has "$log" "MALFORMED" "the block says MALFORMED"
  _qm_put "$r" .git-guard/mandate-baseline.json '{"version": 1, "policy_revision": "git-guard-mandate-1", "measured_at_commit": "x", "rules": {"literal_enum": {"src/app.py": 1}}}\n'
  _qm_commit "$r" "undeclared + stale"
  _qm_scan "$r" "$log" --check-baseline; rc=$?
  t_expect_rc 1 "$rc" "undeclared findings and a stale entry block"
  _qm_has "$log" "UNDECLARED except_pass" "a rule with findings and no entry is UNDECLARED"
  _qm_has "$log" "STALE rules.literal_enum" "an entry for a non-enforced rule is STALE"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  _qm_commit "$r" "no register"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    0000000000000000000000000000000000000000 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "a repo with no register pushes as before"
  _qm_lacks "$log" "git-guard mandate" "and the mandate prints nothing for it"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$r" rev-parse HEAD)" \
    1111111111111111111111111111111111111111 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "a no-register force push needs no local copy of the remote commit"
  _qm_lacks "$log" "TOOL ERROR" "an absent remote commit is not a scanner failure"
  gg_rmrepo "$r"

  # ---- every pushed commit is checked, not only the tip --------------------------
  # (git-guard #72 review, P1.) An intermediate commit with a malformed register
  # used to reach the remote whenever the tip's register was fine.
  r="$(_qm_repo)"
  _qm_put "$r" README.md 'base\n'
  _qm_commit "$r" "base"
  _qm_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json '{"version": 1, "rules": []}\n'
  _qm_commit "$r" "malformed in the middle"
  _qm_mid="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >/dev/null 2>&1
  _qm_commit "$r" "valid at the tip"
  _qm_tip="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_base" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "a malformed register in an intermediate pushed commit blocks"
  _qm_has "$log" "MALFORMED" "the block says MALFORMED"
  _qm_has "$log" "$(printf %s "$_qm_mid" | cut -c1-12)" "and names the intermediate commit"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" \
    1111111111111111111111111111111111111111 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "an absent remote commit does not hide an intermediate malformed register"
  _qm_has "$log" "MALFORMED" "the available local history still enforces its register"
  # positive control: once the remote already has the bad commit, only the tip is new.
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_mid" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "the same tip pushes once the remote already holds the bad commit"
  ( cd "$r" && git update-ref refs/remotes/origin/main "$_qm_mid" )
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" \
    1111111111111111111111111111111111111111 > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "an unfetched remote replacement does not recheck already published debt"
  _qm_lacks "$log" "MALFORMED" "the known remote history remains outside the introduced commits"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  ( cd "$r" && sh "$_QM_SCAN" --write-baseline ) >/dev/null 2>&1
  _qm_commit "$r" "valid source and register"
  _qm_base="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_NARROW"
  _qm_commit "$r" "source-only register regression"
  _qm_mid="$(git -C "$r" rev-parse HEAD)"
  _qm_put "$r" src/app.py "$_QM_CLEAN"
  _qm_commit "$r" "source-only restoration"
  _qm_tip="$(git -C "$r" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_base" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "a source-only intermediate register regression blocks"
  _qm_has "$log" "$(printf %s "$_qm_mid" | cut -c1-12)" "the source-only block names its introduced commit"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$_qm_tip" "$_qm_mid" > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "the restored tip passes once the intermediate commit is remote"
  gg_rmrepo "$r"

  # ---- a type change (symlink -> regular file) is scanned (git-guard #72 review) --
  r="$(_qm_repo)"
  _qm_conf "$r" 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\n'
  _qm_put "$r" README.md 'base\n'
  ( cd "$r" && mkdir -p src && ln -s ../README.md src/model.py )
  _qm_commit "$r" "symlink"
  _qm_type_base="$(git -C "$r" rev-parse HEAD)"
  rm -f "$r/src/model.py"
  _qm_put "$r" src/model.py 'from pydantic.v1 import BaseModel\n'
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "a symlink turned into a file with pydantic.v1 blocks (type change is scanned)"
  _qm_has "$log" "pydantic_v1" "the block names pydantic_v1"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 1 "$rc" "pre-commit dispatches mandate checks for a source type change"
  _qm_has "$log" "pydantic_v1" "pre-commit reports the actual type-change finding"
  _qm_commit "$r" "source replaces symlink"
  _qm_scan "$r" "$log" --range "$_qm_type_base..HEAD"; rc=$?
  t_expect_rc 1 "$rc" "a range symlink-to-file type change enforces pydantic.v1"
  gg_rmrepo "$r"

  # Same review: added source symlinks caused exporter errors. Protect the
  # regular-file-only policy in staged/range/caller paths; detect alias target
  # text treated as source. Needs the symlink support used by the case above.
  r="$(_qm_repo)"
  _qm_conf "$r" 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\n'
  _qm_put "$r" README.md 'value = 1\n'
  _qm_commit "$r" "base"
  _qm_type_base="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && ln -s README.md alias.py && git add alias.py )
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "an added Python symlink is skipped before staged export"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-commit" ) >"$log" 2>&1; rc=$?
  t_expect_rc 0 "$rc" "pre-commit preserves the source-symlink skip policy"
  _qm_commit "$r" "source alias"
  _qm_scan "$r" "$log" --range "$_qm_type_base..HEAD"; rc=$?
  t_expect_rc 0 "$rc" "an added Python symlink is skipped before range export"
  gg_rmrepo "$r"

  # ---- repository policy is read from the same snapshot as the code ------------
  # (git-guard #72 review, P2.) The scanner used to read .qa-gate.conf from the
  # working tree once and apply it to every snapshot it scanned, so a pushed
  # branch was judged under whatever branch happened to be checked out, and an
  # unstaged conf edit decided what a commit was held to.
  _qm_register='{"version": 1, "policy_revision": "git-guard-mandate-1", "measured_at_commit": "fixture", "rules": {}}\n'
  r="$(_qm_repo)"
  _qm_put "$r" README.md 'base\n'
  _qm_commit "$r" "base"
  _qm_base="$(git -C "$r" rev-parse HEAD)"
  # ref A: its own conf declares lib/a vendored, so its except-pass is exempt.
  ( cd "$r" && git checkout -q -b ref-a "$_qm_base" )
  _qm_put "$r" .qa-gate.conf 'mandate.vendored=lib/a\n'
  _qm_put "$r" lib/a/app.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register"
  _qm_commit "$r" "ref a"
  _qm_a="$(git -C "$r" rev-parse HEAD)"
  # ref B: its own conf makes except_pass advisory, so its except-pass is not counted.
  ( cd "$r" && git checkout -q -b ref-b "$_qm_base" )
  _qm_put "$r" .qa-gate.conf 'mandate.except_pass=warn\n'
  _qm_put "$r" src/b.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register"
  _qm_commit "$r" "ref b"
  _qm_b="$(git -C "$r" rev-parse HEAD)"
  # ref C: no conf (policy on), an undeclared finding: its register does not hold.
  ( cd "$r" && git checkout -q -b ref-c "$_qm_base" )
  _qm_put "$r" src/c.py "$_QM_NARROW"
  _qm_put "$r" .git-guard/mandate-baseline.json "$_qm_register"
  _qm_commit "$r" "ref c"
  _qm_c="$(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && git checkout -q --detach "$_qm_base" )
  printf 'refs/heads/ref-a %s refs/heads/ref-a %s\nrefs/heads/ref-b %s refs/heads/ref-b %s\n' \
    "$_qm_a" 0000000000000000000000000000000000000000 "$_qm_b" 0000000000000000000000000000000000000000 \
    > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "a two-ref push judges each ref by its own committed conf (vendored dir, severity)"
  _qm_lacks "$log" "UNDECLARED" "neither ref is checked under the other's (or the checkout's) policy"
  printf 'mandate.enabled=off\n' > "$r/.qa-gate.conf"   # untracked: the checkout opts out
  printf 'refs/heads/ref-c %s refs/heads/ref-c %s\n' "$_qm_c" 0000000000000000000000000000000000000000 \
    > "$GG_T_TMPROOT/qm-refs"
  _qm_push "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "a checkout with mandate.enabled=off still enforces a pushed ref whose own conf is on"
  _qm_has "$log" "UNDECLARED except_pass" "the pushed ref's register is evaluated"
  rm -f "$r/.qa-gate.conf"
  gg_rmrepo "$r"

  r="$(_qm_repo)"
  _qm_put "$r" .qa-gate.conf 'mandate.except_pass=off\n'
  _qm_put "$r" src/n.py "$_QM_NARROW"
  printf 'mandate.except_pass=changed\n' > "$r/.qa-gate.conf"   # unstaged edit
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 0 "$rc" "the staged conf (except_pass=off) governs the commit, not the unstaged edit"
  _qm_has "$log" "policy: index" "the summary names the staged policy it applied"
  gg_rmrepo "$r"
  r="$(_qm_repo)"
  _qm_put "$r" src/n.py "$_QM_NARROW"
  printf 'mandate.except_pass=off\nmandate.enabled=off\n' > "$r/.qa-gate.conf"   # never staged
  _qm_scan "$r" "$log" --staged; rc=$?
  t_expect_rc 1 "$rc" "an unstaged conf that switches rules off does not relax the commit"
  printf 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\nmandate.enabled=off\n' \
    > "$r/.qa-gate.conf"
  gg_run_gate_log "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "qa_gate.sh defers to the staged mandate policy too"
  gg_rmrepo "$r"

  # ---- a broken ast-grep is a TOOL ERROR; an unrelated `sg` is "absent" -------
  # (git-guard #72 review, P2.) A known `ast-grep` executable whose version probe
  # fails used to fall through to the missing-tool WARN and pass.
  r="$(_qm_repo)"
  _qm_put "$r" src/app.py "$_QM_SWALLOW"
  _qm_fake="$(_qm_path_dir "$GG_T_TMPROOT/qm-fake-astgrep")"
  mkdir -p "$_qm_fake"
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_fake/ast-grep" '#!/bin/sh\nprintf "astgrep-exit3\\n" >> "$GG_QM_MARKER"\necho "ast-grep: cannot load runtime" >&2\nexit 3\n'
  ( cd "$r" && PATH="$_qm_fake:$PATH" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 2 "$rc" "an ast-grep whose --version exits 3 is a TOOL ERROR that blocks"
  _qm_has "$log" "TOOL ERROR [ast-grep]" "the TOOL ERROR names ast-grep"
  _qm_has "$GG_QM_MARKER" "astgrep-exit3" "the deliberately broken ast-grep payload actually ran"
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_fake/ast-grep" '#!/bin/sh\nprintf "astgrep-empty\\n" >> "$GG_QM_MARKER"\nexit 0\n'
  ( cd "$r" && PATH="$_qm_fake:$PATH" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 2 "$rc" "an ast-grep that prints no version is a TOOL ERROR too"
  _qm_has "$GG_QM_MARKER" "astgrep-empty" "the empty-version ast-grep payload actually ran"
  _qm_sgbin="$(_qm_path_dir "$GG_T_TMPROOT/qm-sg-bin")"
  _qm_min_bin "$_qm_sgbin" sh git dirname env sort tr ruff
  _qm_p="$(gg_python_exe 2>/dev/null)" &&
    _qm_forward "$_qm_sgbin/python3" "$_qm_p"
  # shellcheck disable=SC2016  # marker expands in the invoked child, not fixture creation
  _qm_payload "$_qm_sgbin/sg" '#!/bin/sh\nprintf "util-sg\\n" >> "$GG_QM_MARKER"\necho "sg from util-linux 2.39"\n'
  ( PATH="$_qm_sgbin" python3 -I -c 'import shutil; assert shutil.which("ast-grep") is None' ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 0 "$rc" "the restricted interpreter runs and cannot discover ast-grep"
  ( cd "$r" && VIRTUAL_ENV='' PATH="$_qm_sgbin" sh "$_QM_SCAN" --staged ) >/dev/null 2>"$log"; rc=$?
  t_expect_rc 1 "$rc" "an unrelated system sg is treated as no ast-grep (ruff still blocks the swallow)"
  _qm_has "$log" "ast-grep is not installed, so these rules were NOT evaluated" \
    "the util-linux sg reads as a missing ast-grep, not a TOOL ERROR"
  gg_rmrepo "$r"

  _qm_has "$GG_QM_MARKER" "util-sg" "the unrelated sg payload actually ran"
  unset GG_QM_MARKER

  # ---- qa_gate.sh calls the scanner at pre-commit ------------------------------
  r="$(_qm_repo)"
  printf 'python.ruff_check=off\npython.ruff_format=off\npython.mypy=off\npython.basedpyright=off\nastgrep=off\n' \
    > "$r/.qa-gate.conf"
  ( cd "$r" && git add .qa-gate.conf )
  _qm_quoted_path='vendor\caf"é.py'
  if gg_is_windows; then _qm_quoted_path="vendor café's model.py"; fi
  _qm_put "$r" "$_qm_quoted_path" "$_QM_SWALLOW"
  git -C "$r" ls-files --error-unmatch -- "$_qm_quoted_path" >/dev/null 2>&1; rc=$?
  t_expect_rc 0 "$rc" "the platform-valid quoted UTF-8 fixture is actually staged"
  gg_run_gate_log "$r" "$log"; rc=$?
  t_expect_rc 1 "$rc" "qa_gate.sh blocks a staged mandate finding in a quoted UTF-8 filename with a quote"
  _qm_has "$log" "quality mandate findings" "the gate's block names the mandate"
  printf 'mandate.enabled=off\n' >> "$r/.qa-gate.conf"
  ( cd "$r" && git add .qa-gate.conf )
  gg_run_gate_log "$r" "$log"; rc=$?
  t_expect_rc 0 "$rc" "qa_gate.sh with mandate.enabled=off passes"
  gg_rmrepo "$r"

  rm -f "$log"
  return 0
}

# Protects: eager nested headers declare enclosing locals; subscriptions capture owners.
# Detects: stale closure exemptions and post-index false model evidence.
# Needs: actual staged scanner and compile-valid owned fixtures, not fixture imports.
# Breadcrumb: hooks/common/mandate_scan.py receiver_bound_names/visit_Subscript.
_qm_receiver_header_subscript_contexts() {
  _qm_receiver_case 'nested default binds enclosing closure local' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    def configure(marker=(receiver:=Model)):\n        pass\n    return load()\nrun()\n' 0 unknown
  _qm_receiver_case 'nested keyword default binds enclosing closure local' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    def configure(*,marker=(receiver:=Model)):\n        pass\n    return load()\nrun()\n' 0 unknown
  _qm_receiver_case 'nested decorator binds enclosing closure local' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    @((receiver:=Model) and (lambda f:f))\n    def configure():\n        pass\n    return load()\nrun()\n' 0 unknown
  _qm_receiver_case 'nested class base binds enclosing closure local' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    class Configure((receiver:=Model)):\n        pass\n    return load()\nrun()\n' 0 unknown
  _qm_receiver_case 'nested class keyword binds enclosing closure local' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    class Configure(Model, extra=(receiver:=Model) and "allow"):\n        pass\n    return load()\nrun()\n' 0 unknown
  _qm_receiver_case 'nested deferred body does not bind enclosing local' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Model\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    def configure():\n        receiver=Parser()\n    return load()\nrun()\n' 1 model
  _qm_receiver_case 'nested class body locals do not bind enclosing function' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Model\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    class Configure:\n        receiver=Parser()\n    return load()\nrun()\n' 1 model
  _qm_receiver_case 'nested header unrelated write preserves model' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Model\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    def configure(marker=(other:=Parser)):\n        pass\n    return load()\nrun()\n' 1 model
  _qm_receiver_case 'nested stable default preserves plain global' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    def configure(marker=Model):\n        pass\n    return load()\nrun()\n' 0 plain
  _qm_receiver_case 'Model subscription captures owner before index rebind' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Model\nreceiver[(receiver:=Parser)].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'Model nested subscription captures initial owner' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Model\nreceiver[((receiver:=Parser),T)[1]][int].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'Parser subscription captures owner before index rebind' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser\nreceiver[(receiver:=Model)].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'Parser nested subscription captures initial owner' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nreceiver=Parser\nreceiver[(receiver:=Model)][int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'stable generic model class retains model' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nModel[int].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'stable plain generic return remains unresolved' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nParser[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'model instance subscription remains unresolved' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nModel()[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'plain instance subscription remains unresolved' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nParser()[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'index model data mutation retains model' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nModel[setattr(Model,'"'"'model_config'"'"',{})].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'index called type mutation forfeits model' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\ndef change():\n    Model.__bases__=external\nModel[change()].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'index uncalled type mutator preserves model' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\ndef change():\n    Model.__bases__=external\nModel[change].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'index called method mutation preserves model ancestry' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\ndef change():\n    Model.parse_file=external\nModel[change()].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'index direct model call stays independently enforced' \
    'from pydantic import BaseModel\nfrom typing import Generic,TypeVar\nT=TypeVar("T")\nclass Model(BaseModel,Generic[T]):\n    pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):\n        return path\n    @classmethod\n    def __class_getitem__(cls,item):\n        return cls\nParser[Model.parse_obj({})].parse_file('"'"'x'"'"')\n' 1 model
}

# Protects: legacy eager annotations declare locals without borrowing nested bodies.
# Detects: stale plain/model closure evidence for all argument kinds and returns.
# Needs: actual receiver AST resolver; legacy syntax is rejected by modern Ruff.
# Breadcrumb: hooks/common/mandate_scan.py receiver_binding_events/bound_names.
_qm_receiver_legacy_annotation_inventory() {
  _qmr_rows="$GG_T_TMPROOT/legacy-annotation-rows"
  if ! "$(gg_python)" -I - "$GG_ROOT" >"$_qmr_rows" <<'PY'
import ast
import importlib.util
from pathlib import Path
import sys
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("legacy_inventory_scanner", root / "hooks/common/mandate_scan.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
prefix = "from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):\n        return 'Parser'\n"
headers = {
    "positional": "def configure(marker:{annotation}):pass",
    "posonly": "def configure(marker:{annotation},/):pass",
    "keyword": "def configure(*,marker:{annotation}):pass",
    "varargs": "def configure(*markers:{annotation}):pass",
    "kwargs": "def configure(**markers:{annotation}):pass",
    "return": "def configure()->{annotation}:pass",
}
cases = []
for kind, template in headers.items():
    for scope in ("nested", "module"):
        header = template.format(annotation="(receiver:=Model)")
        tail = ("receiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('x')\n    " + header + "\n    return load()\nanswer=run()\n") if scope == "nested" else ("receiver=Parser()\nload=lambda:receiver.parse_file('x')\n" + header + "\nanswer=load()\n")
        cases.append((scope + " " + kind + " legacy write", tail, "unknown", "Model"))
    header = template.format(annotation="(receiver:=Parser())")
    cases.append(("nested " + kind + " inverse", "receiver=Model\ndef run():\n    load=lambda:receiver.parse_file('x')\n    " + header + "\n    return load()\nanswer=run()\n", "unknown", "Parser"))
    header = template.format(annotation="Model")
    cases.append(("stable " + kind, "receiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('x')\n    " + header + "\n    return load()\nanswer=run()\n", "plain", "Parser"))
cases.extend([
    ("unrelated annotation binding preserves model", "receiver=Model\ndef run():\n    load=lambda:receiver.parse_file('x')\n    def configure(marker:(other:=Parser)):pass\n    return load()\nanswer=run()\n", "model", "Model"),
    ("deferred nested annotation local stays separate", "receiver=Model\ndef run():\n    load=lambda:receiver.parse_file('x')\n    def configure():\n        def inner(marker:(receiver:=Parser())):pass\n    return load()\nanswer=run()\n", "model", "Model"),
    ("class body annotation local stays separate", "receiver=Model\ndef run():\n    load=lambda:receiver.parse_file('x')\n    class Configure:\n        def inner(marker:(receiver:=Parser())):pass\n    return load()\nanswer=run()\n", "model", "Model"),
    ("quoted annotation is no enclosing write", "receiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('x')\n    def configure(marker:'(receiver:=Model)'):pass\n    return load()\nanswer=run()\n", "plain", "Parser"),
])
for label, tail, expected, runtime_expected in cases:
    source = prefix + tail
    resolver = module.PydanticReceivers(source)
    resolver.visit(ast.parse(source))
    kinds = set().union(*resolver.calls.values()) if resolver.calls else set()
    passed = kinds == {expected}
    print(("PASS" if passed else "FAIL") + "|" + label + "|" + ",".join(sorted(kinds)))
PY
  then
    t_fail 'legacy annotation resolver setup failed'
    cat "$_qmr_rows" >&2
    return 0
  fi
  while IFS='|' read -r _qmr_state _qmr_label _qmr_kinds; do
    if [ "$_qmr_state" = PASS ]; then t_ok "legacy AST: $_qmr_label"; else
      t_fail "legacy AST: $_qmr_label (actual $_qmr_kinds)"
    fi
  done <"$_qmr_rows"
  _qmr_repo="$(_qm_repo)"; _qmr_log="$GG_T_TMPROOT/legacy-annotation-syntax.log"
  _qm_put "$_qmr_repo" src/model.py 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file("x")\n    def configure(marker:(receiver:=Model)):pass\n    return load()\n'
  _qm_scan "$_qmr_repo" "$_qmr_log" --staged; _qmr_rc=$?
  t_expect_rc 1 "$_qmr_rc" 'current staged pipeline rejects legacy annotation syntax'
  _qm_has "$_qmr_log" '[python_syntax]' 'current Ruff syntax barrier stays visible'
  gg_rmrepo "$_qmr_repo"
}

# Protects: comprehension targets stay local and outer walrus bindings remain visible.
# Detects: unrelated loop names weakening a later known-model block.
# Needs: actual staged scanner and seven compile-valid modern fixtures.
# Breadcrumb: hooks/common/mandate_scan.py receiver_bound_names/binding_events.
_qm_receiver_comprehension_scope_contexts() {
  _qm_receiver_case 'list target is not enclosing local' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef run():\n    [None for Model in []]\n    return Model.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'set target is not enclosing local' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef run():\n    {None for Model in []}\n    return Model.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'dict target is not enclosing local' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef run():\n    {None:None for Model in []}\n    return Model.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'generator target is not enclosing local' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef run():\n    (None for Model in [])\n    return Model.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'target-local body remains unresolved' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef run():\n    return [Model.parse_file('"'"'x'"'"') for Model in items]\n' 0 unknown
  _qm_receiver_case 'comprehension walrus still binds enclosing local' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nreceiver=Parser()\ndef run():\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    [(receiver:=Model) for item in [0]]\n    return load()\n' 0 unknown
  _qm_receiver_case 'ordinary target preserves enclosing model' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\ndef run():\n    [None for item in []]\n    return Model.parse_file('"'"'x'"'"')\n' 1 model
}

# Protects: formal bindings shadow outer names and later reassignment expires captures.
# Detects: stale parameter/self proof and explicit initializer-hook namespace changes.
# Needs: actual staged scanner; ordinary data/plain and strong-model counterparts.
# Breadcrumb: hooks/common/mandate_scan.py receiver_rebound_names/target_mutation.
_qm_receiver_parameter_hook_contexts() {
  _qm_receiver_case 'typed parameter lambda observes later reassignment' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef outer(receiver:Parser):\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    receiver=Model\n    return load()\n' 0 unknown
  _qm_receiver_case 'typed parameter nested function observes later reassignment' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef outer(receiver:Parser):\n    def load():return receiver.parse_file('"'"'x'"'"')\n    receiver=Model\n    return load()\n' 0 unknown
  _qm_receiver_case 'implicit self lambda observes later reassignment' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass LocalParser:\n    def parse_file(self,path):return path\n    def run(self):\n        load=lambda:self.parse_file('"'"'x'"'"')\n        self=Model\n        return load()\n' 0 unknown
  _qm_receiver_case 'strict ambiguity cannot clear reassigned parameter' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef outer(receiver:Parser):\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    receiver=Model\n    return load()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'replaced initializer loses class plain proof' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef install(self):\n    self.parse_file=Model.parse_file\nParser.__init__=install\nParser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'replaced subclass hook loses child plain proof' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef install(cls):\n    cls.parse_file=Model.parse_file\nParser.__init_subclass__=classmethod(install)\nclass Child(Parser):pass\nChild().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'unchanged typed parameter closure remains plain' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef outer(receiver:Parser):\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    return load()\n' 0 plain
  _qm_receiver_case 'ordinary self data write preserves plain closure' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass LocalParser:\n    def parse_file(self,path):return path\n    def run(self):\n        load=lambda:self.parse_file('"'"'x'"'"')\n        self.path='"'"'notes'"'"'\n        return load()\n' 0 plain
  _qm_receiver_case 'unchanged model parameter remains strong' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef outer(receiver:Model):\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    return load()\n' 1 model
  _qm_receiver_case 'model initializer write preserves model ancestry' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef install(self):self.path='"'"'notes'"'"'\nModel.__init__=install\nModel.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'parameter shadow ignores rebound global for strong model' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nreceiver=Parser()\nreceiver=Model\ndef outer(receiver:Model):\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    return load()\n' 1 model
  _qm_receiver_case 'parameter shadow ignores rebound global for plain parser' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nreceiver=Parser()\nreceiver=Model\ndef outer(receiver:Parser):\n    load=lambda:receiver.parse_file('"'"'x'"'"')\n    return load()\n' 0 plain
  _qm_receiver_case 'model subclass hook write preserves direct model ancestry' \
    'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef install(cls):cls.path='"'"'notes'"'"'\nModel.__init_subclass__=classmethod(install)\nModel.parse_file('"'"'x'"'"')\n' 1 model
}

# Protects: Implicit hooks cannot retain plain proof or invent subscription ancestry.
# Detects: Setter/deleter, custom subscription and shared-metaclass projection gaps.
# Needs: actual staged Ruff/ast-grep;23 owned3.15 stdlib dispatch witnesses.
# Breadcrumb: hooks/common/mandate_scan.py ReceiverOperation/ReceiverEffect/receiver_effect.
_qm_receiver_data_hook_contexts() {
  _qm_receiver_case 'implicit setter during data-only initializer' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Writer:\n    def __setattr__(self,name,value):\n        self.__dict__[name]=value\n        self.__dict__['"'"'parse_file'"'"']=Model.parse_file\n    def __init__(self):self.path='"'"'x'"'"'\n    def parse_file(self,path):return path\nWriter().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'implicit setter during ordinary field assignment' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Writer:\n    def __setattr__(self,name,value):\n        self.__dict__[name]=value\n        self.__dict__['"'"'parse_file'"'"']=Model.parse_file\n    def parse_file(self,path):return path\nobj=Writer()\nobj.path='"'"'x'"'"'\nobj.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'strict implicit setter cannot stay plain' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Writer:\n    def __setattr__(self,name,value):\n        self.__dict__[name]=value\n        self.__dict__['"'"'parse_file'"'"']=Model.parse_file\n    def parse_file(self,path):return path\nobj=Writer()\nobj.path='"'"'x'"'"'\nobj.parse_file('"'"'x'"'"')\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'implicit deletion can replace receiver method' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Deleter:\n    def __init__(self):self.path='"'"'x'"'"'\n    def __delattr__(self,name):self.__dict__['"'"'parse_file'"'"']=Model.parse_file\n    def parse_file(self,path):return path\nobj=Deleter()\ndel obj.path\nobj.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'explicit alias setter replacement is unsupported' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef install(self,name,value):\n    self.__dict__[name]=value\n    self.__dict__['"'"'parse_file'"'"']=Model.parse_file\nAlias=Parser\nAlias.__setattr__=install\nobj=Parser()\nobj.path='"'"'x'"'"'\nobj.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'custom class subscription return is unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Holder(BaseModel):\n    def __class_getitem__(cls,key):return Parser()\nHolder[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'assigned class subscription return is unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(key):return Parser()\nclass Holder(BaseModel):\n    __class_getitem__=staticmethod(redirect)\nHolder[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'inherited custom subscription return is unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Holder(BaseModel):\n    def __class_getitem__(cls,key):return Parser()\nclass Child(Holder):pass\nChild[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'explicit alias subscription replacement is unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(cls,key):return Parser()\nAlias=Model\nAlias.__class_getitem__=classmethod(redirect)\nModel[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'deferred subscription sees later replacement' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef load():return Model[int].parse_file('"'"'x'"'"')\ndef redirect(cls,key):return Parser()\nModel.__class_getitem__=classmethod(redirect)\nload()\n' 0 unknown
  _qm_receiver_case 'direct model API survives custom subscription' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Holder(BaseModel):\n    def __class_getitem__(cls,key):return Parser()\nHolder.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'stock generic model subscription retains model' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nfrom typing import Generic,TypeVar\nT=TypeVar('"'"'T'"'"')\nclass Stock(BaseModel,Generic[T]):pass\nStock[int].parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'ordinary plain data write remains plain' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nobj=Parser()\nobj.path='"'"'x'"'"'\nobj.parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'ordinary model data write retains model' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Item(BaseModel):path:str='"'"'x'"'"'\nobj=Item()\nobj.path='"'"'y'"'"'\nobj.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'instance subscription return remains unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Item(BaseModel):\n    def __getitem__(self,key):return Parser()\nItem()[0].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'non-type base proxy remains unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Proxy:\n    def __mro_entries__(self,bases):return (Parser,)\nclass Box(Proxy()):pass\nBox().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'metaclass subscription remains unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Meta(type):\n    def __getitem__(cls,key):return Parser()\nclass Box(metaclass=Meta):pass\nBox[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'late metaclass call changes constructor result' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(cls,*args,**kwargs):return Parser()\ntype(Model).__call__=redirect\nModel().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'direct model API survives metaclass call mutation' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(cls,*args,**kwargs):return Parser()\ntype(Model).__call__=redirect\nModel.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'direct model API survives visible instance setter' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\nclass Holder(BaseModel):\n    def __setattr__(self,name,value):self.__dict__[name]=value\nHolder.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'direct model API survives later class subscription write' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(cls,key):return Parser()\nModel.__class_getitem__=classmethod(redirect)\nModel.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'late metaclass subscription changes result' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(cls,key):return Parser()\ntype(Model).__getitem__=redirect\nModel[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'direct model API survives metaclass subscription mutation' 'from pydantic import BaseModel\nclass Model(BaseModel):\n    pass\nclass Parser:\n    def parse_file(self,path):return path\ndef redirect(cls,key):return Parser()\ntype(Model).__getitem__=redirect\nModel.parse_file('"'"'x'"'"')\n' 1 model
}

# Protects: Shared-meta construction effects do not invent subclass ownership.
# Detects: Lost operation unions, false direct-API ambiguity and init-owner conflation.
# Needs: actual staged scanner; owned heap-metaclass witnesses, not framework internals.
# Breadcrumb: hooks/common/mandate_scan.py receiver_unresolved_effect/receiver_join.
_qm_receiver_projection_join_contexts() {
  _qm_receiver_case 'direct heap-metaclass initializer' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef redirect(cls,*args,**kwargs):\n    type.__init__(cls,*args,**kwargs)\n    cls.__bases__=(Parser,)\ntype(Model).__init__=redirect\nclass Child(Model):pass\nanswer=Child.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'alias heap-metaclass initializer' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef redirect(cls,*args,**kwargs):\n    type.__init__(cls,*args,**kwargs)\n    cls.__bases__=(Parser,)\nAlias=type(Model)\nAlias.__init__=redirect\nclass Child(Model):pass\nanswer=Child.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'direct Model API counterpart' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef redirect(cls,*args,**kwargs):\n    type.__init__(cls,*args,**kwargs)\n    cls.__bases__=(Parser,)\ntype(Model).__init__=redirect\nclass Child(Model):pass\nanswer=Model.parse_file("x")\n' 1 model
  _qm_receiver_case 'known class initializer does not erase subclass ancestry' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef setup(self):self.path='"'"'x'"'"'\nModel.__init__=setup\nclass Child(Model):pass\nChild.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'conditional custom subscription preserves direct model ancestry' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef redirect(cls,key):return Parser\nif condition:\n    Model.__class_getitem__=classmethod(redirect)\nModel.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'conditional custom subscription result stays unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef redirect(cls,key):return Parser\nif condition:\n    Model.__class_getitem__=classmethod(redirect)\nModel[int].parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'conditional shared metaclass call preserves direct model ancestry' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\ndef redirect(cls,*args):return Parser()\nif condition:\n    type(Model).__call__=redirect\nModel.parse_file('"'"'x'"'"')\n' 1 model
}

# Protects: Literal-data callbacks and namespace conservatism preserve prior evidence.
# Detects: Lost module/class barriers or protocol-bearing callbacks blessed as pure.
# Needs: actual staged scanner; owned FakeBase runtime controls, not provider calls.
# Breadcrumb: hooks/common/mandate_scan.py receiver_literal_data_hook/invalidate_target/class_mutation_barrier.
_qm_receiver_effect_preservation_contexts() {
  _qm_receiver_case 'known literal-data subclass callback preserves model' 'from pydantic import BaseModel\nfrom typing import Generic, TypeVar\nT = TypeVar('"'"'T'"'"')\nclass Model(BaseModel, Generic[T]): pass\nclass Plain:\n    @classmethod\n    def parse_file(cls, path): return '"'"'plain'"'"'\ndef install(cls): cls.marker='"'"'data'"'"'\nModel.__init_subclass__=classmethod(install)\nclass Child(Model): pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'known literal-data callback Name alias preserves model' 'from pydantic import BaseModel\nfrom typing import Generic, TypeVar\nT = TypeVar('"'"'T'"'"')\nclass Model(BaseModel, Generic[T]): pass\nclass Plain:\n    @classmethod\n    def parse_file(cls, path): return '"'"'plain'"'"'\ndef install(cls): cls.marker='"'"'data'"'"'\nalias=install\nModel.__init_subclass__=classmethod(alias)\nclass Child(Model): pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'retyping subclass callback stays unsupported' 'from pydantic import BaseModel\nfrom typing import Generic, TypeVar\nT = TypeVar('"'"'T'"'"')\nclass Model(BaseModel, Generic[T]): pass\nclass Plain:\n    @classmethod\n    def parse_file(cls, path): return '"'"'plain'"'"'\ndef install(cls): cls.__bases__=(Plain,)\nModel.__init_subclass__=classmethod(install)\nclass Child(Model): pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'exact mutated module namespace is unresolved' 'import pydantic as pd\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\nkey='"'"'BaseModel'"'"'\npd.__dict__[key]=Parser\nclass Child(pd.BaseModel):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'ordinary module data preserves trusted namespace' 'import pydantic as pd\nclass Parser:\n    @classmethod\n    def parse_file(cls,path):return '"'"'Parser'"'"'\npd.__dict__['"'"'note'"'"']='"'"'data'"'"'\nclass Child(pd.BaseModel):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'nested immediate class mutation forfeits outer plain proof' 'from pydantic import BaseModel\nclass Parser:\n    def parse_file(self,path):return '"'"'Parser'"'"'\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nclass Patch:\n    Holder.target.__getattribute__=lambda self,name:BaseModel.parse_file if name=='"'"'parse_file'"'"' else object.__getattribute__(self,name)\nanswer=reader.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'strict nested class mutation cannot stay plain' 'from pydantic import BaseModel\nclass Parser:\n    def parse_file(self,path):return '"'"'Parser'"'"'\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nclass Patch:\n    Holder.target.__getattribute__=lambda self,name:BaseModel.parse_file if name=='"'"'parse_file'"'"' else object.__getattribute__(self,name)\nanswer=reader.parse_file('"'"'x'"'"')\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'ordinary nested class data write preserves plain proof' 'from pydantic import BaseModel\nclass Parser:\n    def parse_file(self,path):return '"'"'Parser'"'"'\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nclass Patch:\n    Holder.target.note='"'"'data'"'"'\nanswer=reader.parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'supported data callback is not a proven plain API receiver' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef install(cls):cls.marker='"'"'data'"'"'\ninstall.__dict__.update({'"'"'parse_file'"'"':Model.parse_file})\ninstall.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'strict data callback receiver cannot clear unresolved API' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef install(cls):cls.marker='"'"'data'"'"'\ninstall.__dict__.update({'"'"'parse_file'"'"':Model.parse_file})\ninstall.parse_file('"'"'x'"'"')\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'subscript protocol RHS is not a supported data callback' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        key.__bases__=(Plain,)\n        return '"'"'data'"'"'\ntrigger=Trigger()\ndef install(cls):cls.marker=trigger[cls]\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'descriptor attribute RHS is not a supported data callback' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    @property\n    def marker(self):\n        Model.__bases__=(Plain,)\n        return '"'"'data'"'"'\ntrigger=Trigger()\ndef install(cls):cls.marker=trigger.marker\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
}

# Protects: A local literal-data callback proof expires when its code object changes.
# Detects: Stale callback identity through Name aliases, captures or called mutators.
# Needs: actual staged scanner and8ownedFakeBase runtime witnesses; no provider API.
# Breadcrumb: hooks/common/mandate_scan.py RECEIVER_NAMESPACE_MEMBERS/visit_FunctionDef/invalidate_binding.
_qm_receiver_callback_code_contexts() {
  _qm_receiver_case 'direct callback code mutation expires structural proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\ninstall.__code__=alter.__code__\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'Name-alias callback code mutation expires original proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\nalias=install\nalias.__code__=alter.__code__\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'called local code mutator expires callback proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\ndef change():install.__code__=alter.__code__\nchange()\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'uncalled code mutator preserves literal callback' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\ndef change():install.__code__=alter.__code__\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'reading callback code preserves literal callback' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\ncode=install.__code__\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'deferred builder observes possible callback code mutation' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\ndef build():\n    Model.__init_subclass__=classmethod(install)\n    class Child(Model):pass\n    return Child.parse_file("x")\ninstall.__code__=alter.__code__\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'ordinary model code-named data preserves model ancestry' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\nModel.__code__='"'"'metadata'"'"'\nanswer=Model.parse_file('"'"'x'"'"')\n' 1 model
  _qm_receiver_case 'unknown code-mutation owner expires callback proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\ndef install(cls):cls.marker='"'"'data'"'"'\ndef alter(cls):cls.__bases__=(Plain,)\nholder=[install]\nholder[0].__code__=alter.__code__\nModel.__init_subclass__=classmethod(install)\nclass Child(Model):pass\nanswer=Child.parse_file('"'"'x'"'"')\n' 0 unknown
}

# Protects: Initializer protocols and descriptor completion cannot establish stale plain proof.
# Detects: No-explicit-call purity assumptions and missing automatic set-name dispatch.
# Needs: actual staged scanner andownedFakeBase language witnesses; no provider API.
# Breadcrumb: hooks/common/mandate_scan.py plain_initializer_supported/plain_namespace_supported/has_set_name.
_qm_receiver_initializer_descriptor_contexts() {
  _qm_receiver_case 'initializer subscription protocol cannot retain plain proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __getitem__(self,key):\n        Parser.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Parser:\n    def __init__(self):self.marker=trigger[0]\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'strict initializer protocol cannot silently clear' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __getitem__(self,key):\n        Parser.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Parser:\n    def __init__(self):self.marker=trigger[0]\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor set-name cannot retain plain owner proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __set_name__(self,owner,name):owner.parse_file=Model.parse_file\nclass Parser:\n    marker=Trigger()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'strict descriptor set-name cannot silently clear' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __set_name__(self,owner,name):owner.parse_file=Model.parse_file\nclass Parser:\n    marker=Trigger()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'literal and Name initializer data preserves plain proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    def __init__(self,path):\n        self.path=path\n        self.marker='"'"'data'"'"'\n    def parse_file(self,path):return path\nanswer=Parser('"'"'owned'"'"').parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'ordinary class literal data preserves plain proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    marker='"'"'data'"'"'\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'known local non-descriptor field preserves plain proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:pass\nclass Parser:\n    marker=Marker()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
}

# Protects: Known absence/presence survives aliases, inheritance and namespace writes.
# Detects: Late/inherited hooks, unsafe decorators or unsupported constructor unpacking.
# Needs: actual staged scanner andownedFakeBase language witnesses; no provider API.
# Breadcrumb: hooks/common/mandate_scan.py plain_initializer_supported/plain_namespace_supported/has_set_name.
_qm_receiver_descriptor_presence_contexts() {
  _qm_receiver_case 'inherited set-name presence cannot prove plain owner' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __set_name__(self,owner,name):owner.parse_file=Model.parse_file\nclass Child(Trigger):pass\nclass Parser:\n    marker=Child()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'descriptor class Name alias cannot prove plain owner' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __set_name__(self,owner,name):owner.parse_file=Model.parse_file\nAlias=Trigger\nclass Parser:\n    marker=Alias()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'later set-name namespace mutation expires absence' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:pass\ndef bind(self,owner,name):owner.parse_file=Model.parse_file\nMarker.__set_name__=bind\nclass Parser:\n    marker=Marker()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'Name-alias later set-name mutation expires absence' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:pass\ndef bind(self,owner,name):owner.parse_file=Model.parse_file\nAlias=Marker\nAlias.__set_name__=bind\nclass Parser:\n    marker=Marker()\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'existing instance expires after class set-name mutation' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:pass\ndef bind(self,owner,name):owner.parse_file=Model.parse_file\nmarker=Marker()\nMarker.__set_name__=bind\nclass Parser:\n    marker=marker\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'method self proof cannot precede descriptor completion' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __set_name__(self,owner,name):owner.parse_file=Model.parse_file\nclass Parser:\n    def parse_file(self,path):return path\n    def run(self):return self.parse_file('"'"'x'"'"')\n    marker=Trigger()\nanswer=Parser().run()\n' 0 unknown
  _qm_receiver_case 'arbitrary decorated non-API function may be descriptor' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n    def __set_name__(self,owner,name):owner.parse_file=Model.parse_file\ndef decorate(fn):return Trigger()\nclass Parser:\n    @decorate\n    def marker(self):pass\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'ordinary function Name is descriptor-free' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef helper():return '"'"'data'"'"'\nclass Parser:\n    marker=helper\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'ordinary function Name alias is descriptor-free' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef helper():return '"'"'data'"'"'\nalias=helper\nclass Parser:\n    marker=alias\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'unshadowed builtin staticmethod field is descriptor-free' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef helper():return '"'"'data'"'"'\nclass Parser:\n    marker=staticmethod(helper)\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'local function aliases and builtin wrappers remain plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n    def helper():return '"'"'data'"'"'\n    alias=helper\n    marker=staticmethod(alias)\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'ordinary local constructor literal and Name arguments remain plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:\n    def __init__(self,item):self.item=item\nitem='"'"'data'"'"'\nclass Parser:\n    marker=Marker(item)\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'constructor starred protocol remains unsupported' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:\n    def __init__(self,*items):pass\nitems=(1,)\nclass Parser:\n    marker=Marker(*items)\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'constructor keyword unpack protocol remains unsupported' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Marker:\n    def __init__(self,**options):pass\noptions={}\nclass Parser:\n    marker=Marker(**options)\n    def parse_file(self,path):return path\nanswer=Parser().parse_file('"'"'x'"'"')\n' 0 unknown
}

# Protects: Namespace eager values cannot mutate parent/outer proofs unnoticed.
# Detects: Protocols hidden inside containers/defaults or lost captured barriers.
# Needs: actual staged scanner and11ownedFakeBase runtime witnesses; no provider API.
# Breadcrumb: hooks/common/mandate_scan.py supported_eager_value/plain_namespace_supported/class_mutation_barrier.
_qm_receiver_descriptor_eager_contexts() {
  _qm_receiver_case container_protocol_during_class_namespace 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=[trigger[0]]\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case function_default_protocol_during_class_namespace 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    def helper(self,value=trigger[0]):pass\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case literal_container_no_protocol_positive 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=['"'"'data'"'"',7]\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case outer_parent_proof_after_protocol 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=[trigger[0]]\nanswer=Parent().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case lambda_default_protocol 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=lambda value=trigger[0]: None\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'nested literal containers and ordinary Names are inert' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nlabel='"'"'data'"'"'\nclass Reader(Parent):\n    marker=[label,{'"'"'x'"'"':7},(None,'"'"'data'"'"')]\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'lambda body protocol is deferred not class eager' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=lambda:trigger[0]\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'ordinary Name function default is inert' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    def helper(self,value=trigger):pass\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 plain
  _qm_receiver_case 'strict outer parent cannot clear after namespace protocol' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=[trigger[0]]\nanswer=Parent().parse_file('"'"'x'"'"')\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'opaque list boundary keeps earlier lookup unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=[Parent.parse_file("before"),trigger[0]]\n' 0 unknown
  _qm_receiver_case 'same container lookup after protocol forfeits plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n    marker=[trigger[0],Parent.parse_file("after")]\n' 0 unknown
}

# Protects: builtin-only hash proof and ordered lookups around container insertion.
# Detects: dictionary/set Name keys executing protocols under a literal-container exemption.
# Needs: actual staged default scanner, owned stdlib runtime witnesses; no provider.
# Breadcrumb: hooks/common/mandate_scan.py supported_eager_value/scoped/stored_class_key.
_qm_receiver_descriptor_hash_contexts() {
  _qm_receiver_case dict_key_hash 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker={trigger: 1}\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'opaque dict container keeps earlier lookup unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[Parent.parse_file("first"),{trigger:1}]\n' 0 unknown
  _qm_receiver_case 'dict_key_hash lookup after insertion' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[{trigger:1},Parent.parse_file("later")]\n' 0 unknown
  _qm_receiver_case 'dict_key_hash literal hash inputs are inert' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker={("key",1):trigger}\nanswer=Reader().parse_file("x")\n' 0 plain
  _qm_receiver_case set_member_hash 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker={trigger}\nanswer=Reader().parse_file('"'"'x'"'"')\n' 0 unknown
  _qm_receiver_case 'opaque set container keeps earlier lookup unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[Parent.parse_file("first"),{trigger}]\n' 0 unknown
  _qm_receiver_case 'set_member_hash lookup after insertion' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[{trigger},Parent.parse_file("later")]\n' 0 unknown
  _qm_receiver_case 'set_member_hash literal hash inputs are inert' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __hash__(self):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker={("key",1),None}\nanswer=Reader().parse_file("x")\n' 0 plain
}

# Protects: immediate copied branch views and unchanged earlier lookup evidence.
# Detects: class eager effects lost by If/IfExp/BoolOp environment copies.
# Needs: actual staged default scanner, owned stdlib runtime witnesses; no provider.
# Breadcrumb: hooks/common/mandate_scan.py supported_eager_value/scoped/stored_class_key.
_qm_receiver_descriptor_eager_branch_contexts() {
  _qm_receiver_case 'unsupported If prefix keeps earlier lookup unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n if True:\n  marker=[Parent.parse_file("first"),trigger[0]]\n' 0 unknown
  _qm_receiver_case 'if copied eager view lookup after' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n if True:\n  marker=[trigger[0],Parent.parse_file("later")]\n' 0 unknown
  _qm_receiver_case 'unsupported IfExp prefix keeps earlier lookup unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[Parent.parse_file("first"),trigger[0]] if True else []\n' 0 unknown
  _qm_receiver_case 'ifexp copied eager view lookup after' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[trigger[0],Parent.parse_file("later")] if True else []\n' 0 unknown
  _qm_receiver_case 'unsupported BoolOp prefix keeps earlier lookup unresolved' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n marker=True and [Parent.parse_file("first"),trigger[0]]\n' 0 unknown
  _qm_receiver_case 'boolop copied eager view lookup after' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n    @classmethod\n    def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n    def __getitem__(self,key):\n        Parent.parse_file=Model.parse_file\n        return '"'"'data'"'"'\ntrigger=Trigger()\nclass Reader(Parent):\n marker=True and [trigger[0],Parent.parse_file("later")]\n' 0 unknown
}

# Protects: explicit closed CLASS-to-CLASS field facts and their invalidation.
# Detects: ordinary data regression, opaque overwrite or alias namespace reuse.
# Needs: actual staged default scanner, owned stdlib runtime witnesses; no provider.
# Breadcrumb: hooks/common/mandate_scan.py supported_eager_value/scoped/stored_class_key.
_qm_receiver_stored_class_contexts() {
  _qm_receiver_case 'closed stored class data positive' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nclass Patch:\n Holder.target.note="data"\nanswer=reader.parse_file("x")\n' 0 plain
  _qm_receiver_case 'unknown class overwrite expires stored proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nclass Meta(type):\n def __setattr__(cls,name,value):\n  Parser.parse_file=Model.parse_file\nclass Replacement(metaclass=Meta):pass\nHolder.target=Replacement\nclass Patch:\n Holder.target.note="data"\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'alias namespace mutation expires stored proof' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nAlias=Holder\nAlias.__getattribute__=lambda self,name:object.__getattribute__(self,name)\nclass Patch:\n Holder.target.note="data"\nanswer=reader.parse_file("x")\n' 0 unknown
}

# Protects: finite eager prefixes, strong Model ancestry and captured-function order.
# Detects: implicit protocols or opaque class operations restoring stale plain facts.
# Needs: actual default/strict staged scanner and8ownedFakeBase witnesses; no provider.
# Breadcrumb: hooks/common/mandate_scan.py visit/eager_prefix_node/revalidate_binding.
_qm_receiver_eager_prefix_contract_contexts() {
  _qm_receiver_case 'unsupported BinOp expires before immediate traversal' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __add__(self,value):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[trigger+1,Parent.parse_file('"'"'after'"'"')]\nanswer=Reader.marker[1]\n' 0 unknown
  _qm_receiver_case 'strict ambiguity still blocks unsupported BinOp' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __add__(self,value):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[trigger+1,Parent.parse_file('"'"'after'"'"')]\nanswer=Reader.marker[1]\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'unsupported class truthiness pre-expires plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __bool__(self):\n  Parent.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Reader(Parent):\n if trigger:\n  marker=Parent.parse_file("after")\nanswer=Reader.marker\n' 0 unknown
  _qm_receiver_case 'unsupported attribute evaluation pre-expires plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __getattribute__(self,name):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[trigger.value,Parent.parse_file("after")]\nanswer=Reader.marker[1]\n' 0 unknown
  _qm_receiver_case 'model class opaque body invalidates unrelated outer plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __add__(self,value):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Subject(BaseModel):\n marker=trigger+1\nanswer=Parent.parse_file("after")\n' 0 unknown
  _qm_receiver_case 'model class direct ancestry remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __add__(self,value):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Subject(BaseModel):\n marker=trigger+1\nanswer=Subject.parse_file("after")\n' 1 model
  _qm_receiver_case 'opaque constructor argument expires captured class result' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n def __init__(self,marker=None):self.marker=marker\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __add__(self,value):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader:\n marker=Parent(trigger+1).parse_file("after")\nanswer=Reader.marker\n' 0 unknown
  _qm_receiver_case 'looked up legacy method remains plain before opaque argument' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return '"'"'plain'"'"'\nclass Trigger:\n def __add__(self,value):\n  Parent.parse_file=Model.parse_file\n  return 1\ntrigger=Trigger()\nclass Reader:\n marker=Parent.parse_file(trigger+1)\nanswer=Reader.marker\n' 0 plain
}

# Protects: preserved prefix observations followed by an explicit opaque tail fence.
# Detects: eager iterator acquisition, decorators or class construction leaking PLAIN.
# Needs: staged scanner and5ownedFakeBase witnesses; generator body remains deferred.
# Breadcrumb: hooks/common/mandate_scan.py comprehension/capture_decorators/visit_ClassDef.
_qm_receiver_eager_prefix_completion_contexts() {
  _qm_receiver_case 'list comprehension acquisition expires later plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Trigger:\n def __iter__(self):\n  Parent.parse_file=Model.parse_file\n  return iter(())\ntrigger=Trigger()\nclass Reader(Parent):\n marker=[value for value in trigger]\n answer=Parent.parse_file("after")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'generator comprehension acquisition expires later plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Trigger:\n def __iter__(self):\n  Parent.parse_file=Model.parse_file\n  return iter(())\ntrigger=Trigger()\nclass Reader(Parent):\n marker=(value for value in trigger)\n answer=Parent.parse_file("after")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'unknown decorator application expires later plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Decorator:\n def __call__(self,target):\n  Parent.parse_file=Model.parse_file\n  return target\ndecorator=Decorator()\nclass Reader(Parent):\n @decorator\n def helper(self):pass\n answer=Parent.parse_file("after")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'unproved class construction expires later plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Meta(type):\n def __new__(meta,name,bases,namespace):\n  Parent.parse_file=Model.parse_file\n  return super().__new__(meta,name,bases,namespace)\nclass Reader(Parent):\n class Child(metaclass=Meta):pass\n answer=Parent.parse_file("after")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'proved literal-data decorator preserves unrelated plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef mark(target):\n target.label="data"\n return None\nclass Reader(Parent):\n @mark\n def helper(self):pass\n answer=Parent.parse_file("after")\nanswer=Reader.answer\n' 0 plain
}

# Protects: observed headers precede opaque preparation, which precedes class body.
# Detects: an unknown metaclass prepare hook leaking stale PLAIN into the body.
# Needs: real staged default/strict pipeline; dormant own hook/header positives.
# Breadcrumb: hooks/common/mandate_scan.py visit_ClassDef preparation_supported.
_qm_receiver_eager_prefix_prepare_contexts() {
  _qm_receiver_case 'unproved preparation expires before class body' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):\n  Parent.parse_file=Model.parse_file\n  return {}\nclass Reader(metaclass=Meta):\n answer=Parent.parse_file("body")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'strict unproved preparation blocks unresolved body' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):\n  Parent.parse_file=Model.parse_file\n  return {}\nclass Reader(metaclass=Meta):\n answer=Parent.parse_file("body")\nanswer=Reader.answer\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'dormant own prepare definition preserves plain body' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Reader:\n @classmethod\n def __prepare__(cls,name,bases):\n  Parent.parse_file=Model.parse_file\n  return {}\n answer=Parent.parse_file("body")\nanswer=Reader.answer\n' 0 plain
  _qm_receiver_case 'header lookup precedes unknown namespace preparation' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases,**kwargs):\n  Parent.parse_file=Model.parse_file\n  return {}\n def __new__(meta,name,bases,namespace,**kwargs):\n  return super().__new__(meta,name,bases,namespace)\nclass Reader(metaclass=Meta, marker=Parent.parse_file("header")):pass\nanswer="plain"\n' 0 plain
}

# Protects: actual header builtin identity and opaque class LOAD_NAME provenance.
# Detects: fresh namespace stores or substituted model/module names claiming proof.
# Needs: staged default/strict cases, closed/global/deferred positives; no provider.
# Breadcrumb: hooks/common/mandate_scan.py value/visit/scoped/visit_ClassDef.
_qm_receiver_opaque_namespace_contexts() {
  _qm_receiver_case 'F1 enclosing type shadow default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Meta(type):\n def __new__(meta,name,bases,namespace):\n  if name=="Child":\n   Parent.parse_file=Model.parse_file\n  return super().__new__(meta,name,bases,namespace)\nclass Evil(metaclass=Meta):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Reader(Parent):\n type=Evil\n class Child(type):pass\n answer=Parent.parse_file("x")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'F1 enclosing type shadow strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Meta(type):\n def __new__(meta,name,bases,namespace):\n  if name=="Child":\n   Parent.parse_file=Model.parse_file\n  return super().__new__(meta,name,bases,namespace)\nclass Evil(metaclass=Meta):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Reader(Parent):\n type=Evil\n class Child(type):pass\n answer=Parent.parse_file("x")\nanswer=Reader.answer\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'F2 opaque namespace fresh store default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Namespace(dict):\n def __setitem__(self,key,value):\n  if key=="Local":\n   value.parse_file=Model.parse_file\n  super().__setitem__(key,value)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n class Local:\n  @classmethod\n  def parse_file(cls,path):return "plain"\n answer=Local.parse_file("x")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'F2 opaque namespace fresh store strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Namespace(dict):\n def __setitem__(self,key,value):\n  if key=="Local":\n   value.parse_file=Model.parse_file\n  super().__setitem__(key,value)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n class Local:\n  @classmethod\n  def parse_file(cls,path):return "plain"\n answer=Local.parse_file("x")\nanswer=Reader.answer\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'F2 opaque namespace model-name load default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="Model":return Plain\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n answer=Model.parse_file("x")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'F2 opaque namespace model-name load strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="Model":return Plain\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n answer=Model.parse_file("x")\nanswer=Reader.answer\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'ordinary unshadowed type header remains closed' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Reader:\n class Child(type):pass\n answer=Parent.parse_file("x")\nanswer=Reader.answer\n' 0 plain
  _qm_receiver_case 'closed namespace class store remains plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parent:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Holder:pass\nclass Reader:\n Holder.target=Parent\n answer=Holder.target.parse_file("x")\nanswer=Reader.answer\n' 0 plain
  _qm_receiver_case 'opaque suite explicit global model stays strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="Model":return Plain\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n global Model\n answer=Model.parse_file("x")\nanswer=Reader.answer\n' 1 model
  _qm_receiver_case 'opaque suite deferred method uses actual global model' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="Model":return Plain\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n def load(self):return Model.parse_file("x")\nanswer=Reader().load()\n' 1 model
  _qm_receiver_case 'module model after opaque suite stays strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="Model":return Plain\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):pass\nanswer=Model.parse_file("x")\n' 1 model
  _qm_receiver_case 'nested global declaration cannot exempt opaque outer lookup' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="Model":return Plain\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n def helper(self):\n  global Model\n answer=Model.parse_file("x")\nanswer=Reader.answer\n' 0 unknown
  _qm_receiver_case 'opaque module-name lookup cannot claim model identity' 'from pydantic import BaseModel\nimport pydantic as pd\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass PlainModule:BaseModel=Plain\nclass Namespace(dict):\n def __getitem__(self,key):\n  if key=="pd":return PlainModule\n  return super().__getitem__(key)\nclass Meta(type):\n @classmethod\n def __prepare__(meta,name,bases):return Namespace()\nclass Reader(metaclass=Meta):\n answer=pd.BaseModel.parse_file("x")\nanswer=Reader.answer\n' 0 unknown
}

# Protects: proved method role, deferred builtin horizon and lexical class globals.
# Detects: untrusted decorators inferring MODEL or future/global shadows clearing it.
# Needs: actual default/strict scanner; owned runtimes and immediate-prefix controls.
# Breadcrumb: hooks/common/mandate_scan.py visit_FunctionDef/builtin_lookup/visit_ClassDef.
_qm_receiver_binding_frames_contexts() {
  _qm_receiver_case 'N1 opaque staticmethod default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Settings(BaseModel, frozen=True):\n @staticmethod\n def load(source):return source.parse_file("x")\nanswer=Settings.load(Plain)\n' 0 unknown
  _qm_receiver_case 'N1 opaque staticmethod strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Settings(BaseModel, frozen=True):\n @staticmethod\n def load(source):return source.parse_file("x")\nanswer=Settings.load(Plain)\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'N1 ordinary self positive' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Settings(BaseModel, frozen=True):\n def load(self):return self.parse_file("x")\nanswer=Settings().load()\n' 1 model
  _qm_receiver_case 'L1 deferred builtin shadow default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef build():\n class Parser:\n  @classmethod\n  def parse_file(cls,path):return "plain"\n return Parser.parse_file("x")\ndef classmethod(f):return Model.parse_file\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'L1 deferred builtin shadow strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef build():\n class Parser:\n  @classmethod\n  def parse_file(cls,path):return "plain"\n return Parser.parse_file("x")\ndef classmethod(f):return Model.parse_file\nanswer=build()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'L2 closed global over function plain default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef build():\n Model=Plain\n class Reader:\n  global Model\n  answer=Model.parse_file("x")\n return Reader.answer\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'L2 closed global over function plain strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef build():\n Model=Plain\n class Reader:\n  global Model\n  answer=Model.parse_file("x")\n return Reader.answer\nanswer=build()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'L2 opaque global over function model default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nGlobal=Plain\ndef build():\n Global=Model\n class Reader(metaclass=type):\n  global Global\n  answer=Global.parse_file("x")\n return Reader.answer\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'L2 opaque global over function model strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nGlobal=Plain\ndef build():\n Global=Model\n class Reader(metaclass=type):\n  global Global\n  answer=Global.parse_file("x")\n return Reader.answer\nanswer=build()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'proved classmethod retains class receiver' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Settings(BaseModel):\n @classmethod\n def load(cls):return cls.parse_file("x")\nanswer=Settings.load()\n' 1 model
  _qm_receiver_case 'proved staticmethod retains unknown first argument' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Settings(BaseModel):\n @staticmethod\n def load(source):return source.parse_file("x")\nanswer=Settings.load(Plain)\n' 0 unknown
  _qm_receiver_case 'immediate builtin decorator survives later module shadow' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "plain"\nanswer=Parser.parse_file("x")\ndef classmethod(f):return Model.parse_file\n' 0 plain

  _qm_receiver_case 'deferred builtin considers lexical global writer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef build():\n class Parser:\n  @classmethod\n  def parse_file(cls,path):return "plain"\n return Parser.parse_file("x")\ndef install():\n global classmethod\n classmethod=lambda f:Model.parse_file\nalias=install\nalias()\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'deferred builtin considers lexical global writer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef build():\n class Parser:\n  @classmethod\n  def parse_file(cls,path):return "plain"\n return Parser.parse_file("x")\ndef install():\n global classmethod\n classmethod=lambda f:Model.parse_file\nalias=install\nalias()\nanswer=build()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'captured immediate builtin survives later global writer' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef install():\n global classmethod\n classmethod=lambda f:Model.parse_file\nalias=install\nalias()\nanswer=Parser.parse_file("x")\n' 0 plain
}

# Protects: lexical nested-function globals and actual positional receiver formals.
# Detects: closure-local values impersonating globals or kw-only arguments as self.
# Needs: default/strict sync+async witnesses; positional and annotation positives.
# Breadcrumb: hooks/common/mandate_scan.py visit_FunctionDef and AsyncFunctionDef alias.
_qm_receiver_global_formals_contexts() {
  _qm_receiver_case 'F1 nested function global default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef build():\n Model=Plain\n def inner():\n  global Model\n  return Model.parse_file("x")\n return inner()\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'F1 nested function global strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef build():\n Model=Plain\n def inner():\n  global Model\n  return Model.parse_file("x")\n return inner()\nanswer=build()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'F2 keyword-only parameter default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Settings(BaseModel):\n def load(*,source):return source.parse_file("x")\nanswer=Settings.load(source=Plain)\n' 0 unknown
  _qm_receiver_case 'F2 keyword-only parameter strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Settings(BaseModel):\n def load(*,source):return source.parse_file("x")\nanswer=Settings.load(source=Plain)\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'nested async global provenance default' 'import asyncio\nfrom pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef build():\n Model=Plain\n async def inner():\n  global Model\n  return Model.parse_file("x")\n return asyncio.run(inner())\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'nested async global provenance strict' 'import asyncio\nfrom pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\ndef build():\n Model=Plain\n async def inner():\n  global Model\n  return Model.parse_file("x")\n return asyncio.run(inner())\nanswer=build()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'genuine module function global remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\ndef build():\n global Model\n return Model.parse_file("x")\nanswer=build()\n' 1 model
  _qm_receiver_case 'positional-only model self remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Settings(BaseModel):\n def load(self,/):return self.parse_file("x")\nanswer=Settings().load()\n' 1 model
  _qm_receiver_case 'positional-only classmethod remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Settings(BaseModel):\n @classmethod\n def load(cls,/):return cls.parse_file("x")\nanswer=Settings.load()\n' 1 model
  _qm_receiver_case 'positional-only staticmethod remains unbound' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Plain:\n @classmethod\n def parse_file(cls,path):return "plain"\nclass Settings(BaseModel):\n @staticmethod\n def load(source,/):return source.parse_file("x")\nanswer=Settings.load(Plain)\n' 0 unknown
  _qm_receiver_case 'keyword-only annotation still provides model evidence' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Settings(BaseModel):\n def load(*,source:Model):return source.parse_file("x")\nanswer=Settings.load(source=Model)\n' 1 model
}

# Protects: Stored class owner mutations expire actual identity-dependent proof.
# Detects: Misidentifying a stored owner as its holder silently preserves plain aliases.
# Needs: Actual staged scanner default/strict, benign data and operation-flag controls.
# Breadcrumb: hooks/common/mandate_scan.py receiver_target_owner/invalidate_target/invalidate_binding.
_qm_receiver_stored_owner_contexts() {
  _qm_receiver_case 'stored class owner mutation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target.parse_file=Model.parse_file\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'stored class owner mutation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target.parse_file=Model.parse_file\nanswer=reader.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored owner deferred capture default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndef load():return reader.parse_file("x")\nHolder.target.parse_file=Model.parse_file\nanswer=load()\n' 0 unknown
  _qm_receiver_case 'stored owner deferred capture strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndef load():return reader.parse_file("x")\nHolder.target.parse_file=Model.parse_file\nanswer=load()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored owner called mutation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndef install():Holder.target.parse_file=Model.parse_file\ninstall()\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'stored owner called mutation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndef install():Holder.target.parse_file=Model.parse_file\ninstall()\nanswer=reader.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored owner alias mutation' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nAlias=Holder\nAlias.target.parse_file=Model.parse_file\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'stored owner benign data' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target.note="data"\nanswer=reader.parse_file("x")\n' 0 plain
  _qm_receiver_case 'stored owner benign deferred data' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndef load():return reader.parse_file("x")\nHolder.target.note="data"\nanswer=load()\n' 0 plain
  _qm_receiver_case 'stored owner direct stored class remains plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nanswer=Holder.target().parse_file("x")\n' 0 plain
  _qm_receiver_case 'resolved owner mutation preserves unrelated plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nclass Other:\n def parse_file(self,path):return "Other"\nother=Other()\nHolder.target.parse_file=Model.parse_file\nanswer=other.parse_file("x")\n' 0 plain
  _qm_receiver_case 'unknown owner mutation expires possible alias' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ntarget=opaque_factory()\ntarget.parse_file=Model.parse_file\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'stored owner dict target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target.__dict__["parse_file"]=Model.parse_file\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'stored owner dict target strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target.__dict__["parse_file"]=Model.parse_file\nanswer=reader.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored owner deletion default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndel Holder.target.parse_file\nanswer=reader.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'stored owner deletion strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndel Holder.target.parse_file\nanswer=reader.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'resolved construct does not imply subclass hook' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef install(self):self.note="data"\nHolder.target.__init__=install\nclass Child(Parser):pass\nanswer=Child.parse_file("x")\n' 0 plain
  _qm_receiver_case 'resolved construct makes new instance uncertain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\ndef install(self):self.parse_file=Model.parse_file\nHolder.target.__init__=install\nanswer=Holder.target().parse_file("x")\n' 0 unknown
  _qm_receiver_case 'explicit subclass mutation remains unsupported' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef install(cls):cls.parse_file=Model.parse_file\nHolder.target.__init_subclass__=classmethod(install)\nclass Child(Parser):pass\nanswer=Child.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'direct model namespace remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target.parse_file=Model.parse_file\nanswer=Model.parse_file("x")\n' 1 model
}

# Protects: Repeated set/dict iterations never exempt later model-bound receivers.
# Detects: List-only regressions can miss the shared eager iteration contract.
# Needs: Actual staged scanner; first-model, stable-plain and strict counterparts.
# Breadcrumb: hooks/common/mandate_scan.py comprehension/visit_SetComp/visit_DictComp.
_qm_receiver_comprehension_variants_contexts() {
  _qm_receiver_case 'set later iteration retains uncertainty default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Parser()\nresult={(receiver.parse_file("x"), (receiver := Model)) for item in range(2)}\n' 0 unknown
  _qm_receiver_case 'set later iteration retains uncertainty strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Parser()\nresult={(receiver.parse_file("x"), (receiver := Model)) for item in range(2)}\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'set first model remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Model\nresult={(receiver.parse_file("x"), (receiver := Parser())) for item in range(2)}\n' 1 model
  _qm_receiver_case 'set stable plain remains plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Parser()\nresult={receiver.parse_file("x") for item in range(2)}\n' 0 plain
  _qm_receiver_case 'dict later iteration retains uncertainty default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Parser()\nresult={receiver.parse_file("x"): (receiver := Model) for item in range(2)}\n' 0 unknown
  _qm_receiver_case 'dict later iteration retains uncertainty strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Parser()\nresult={receiver.parse_file("x"): (receiver := Model) for item in range(2)}\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'dict first model remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Model\nresult={receiver.parse_file("x"): (receiver := Parser()) for item in range(2)}\n' 1 model
  _qm_receiver_case 'dict stable plain remains plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nreceiver=Parser()\nresult={item: receiver.parse_file("x") for item in range(2)}\n' 0 plain
}

# Protects: cached class slots expire across later captures and known field writers.
# Detects: stale stored owner/receiver proof after deferred or local-call overwrite.
# Needs: actual default/strict scanner, initial-store and saved-identity controls.
# Breadcrumb: hooks/common/mandate_scan.py receiver_field_write_events/apply_written.
_qm_receiver_stored_field_horizon_contexts() {
  _qm_receiver_case 'A deferred slot overwrite default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nHolder.target=Model\nanswer=load()\n' 0 unknown
  _qm_receiver_case 'B local call slot overwrite default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'C stale stored owner mutation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Other:\n @classmethod\n def parse_file(cls,path):return "Other"\nother=Other()\ndef swap():Holder.target=Other\nswap()\nHolder.target.parse_file=Model.parse_file\nanswer=other.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'A deferred slot overwrite strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nHolder.target=Model\nanswer=load()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'B local call slot overwrite strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'C stale stored owner mutation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Other:\n @classmethod\n def parse_file(cls,path):return "Other"\nother=Other()\ndef swap():Holder.target=Other\nswap()\nHolder.target.parse_file=Model.parse_file\nanswer=other.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'single stored slot deferred remains plain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nanswer=load()\n' 0 plain
  _qm_receiver_case 'called unrelated member preserves stored slot' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.note=Model\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'direct slot overwrite remains known model' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.target=Model\nanswer=Holder.target.parse_file("x")\n' 1 model
  _qm_receiver_case 'saved field class identity survives replacement' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nSaved=Holder.target\nHolder.target=Model\nanswer=Saved.parse_file("x")\n' 0 plain
  _qm_receiver_case 'saved field deferred identity survives replacement' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nSaved=Holder.target\ndef load():return Saved.parse_file("x")\nHolder.target=Model\nanswer=load()\n' 0 plain
  _qm_receiver_case 'existing parser instance survives slot replacement' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nHolder.target=Model\nanswer=reader.parse_file("x")\n' 0 plain
  _qm_receiver_case 'callable alias writes slot default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\nalias=swap\nalias()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'local wrapper writes slot default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\ndef wrap():swap()\nwrap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'callable alias writes slot strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\nalias=swap\nalias()\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'local wrapper writes slot strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\ndef wrap():swap()\nwrap()\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'annotated slot assignment in call' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():\n Holder.target: object = Model\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'annotation-only slot remains unchanged' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.target: object\ndef load():return Holder.target.parse_file("x")\nanswer=load()\n' 0 plain
  _qm_receiver_case 'augmented slot syntax expires uncertain value' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target += Model\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deleted slot deferred read becomes uncertain' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndel Holder.target\nanswer=load()\n' 0 unknown
  _qm_receiver_case 'branch slot replacement joins uncertainty' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nif condition:\n Holder.target=Model\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'both branch model stores retain strong evidence' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nif condition:\n Holder.target=Model\nelse:\n Holder.target=Model\nanswer=Holder.target.parse_file("x")\n' 1 model
  _qm_receiver_case 'for target field write in known call' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():\n for Holder.target in [Model]:pass\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'with target field write in known call' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Context:\n def __enter__(self):return Model\n def __exit__(self,*args):return False\ndef swap():\n with Context() as Holder.target:pass\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'class body field store expires outer slot' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Change:\n Holder.target=Model\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'same member other owner conservatively expires slot' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass OtherHolder:pass\ndef swap():OtherHolder.target=Model\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'nested function slot capture observes overwrite' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef build():\n Holder.target=Parser\n def load():return Holder.target.parse_file("x")\n Holder.target=Model\n return load()\nanswer=build()\n' 0 unknown
  _qm_receiver_case 'async slot capture observes overwrite' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nimport asyncio\nasync def load():return Holder.target.parse_file("x")\nHolder.target=Model\nanswer=asyncio.run(load())\n' 0 unknown
  _qm_receiver_case 'generator slot capture observes overwrite' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nloads=(Holder.target.parse_file("x") for item in [0])\nHolder.target=Model\nanswer=list(loads)[0]\n' 0 unknown
  _qm_receiver_case 'callable alias cycle converges field effect' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\nalias=swap\nother_alias=alias\nalias=other_alias\nalias()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'uncalled field writer remains inert' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef swap():Holder.target=Model\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'single model slot deferred remains strong' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():return Holder.target.parse_file("x")\nanswer=load()\n' 1 model
  _qm_receiver_case 'inverse deferred slot overwrite is not falsely model' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():return Holder.target.parse_file("x")\nHolder.target=Parser\nanswer=load()\n' 0 unknown
  _qm_receiver_case 'unrelated augmented data member preserves slot' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 plain
}

# Protects: field-call summaries and finite MODEL prefixes without runtime-once inference.
# Protects: field call boundaries under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_call_boundaries_contexts() {
  _qm_receiver_case 'callable instance field writer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __call__(self):Holder.target=Model\nswapper=Swapper()\nHolder.target=Parser\nswapper()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'callable instance field writer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __call__(self):Holder.target=Model\nswapper=Swapper()\nHolder.target=Parser\nswapper()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'lambda setattr field writer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nswap=lambda:setattr(Holder,"target",Model)\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'lambda setattr field writer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nswap=lambda:setattr(Holder,"target",Model)\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'direct literal setattr slot write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nsetattr(Holder,"target",Model)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'direct literal setattr slot write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nsetattr(Holder,"target",Model)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'known function literal setattr slot write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef swap():setattr(Holder,"target",Model)\nHolder.target=Parser\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'known function literal setattr slot write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef swap():setattr(Holder,"target",Model)\nHolder.target=Parser\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'dynamic member setattr slot write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nmember="target"\nsetattr(Holder,member,Model)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'dynamic member setattr slot write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nmember="target"\nsetattr(Holder,member,Model)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'constructor field writer after initial store default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __init__(self):Holder.target=Model\nHolder.target=Parser\nswapper=Swapper()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'constructor field writer after initial store strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __init__(self):Holder.target=Model\nHolder.target=Parser\nswapper=Swapper()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'callback inside known wrapper default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef wrapper(fn):fn()\nHolder.target=Parser\nwrapper(lambda:setattr(Holder,"target",Model))\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'callback inside known wrapper strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef wrapper(fn):fn()\nHolder.target=Parser\nwrapper(lambda:setattr(Holder,"target",Model))\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'known empty helper preserves stored class default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return 1\nHolder.target=Parser\nnoop()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'closed empty constructor preserves stored class default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\nHolder.target=Parser\ndata=Data()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'closed literal initializer preserves stored class default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndata=Data(1)\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'zero argument object preserves stored class default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndata=object()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'literal unrelated setattr preserves target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nsetattr(Holder,"note",Model)\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'literal unrelated delattr preserves target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndelattr(Holder,"note")\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'saved class identity survives setattr default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nSaved=Holder.target\nsetattr(Holder,"target",Model)\nanswer=Saved.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'saved parser instance survives setattr default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nreader=Parser()\nsetattr(Holder,"target",Model)\nanswer=reader.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'uncalled setter remains inert default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef swap():setattr(Holder,"target",Model)\nHolder.target=Parser\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'known pure wrapper preserves target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return 1\ndef wrap():return noop()\nHolder.target=Parser\nwrap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'captured legacy plain before mutation argument default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nanswer=Holder.target.parse_file(setattr(Holder,"target",Model))\n' 0 'plain'
  _qm_receiver_case 'captured legacy model before mutation argument default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\nanswer=Holder.target.parse_file(setattr(Holder,"target",Parser))\n' 1 'model'
  _qm_receiver_case 'shadowed setter is opaque slot boundary default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef setattr(owner,member,value):owner.target=Model\nHolder.target=Parser\nsetattr(Holder,"note",Parser)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'shadowed setter is opaque slot boundary strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef setattr(owner,member,value):owner.target=Model\nHolder.target=Parser\nsetattr(Holder,"note",Parser)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'setter alias is opaque slot boundary default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nsetter=setattr\nsetter(Holder,"target",Model)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'setter alias is opaque slot boundary strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nsetter=setattr\nsetter(Holder,"target",Model)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'unknown noarg lambda future capture default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nopaque=lambda:setattr(Holder,"target",Model)\nopaque()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'unknown noarg lambda future capture strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nopaque=lambda:setattr(Holder,"target",Model)\nopaque()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'callable wrapper alias propagates opacity default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef wrapper(fn):fn()\nalias=wrapper\nHolder.target=Parser\nalias(lambda:setattr(Holder,"target",Model))\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'callable wrapper alias propagates opacity strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef wrapper(fn):fn()\nalias=wrapper\nHolder.target=Parser\nalias(lambda:setattr(Holder,"target",Model))\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field call captures under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_call_captures_contexts() {
  _qm_receiver_case 'future call capture callable instance field writer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __call__(self):Holder.target=Model\nswapper=Swapper()\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswapper()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture callable instance field writer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __call__(self):Holder.target=Model\nswapper=Swapper()\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswapper()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'future call capture lambda setattr field writer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswap=lambda:setattr(Holder,"target",Model)\nswap()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture lambda setattr field writer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswap=lambda:setattr(Holder,"target",Model)\nswap()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'future call capture direct literal setattr slot write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nsetattr(Holder,"target",Model)\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture direct literal setattr slot write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nsetattr(Holder,"target",Model)\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'future call capture known function literal setattr slot write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef swap():setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswap()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture known function literal setattr slot write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef swap():setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswap()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'future call capture dynamic member setattr slot write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nmember="target"\nsetattr(Holder,member,Model)\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture dynamic member setattr slot write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nmember="target"\nsetattr(Holder,member,Model)\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'future call capture constructor field writer after initial store default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __init__(self):Holder.target=Model\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswapper=Swapper()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture constructor field writer after initial store strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Swapper:\n def __init__(self):Holder.target=Model\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nswapper=Swapper()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'future call capture callback inside known wrapper default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef wrapper(fn):fn()\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nwrapper(lambda:setattr(Holder,"target",Model))\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'future call capture callback inside known wrapper strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef wrapper(fn):fn()\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nwrapper(lambda:setattr(Holder,"target",Model))\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field call entry under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_call_entry_contexts() {
  _qm_receiver_case 'one shot opaque before lookup default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():\n opaque()\n return Holder.target.parse_file("x")\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'one shot opaque before lookup strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():\n opaque()\n return Holder.target.parse_file("x")\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'one shot opaque after plain lookup default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n opaque()\n return value\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'one shot opaque after plain lookup strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n opaque()\n return value\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'one shot opaque after model lookup default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Model\ndef load():\n value=Holder.target.parse_file("x")\n opaque()\n return value\nanswer=load()\n' 1 'model'
  _qm_receiver_case 'one shot opaque after model lookup strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Model\ndef load():\n value=Holder.target.parse_file("x")\n opaque()\n return value\nanswer=load()\n' 1 'model' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'external opaque between definition and call default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nopaque()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'external opaque between definition and call strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nopaque()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'two calls reject entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n setattr(Holder,"target",Model)\n return value\nfirst=load()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'two calls reject entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n setattr(Holder,"target",Model)\n return value\nfirst=load()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'loop calls reject entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n setattr(Holder,"target",Model)\n return value\nfor item in [0,1]:answer=load()\n' 0 'unknown'
  _qm_receiver_case 'loop calls reject entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n setattr(Holder,"target",Model)\n return value\nfor item in [0,1]:answer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'comprehension calls reject entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n setattr(Holder,"target",Model)\n return value\nanswer=[load() for item in [0,1]][-1]\n' 0 'unknown'
  _qm_receiver_case 'comprehension calls reject entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():\n value=Holder.target.parse_file("x")\n setattr(Holder,"target",Model)\n return value\nanswer=[load() for item in [0,1]][-1]\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'alias call rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nalias=load\nopaque()\nanswer=alias()\n' 0 'unknown'
  _qm_receiver_case 'alias call rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nalias=load\nopaque()\nanswer=alias()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'wrapper call rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef wrap():return load()\nopaque()\nanswer=wrap()\n' 0 'unknown'
  _qm_receiver_case 'wrapper call rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef wrap():return load()\nopaque()\nanswer=wrap()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'escaped callback rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef dispatch(fn):return fn()\nopaque()\nanswer=dispatch(load)\n' 0 'unknown'
  _qm_receiver_case 'escaped callback rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef dispatch(fn):return fn()\nopaque()\nanswer=dispatch(load)\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'async rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\nimport asyncio\nasync def load():return Holder.target.parse_file("x")\nopaque()\nanswer=asyncio.run(load())\n' 0 'unknown'
  _qm_receiver_case 'async rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\nimport asyncio\nasync def load():return Holder.target.parse_file("x")\nopaque()\nanswer=asyncio.run(load())\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'generator rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():yield Holder.target.parse_file("x")\nopaque()\nanswer=next(load())\n' 0 'unknown'
  _qm_receiver_case 'generator rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nHolder.target=Parser\ndef load():yield Holder.target.parse_file("x")\nopaque()\nanswer=next(load())\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field call reentry under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_call_reentry_contexts() {
  _qm_receiver_case 'effectful attribute assignment rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setattr__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nsink.item=load()\nanswer=observed[-1]\n' 0 'unknown'
  _qm_receiver_case 'effectful attribute assignment rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setattr__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nsink.item=load()\nanswer=observed[-1]\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'effectful subscript assignment rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setitem__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nsink[0]=load()\nanswer=observed[-1]\n' 0 'unknown'
  _qm_receiver_case 'effectful subscript assignment rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setitem__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nsink[0]=load()\nanswer=observed[-1]\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'effectful unpacking assignment rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setattr__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nsink.item, other=(load(),None)\nanswer=observed[-1]\n' 0 'unknown'
  _qm_receiver_case 'effectful unpacking assignment rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setattr__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nsink.item, other=(load(),None)\nanswer=observed[-1]\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'effectful multi target assignment rejects entry certificate default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setattr__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nplain=sink.item=load()\nanswer=observed[-1]\n' 0 'unknown'
  _qm_receiver_case 'effectful multi target assignment rejects entry certificate strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Sink:\n def __setattr__(self,key,value):\n  setattr(Holder,"target",Model)\n  globals()["load"]()\nsink=Sink()\nHolder.target=Parser\nobserved=[]\ndef load():\n value=Holder.target.parse_file("x")\n observed.append(value)\n return value\nplain=sink.item=load()\nanswer=observed[-1]\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'opaque noarg reentry Parser to Model default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nentered=False\ndef opaque():\n global entered\n if not entered:\n  entered=True\n  setattr(Holder,"target",Model)\n  globals()["load"]()\ndef load():\n global result\n result=Holder.target.parse_file("x")\n opaque()\n return result\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'opaque noarg reentry Parser to Model strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nentered=False\ndef opaque():\n global entered\n if not entered:\n  entered=True\n  setattr(Holder,"target",Model)\n  globals()["load"]()\ndef load():\n global result\n result=Holder.target.parse_file("x")\n opaque()\n return result\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'opaque noarg reentry Model to Parser default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\nentered=False\ndef opaque():\n global entered\n if not entered:\n  entered=True\n  setattr(Holder,"target",Parser)\n  globals()["load"]()\ndef load():\n global result\n result=Holder.target.parse_file("x")\n opaque()\n return result\nanswer=load()\n' 1 'model'
  _qm_receiver_case 'opaque noarg reentry Model to Parser strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\nentered=False\ndef opaque():\n global entered\n if not entered:\n  entered=True\n  setattr(Holder,"target",Parser)\n  globals()["load"]()\ndef load():\n global result\n result=Holder.target.parse_file("x")\n opaque()\n return result\nanswer=load()\n' 1 'model' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field call annotations under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_call_annotations_contexts() {
  _qm_receiver_case 'setter owner formal shadows outer class default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef set_note(Holder):setattr(Holder,"note",Model)\nclass TrapMeta(type):\n def __setattr__(cls,key,value):Holder.target=Model\nclass Trap(metaclass=TrapMeta):pass\nHolder.target=Parser\nset_note(Trap)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'setter owner formal shadows outer class strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef set_note(Holder):setattr(Holder,"note",Model)\nclass TrapMeta(type):\n def __setattr__(cls,key,value):Holder.target=Model\nclass Trap(metaclass=TrapMeta):pass\nHolder.target=Parser\nset_note(Trap)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'legacy annotation field effect ordinary default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'legacy annotation field effect ordinary strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'legacy annotation field effect posonly default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(marker:setattr(Holder,"target",Model),/):pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'legacy annotation field effect posonly strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(marker:setattr(Holder,"target",Model),/):pass\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'legacy annotation field effect kwonly default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(*,marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'legacy annotation field effect kwonly strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(*,marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'legacy annotation field effect vararg default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(*marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'legacy annotation field effect vararg strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(*marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'legacy annotation field effect kwarg default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(**marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'legacy annotation field effect kwarg strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure(**marker:setattr(Holder,"target",Model)):pass\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'legacy annotation field effect return default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure()->setattr(Holder,"target",Model):pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'legacy annotation field effect return strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\ndef configure()->setattr(Holder,"target",Model):pass\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field constructor proofs under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_constructor_proofs_contexts() {
  # Protocol/entry regression insertion begins.
  # Protects: ordered protocol effects, captured namespace-owner proof and initial MODEL evidence.
  # Detects: callback false clears and post-key owner laundering; preserves finite CLASS/CSub data.
  # Needs: staged scanner/Ruff/ast-grep; inert runtime and missing-TryStar controls are separate evidence.
  # Code: protocol_event/protocol_effects/visit_Subscript/conservative_control/record_first_model_lookup.
  _qm_receiver_case 'protocol entry Subscript store grafts constructor descriptor default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Data.value=Slot()\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nbox[0]=1\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry Subscript store grafts constructor descriptor strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Data.value=Slot()\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nbox[0]=1\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry Subscript delete callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndel box[0]\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry Subscript delete callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndel box[0]\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry Subscript augmented store callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nbox[0]+=1\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry Subscript augmented store callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nbox[0]+=1\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry For Subscript target callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nfor box[0] in (1,):pass\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry For Subscript target callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nfor box[0] in (1,):pass\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry eager comprehension Subscript target callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\n[0 for box[0] in (1,)]\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry eager comprehension Subscript target callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Box:\n def __setitem__(self,key,value):Holder.target=Model\n def __delitem__(self,key):Holder.target=Model\n def __getitem__(self,key):return 0\nbox=Box()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\n[0 for box[0] in (1,)]\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry module BinOp callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __add__(self,value):\n  Holder.target=Model\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ntrigger+1\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry module BinOp callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __add__(self,value):\n  Holder.target=Model\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ntrigger+1\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry module Subscript read callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __getitem__(self,key):\n  Holder.target=Model\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ntrigger[0]\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry module Subscript read callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __getitem__(self,key):\n  Holder.target=Model\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ntrigger[0]\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry With enter callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Ctx:\n def __enter__(self):\n  Holder.target=Model\n  return None\n def __exit__(self,*args):return False\nctx=Ctx()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nwith ctx:pass\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry With enter callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Ctx:\n def __enter__(self):\n  Holder.target=Model\n  return None\n def __exit__(self,*args):return False\nctx=Ctx()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nwith ctx:pass\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry Match subject definite entry Model default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nreceiver=Model\nmatch receiver.parse_file("x"):\n case value:\n  answer=value\n  receiver=Parser()\n' 1 model
  _qm_receiver_case 'protocol entry Match subject definite entry Model strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nreceiver=Model\nmatch receiver.parse_file("x"):\n case value:\n  answer=value\n  receiver=Parser()\n' 1 model 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry Try body definite entry Model default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nreceiver=Model\ntry:\n answer=receiver.parse_file("x")\nexcept Exception:\n receiver=Parser()\n' 1 model
  _qm_receiver_case 'protocol entry Try body definite entry Model strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nreceiver=Model\ntry:\n answer=receiver.parse_file("x")\nexcept Exception:\n receiver=Parser()\n' 1 model 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry For first iteration definite entry Model default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nreceiver=Model\nfor item in (1,):\n answer=receiver.parse_file("x")\n receiver=Parser()\n' 1 model
  _qm_receiver_case 'protocol entry For first iteration definite entry Model strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nreceiver=Model\nfor item in (1,):\n answer=receiver.parse_file("x")\n receiver=Parser()\n' 1 model 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry finite CLASS ordinary data store precision default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.other=1\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'protocol entry finite CLASS ordinary data store precision strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.other=1\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry unproved dict-owner getter returns callback mapping default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass CallbackBox:\n def __setitem__(self,key,value):Parser.parse_file=Model.parse_file\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":return CallbackBox()\n  return object.__getattribute__(self,name)\nopaque=Proxy()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass OrdinaryClass:pass\nopaque.__dict__["other"]=1\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry unproved dict-owner getter returns callback mapping strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass CallbackBox:\n def __setitem__(self,key,value):Parser.parse_file=Model.parse_file\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":return CallbackBox()\n  return object.__getattribute__(self,name)\nopaque=Proxy()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass OrdinaryClass:pass\nopaque.__dict__["other"]=1\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry dict-owner key rebind cannot certify captured mapping default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass CallbackBox:\n def __setitem__(self,key,value):Parser.parse_file=Model.parse_file\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":return CallbackBox()\n  return object.__getattribute__(self,name)\nopaque=Proxy()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass OrdinaryClass:pass\nopaque.__dict__[(opaque:=OrdinaryClass)]=1\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol entry dict-owner key rebind cannot certify captured mapping strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass CallbackBox:\n def __setitem__(self,key,value):Parser.parse_file=Model.parse_file\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":return CallbackBox()\n  return object.__getattribute__(self,name)\nopaque=Proxy()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass OrdinaryClass:pass\nopaque.__dict__[(opaque:=OrdinaryClass)]=1\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol entry closed CLASS CSub namespace-data mappingproxy guard default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass OrdinaryClass:\n @classmethod\n def __class_getitem__(cls,key):return cls\ntry:\n OrdinaryClass.__dict__["other"]=1\nexcept TypeError:\n mappingproxy_rejected=True\nanswer=Parser.parse_file("x")\n' 0 plain
  _qm_receiver_case 'protocol entry closed CLASS CSub namespace-data mappingproxy guard strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass OrdinaryClass:\n @classmethod\n def __class_getitem__(cls,key):return cls\ntry:\n OrdinaryClass.__dict__["other"]=1\nexcept TypeError:\n mappingproxy_rejected=True\nanswer=Parser.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  # Namespace getter prefix insertion begins.
  # Protects: unproved __dict__ getter effects before legacy calls in the key.
  # Detects: a late Store event cannot repair an earlier false-plain key lookup.
  # Needs: real staged scanner; runtime mapping-key observer is separate inert evidence.
  # Code: apply_namespace_getter_event/visit_Subscript/visit_AugAssign.
  _qm_receiver_case 'protocol entry unproved namespace getter before legacy key lookup default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nmapping={}\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":\n   Parser.parse_file=Model.parse_file\n   return mapping\n  return object.__getattribute__(self,name)\nopaque=Proxy()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nopaque.__dict__[Parser.parse_file("x")]=1\nanswer=next(iter(mapping))\n' 0 unknown
  _qm_receiver_case 'protocol entry unproved namespace getter before legacy key lookup strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nmapping={}\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":\n   Parser.parse_file=Model.parse_file\n   return mapping\n  return object.__getattribute__(self,name)\nopaque=Proxy()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nopaque.__dict__[Parser.parse_file("x")]=1\nanswer=next(iter(mapping))\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  # Namespace getter prefix insertion ends.
  # Protocol/entry regression insertion ends.
  # Bulk lexical FIELD regression insertion begins.
  # Protects: unsafe loop/comp target callbacks and nested generator-local owner shadowing.
  # Detects: strict false clears; preserves finite CLASS and supported class-local Alias stores.
  # Needs: hermetic scanner/Ruff/ast-grep; external inert-runtime truth is source-scoped.
  # Code: PydanticReceivers.comprehension/conservative_control/field_write_effects.
  _qm_receiver_case 'bulk lexical unsafe for Attribute target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nfor alias.other in (1,):pass\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'bulk lexical unsafe for Attribute target strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nfor alias.other in (1,):pass\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical unsafe eager comprehension Attribute target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\n[0 for alias.other in (1,)]\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'bulk lexical unsafe eager comprehension Attribute target strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\n[0 for alias.other in (1,)]\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical finite CLASS for ordinary other target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nfor Holder.other in (1,):pass\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'bulk lexical finite CLASS for ordinary other target strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nfor Holder.other in (1,):pass\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical finite CLASS comprehension ordinary other target default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\n[0 for Holder.other in (1,)]\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'bulk lexical finite CLASS comprehension ordinary other target strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\n[0 for Holder.other in (1,)]\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical unsafe class-body Attribute callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Built:\n alias.other=1\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'bulk lexical unsafe class-body Attribute callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Built:\n alias.other=1\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical finite CLASS class-body ordinary other store default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Built:\n Holder.other=1\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'bulk lexical finite CLASS class-body ordinary other store strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Built:\n Holder.other=1\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical finite class-local Alias ordinary store default' 'class Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Built:\n Alias=Holder\n Alias.other=1\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'bulk lexical finite class-local Alias ordinary store strict' 'class Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nclass Built:\n Alias=Holder\n Alias.other=1\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'bulk lexical nested comprehension local Alias shadows global CLASS default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nopaque=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Alias:pass\nHolder.target=Parser\nfor once in (1,):\n [0 for Alias in (opaque,) for Alias.other in (1,)]\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'bulk lexical nested comprehension local Alias shadows global CLASS strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nopaque=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Alias:pass\nHolder.target=Parser\nfor once in (1,):\n [0 for Alias in (opaque,) for Alias.other in (1,)]\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  # Bulk lexical FIELD regression insertion ends.
  # Deferred/unresolved FIELD regression insertion begins.
  # Protects: constructor captures and write callbacks independent of attribute spelling.
  # Detects: a later graft, unresolved setter, missed delete or unsafe narrow marker.
  # Needs: staged default/strict scanner; no real Pydantic/provider/device execution.
  # Breadcrumb: receiver_capture_suffix, field_write_effects, deferred_bindings, invalidate_target.
  _qm_receiver_case 'deferred unresolved F1 single later descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nData.value=Slot()\nanswer=run()\n' 0 unknown
  _qm_receiver_case 'deferred unresolved F1 single later descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nData.value=Slot()\nanswer=run()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved F1 class-body int before later descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n value=1\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nData.value=Slot()\nanswer=run()\n' 0 unknown
  _qm_receiver_case 'deferred unresolved F1 class-body int before later descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n value=1\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nData.value=Slot()\nanswer=run()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved F2 unresolved owner overwrites recorded class default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nalias=[Holder][0]\nalias.target=Model\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved F2 unresolved owner overwrites recorded class strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nalias=[Holder][0]\nalias.target=Model\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved F2 unresolved owner grafts constructor descriptor default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nalias=[Data][0]\nalias.value=Slot()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved F2 unresolved owner grafts constructor descriptor strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nalias=[Data][0]\nalias.value=Slot()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved module int seed before def without later write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nData.value=1\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain
  _qm_receiver_case 'deferred unresolved module int seed before def without later write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nData.value=1\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved class-body int before def without later write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n value=1\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain
  _qm_receiver_case 'deferred unresolved class-body int before def without later write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n value=1\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved annotation-only direct field is not a store default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nData.value: Slot\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain
  _qm_receiver_case 'deferred unresolved annotation-only direct field is not a store strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nData.value: Slot\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved annotation-only unresolved field is not a store default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nalias=[Data][0]\nalias.value: Slot\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain
  _qm_receiver_case 'deferred unresolved annotation-only unresolved field is not a store strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nalias=[Data][0]\nalias.value: Slot\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nanswer=run()\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved F2 opaque setter changes different field default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nHolder.target=Parser\nalias.other=1\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved F2 opaque setter changes different field strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nHolder.target=Parser\nalias.other=1\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved unresolved owner valued annotation overwrites slot default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nalias=[Holder][0]\nalias.target: object = Model\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved unresolved owner valued annotation overwrites slot strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nalias=[Holder][0]\nalias.target: object = Model\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved unresolved owner deletion reveals inherited Model slot default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass ParentHolder:\n target=Model\nclass Holder(ParentHolder):pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nalias=[Holder][0]\ndel alias.target\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved unresolved owner deletion reveals inherited Model slot strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass ParentHolder:\n target=Model\nclass Holder(ParentHolder):pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nalias=[Holder][0]\ndel alias.target\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved known CSub class exact store preserves other owner slot default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData.target=Model\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'deferred unresolved known CSub class exact store preserves other owner slot strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData.target=Model\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved compound loop prefix retained for deferred constructor capture default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nfor turn in (0,1):\n if turn:\n  Data.value=Slot()\n  answer=run()\n else:\n  def run():\n   Data(1)\n   return Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved compound loop prefix retained for deferred constructor capture strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nfor turn in (0,1):\n if turn:\n  Data.value=Slot()\n  answer=run()\n else:\n  def run():\n   Data(1)\n   return Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved legacy spelling opaque setter preservation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nalias.parse_file=1\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'deferred unresolved legacy spelling opaque setter preservation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Holder.target=Model\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nalias.parse_file=1\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred unresolved future dunder spelling descriptor callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Data.value=Slot()\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nalias.__other__=1\nanswer=run()\n' 0 unknown
  _qm_receiver_case 'deferred unresolved future dunder spelling descriptor callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __setattr__(self,name,value):Data.value=Slot()\nalias=[Proxy()][0]\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\ndef run():\n Data(1)\n return Holder.target.parse_file("x")\nalias.__other__=1\nanswer=run()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  # Deferred/unresolved FIELD regression insertion ends.
  # Descriptor-absence regression insertion begins.
  # Protects: current live constructor Store slots after direct/builtin/helper writes.
  # Detects: absent metadata mistaken for descriptor-free proof; preserves fresh classes.
  # Needs: real staged default/strict scanner; no runtime descriptor/provider execution.
  # Breadcrumb: constructor_write_keys, record_class_store, project_builtin_mutation.
  _qm_receiver_case 'descriptor absence builtin ordinary descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nsetattr(Data,"value",Slot())\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence builtin ordinary descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nsetattr(Data,"value",Slot())\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence helper ordinary descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence helper ordinary descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence private attribute descriptor guard counterpart default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.__value=value\nsetattr(Data,"_Data__value",Slot())\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence private attribute descriptor guard counterpart strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.__value=value\nsetattr(Data,"_Data__value",Slot())\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence fresh class after prior same-member helper write default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Existing:\n def __init__(self,value):self.value=value\ndef install():Existing.value=Slot()\ninstall()\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'descriptor absence fresh class after prior same-member helper write strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Existing:\n def __init__(self,value):self.value=value\ndef install():Existing.value=Slot()\ninstall()\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence class reference live only in stored-class slot default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nclass Kept:pass\nKept.target=Data\nData=None\ndef install():Kept.target.value=Slot()\ninstall()\nHolder.target=Parser\nKept.target(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence class reference live only in stored-class slot strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nclass Kept:pass\nKept.target=Data\nData=None\ndef install():Kept.target.value=Slot()\ninstall()\nHolder.target=Parser\nKept.target(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence unrelated member write preserves initializer absence default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.note=Slot()\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'descriptor absence unrelated member write preserves initializer absence strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.note=Slot()\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence explicit exact-int store renews current field proof default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ninstall()\nData.value=1\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'descriptor absence explicit exact-int store renews current field proof strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ninstall()\nData.value=1\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence no write leaves legitimate field absence default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'descriptor absence no write leaves legitimate field absence strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only direct graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nData.value=Slot()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only direct graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nData.value=Slot()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only builtin graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nsetattr(Data,"value",Slot())\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only builtin graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nsetattr(Data,"value",Slot())\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only helper graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only helper graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only no graft preserves constructor projection default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain
  _qm_receiver_case 'descriptor absence CLASS_SUBSCRIPT-only no graft preserves constructor projection strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n @classmethod\n def __class_getitem__(cls,key):return cls\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence wildcard helper descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nname="value"\ndef install():setattr(Data,name,Slot())\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence wildcard helper descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nname="value"\ndef install():setattr(Data,name,Slot())\ninstall()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence alias helper descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\nalias=install\nalias()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence alias helper descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\nalias=install\nalias()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'descriptor absence wrapper helper descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ndef wrapper():install()\nwrapper()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'descriptor absence wrapper helper descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\ndef install():Data.value=Slot()\ndef wrapper():install()\nwrapper()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  # Descriptor-absence regression insertion ends.
  _qm_receiver_case 'callee receiver construction effect default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nclass Data:\n def __init__(self,value):self.value=value\n def parse_file(self,path):return "Data"\nHolder.target=Parser\ndef wrapper():Data(opaque()).parse_file("unused")\nwrapper()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'callee receiver construction effect strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Model)\nclass Data:\n def __init__(self,value):self.value=value\n def parse_file(self,path):return "Data"\nHolder.target=Parser\ndef wrapper():Data(opaque()).parse_file("unused")\nwrapper()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'constructor descriptor write effect default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n value=Slot()\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'constructor descriptor write effect strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n value=Slot()\n def __init__(self,value):self.value=value\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'late constructor descriptor graft default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nData.value=Slot()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'late constructor descriptor graft strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Slot:\n def __set__(self,obj,value):Holder.target=Model\nclass Data:\n def __init__(self,value):self.value=value\nData.value=Slot()\nHolder.target=Parser\nData(1)\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'current callable code invalidation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return None\ndef evil():Holder.target=Model\nHolder.target=Parser\nnoop.__code__=evil.__code__\nnoop()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'current callable code invalidation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return None\ndef evil():Holder.target=Model\nHolder.target=Parser\nnoop.__code__=evil.__code__\nnoop()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred callable code invalidation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return None\ndef evil():Holder.target=Model\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nnoop.__code__=evil.__code__\nnoop()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'deferred callable code invalidation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return None\ndef evil():Holder.target=Model\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nnoop.__code__=evil.__code__\nnoop()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'deferred aliased callable code invalidation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return None\ndef evil():Holder.target=Model\nHolder.target=Parser\nalias=noop\ndef load():return Holder.target.parse_file("x")\nalias.__code__=evil.__code__\nnoop()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'deferred aliased callable code invalidation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\ndef noop():return None\ndef evil():Holder.target=Model\nHolder.target=Parser\nalias=noop\ndef load():return Holder.target.parse_file("x")\nalias.__code__=evil.__code__\nnoop()\nanswer=load()\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'declared destructor refuses empty constructor default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:\n def __del__(self):Holder.target=Model\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'declared destructor refuses empty constructor strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:\n def __del__(self):Holder.target=Model\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'assigned destructor refuses empty constructor default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\nData.__del__=destroy\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'assigned destructor refuses empty constructor strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\nData.__del__=destroy\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'builtin installed destructor refuses empty constructor default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\nsetattr(Data,"__del__",destroy)\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'builtin installed destructor refuses empty constructor strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\nsetattr(Data,"__del__",destroy)\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field stored int under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_stored_int_contexts() {
  _qm_receiver_case 'stored int evil overwrite after def default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nHolder.note=Evil()\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int evil overwrite after def strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nHolder.note=Evil()\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int opaque prior replacement default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nopaque=lambda:setattr(Holder,"note",Evil())\nopaque()\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int opaque prior replacement strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nopaque=lambda:setattr(Holder,"note",Evil())\nopaque()\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int alias replacement default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nAlias=Holder\nAlias.note=Evil()\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int alias replacement strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nAlias=Holder\nAlias.note=Evil()\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int unknown join default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\ncondition=False\nif condition:Holder.note=1\nelse:Holder.note=Evil()\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int unknown join strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\ncondition=False\nif condition:Holder.note=1\nelse:Holder.note=Evil()\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int bool outside exact domain default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=True\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int bool outside exact domain strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=True\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int subclass outside exact domain default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass EvilInt(int):\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=EvilInt(1)\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int subclass outside exact domain strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass EvilInt(int):\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=EvilInt(1)\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int Name rhs outside exact domain default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nliteral=1\nHolder.note=literal\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int Name rhs outside exact domain strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nliteral=1\nHolder.note=literal\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int non Add outside exact domain default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note -= 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int non Add outside exact domain strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note -= 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int known call alias invalidates default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef replace():Holder.note=Evil()\nalias=replace\ndef swap():Holder.note += 1\nalias()\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int known call alias invalidates strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef replace():Holder.note=Evil()\nalias=replace\ndef swap():Holder.note += 1\nalias()\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int uncalled writer does not leak default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef hidden():Holder.note=Evil()\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'stored int uncalled writer does not leak strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef hidden():Holder.note=Evil()\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int both int branches retain type default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nif True:Holder.note=1\nelse:Holder.note=2\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'stored int both int branches retain type strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nif True:Holder.note=1\nelse:Holder.note=2\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int reseeded literal after def default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nHolder.note=2\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'stored int reseeded literal after def strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nHolder.note=2\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'plain' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int second operation consumes proof default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nswap()\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int second operation consumes proof strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nswap()\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int earlier write in same helper default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():\n Holder.note=Evil()\n Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int earlier write in same helper strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():\n Holder.note=Evil()\n Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'stored int projection mutation forfeits proof default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef replacement(self):pass\nHolder.__init__=replacement\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'stored int projection mutation forfeits proof strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\nHolder.note=1\ndef replacement(self):pass\nHolder.__init__=replacement\ndef swap():Holder.note += 1\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'isolated stored int operator interval default' 'class Trigger:\n def __add__(self,other):\n  Holder.note=Evil()\n  return 0\ntrigger=Trigger()\nfrom pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nvalue=trigger+0\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'isolated stored int operator interval strict' 'class Trigger:\n def __add__(self,other):\n  Holder.note=Evil()\n  return 0\ntrigger=Trigger()\nfrom pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nvalue=trigger+0\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'isolated stored int getter interval default' 'class Trigger:\n @property\n def value(self):\n  Holder.note=Evil()\n  return 0\ntrigger=Trigger()\nfrom pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nvalue=trigger.value\nswap()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'isolated stored int getter interval strict' 'class Trigger:\n @property\n def value(self):\n  Holder.note=Evil()\n  return 0\ntrigger=Trigger()\nfrom pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,other):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef swap():Holder.note += 1\nvalue=trigger.value\nswap()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field namespace calls under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_namespace_calls_contexts() {
  _qm_receiver_case 'captured builtin owner mutation default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\nclass Other:\n @classmethod\n def parse_file(cls,path):return "Other"\ndef destroy(self):Holder.target=Model\nSaved=Data\nsetattr(Data,"__del__",((Data:=Other),destroy)[1])\nHolder.target=Parser\nSaved()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'captured builtin owner mutation strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\nclass Other:\n @classmethod\n def parse_file(cls,path):return "Other"\ndef destroy(self):Holder.target=Model\nSaved=Data\nsetattr(Data,"__del__",((Data:=Other),destroy)[1])\nHolder.target=Parser\nSaved()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'rebound unrelated class is preserved default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\nclass Other:\n @classmethod\n def parse_file(cls,path):return "Other"\ndef destroy(self):Holder.target=Model\nSaved=Data\nsetattr(Data,"__del__",((Data:=Other),destroy)[1])\nHolder.target=Parser\nSaved()\nanswer=Data.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'rebound unrelated class is preserved strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\nclass Other:\n @classmethod\n def parse_file(cls,path):return "Other"\ndef destroy(self):Holder.target=Model\nSaved=Data\nsetattr(Data,"__del__",((Data:=Other),destroy)[1])\nHolder.target=Parser\nSaved()\nanswer=Data.parse_file("x")\n' 0 'plain' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'direct namespace installer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef install():setattr(Data,"__del__",destroy)\ninstall()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'direct namespace installer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef install():setattr(Data,"__del__",destroy)\ninstall()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'nested namespace installer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef install():setattr(Data,"__del__",destroy)\ndef outer():install()\nouter()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'nested namespace installer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef install():setattr(Data,"__del__",destroy)\ndef outer():install()\nouter()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'forward namespace installer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef outer():install()\ndef install():setattr(Data,"__del__",destroy)\nouter()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'forward namespace installer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef outer():install()\ndef install():setattr(Data,"__del__",destroy)\nouter()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'aliased namespace installer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef install():setattr(Data,"__del__",destroy)\nalias=install\nalias()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'aliased namespace installer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef install():setattr(Data,"__del__",destroy)\nalias=install\nalias()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'named lambda namespace installer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ninstall=lambda:setattr(Data,"__del__",destroy)\ninstall()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'named lambda namespace installer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ninstall=lambda:setattr(Data,"__del__",destroy)\ninstall()\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'callback namespace installer default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef run(fn):fn()\nrun(lambda:setattr(Data,"__del__",destroy))\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'unknown'
  _qm_receiver_case 'callback namespace installer strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef run(fn):fn()\nrun(lambda:setattr(Data,"__del__",destroy))\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 1 'unknown' 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'uninvoked namespace callback stays inert default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef ignore(fn):return None\nignore(lambda:setattr(Data,"__del__",destroy))\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'plain'
  _qm_receiver_case 'uninvoked namespace callback stays inert strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Data:pass\ndef destroy(self):Holder.target=Model\ndef ignore(fn):return None\nignore(lambda:setattr(Data,"__del__",destroy))\nHolder.target=Parser\nData()\nanswer=Holder.target.parse_file("x")\n' 0 'plain' 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: field model prefix under default and strict receiver policy.
# Detects: stale stored-class facts, unsafe empty effects or false MODEL promotion.
# Needs: actual staged scanner, Git, ast-grep and Ruff; no device/provider calls.
# Breadcrumb: hooks/common/mandate_scan.py field_body/deferred_bindings/receiver_effect/record_called_model_prefix.
_qm_receiver_field_model_prefix_contexts() {
  _qm_receiver_case 'MODEL prefix first Model assignment before later opaque' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Parser)\nHolder.target=Model\ndef load():\n value=Holder.target.parse_file("x")\n opaque()\n return value\nanswer=load()\n' 1 'model'
  _qm_receiver_case 'MODEL prefix opaque before inner lookup forbids witness' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Parser)\nHolder.target=Model\ndef load():\n opaque()\n return Holder.target.parse_file("x")\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix external opaque before invocation forbids witness' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nopaque=lambda:setattr(Holder,"target",Parser)\nHolder.target=Model\ndef load():return Holder.target.parse_file("x")\nopaque()\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix receiver assignment RHS local' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():\n Holder=Holder.target.parse_file("x")\n return Holder\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix late local assignment' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():\n return Holder.target.parse_file("x")\n Holder=Model\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix late annotation only local' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():\n return Holder.target.parse_file("x")\n Holder:object\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix late MatchMapping rest local' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():\n return Holder.target.parse_file("x")\n match {}:\n  case {**Holder}:pass\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix late local deletion' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():\n return Holder.target.parse_file("x")\n del Holder\nanswer=load()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix real global declaration preserves global Model' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():\n global Holder\n return Holder.target.parse_file("x")\nanswer=load()\n' 1 'model'
  _qm_receiver_case 'MODEL prefix module callee invoked under foreign local frame' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Parser\ndef load():return Holder.target.parse_file("x")\nclass Other:pass\nOther.target=Model\ndef caller():\n Holder=Other\n return load()\nanswer=caller()\n' 0 'unknown'
  _qm_receiver_case 'MODEL prefix rebound function identity forbids witness' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nHolder.target=Model\ndef load():return Holder.target.parse_file("x")\ndef alternate():return "Parser"\nload=alternate\nanswer=load()\n' 0 'unknown'
}


# Protects: implicit operator/callback effects reach the actual receiver view.
# Detects: false PLAIN after iadd/rich-compare/unary or namespace-mapping callbacks,
# and lost effects across loops, comprehensions, captures and argument rebinding.
# Needs: staged scanner, genuine ast-grep and Ruff; fixtures perform no provider I/O.
# Breadcrumb: hooks/common/mandate_scan.py protocol_event/visit_Compare/visit_Call,
# comprehension/conservative_control/deferred_bindings and ReceiverBinding.protocol_effect.
_qm_receiver_protocol_consumer_contexts() {
  _qm_receiver_case 'protocol consumer inplace Name callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __iadd__(self,value):\n  Parser.parse_file=Model.parse_file\n  return self\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ntrigger+=1\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer inplace Name callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __iadd__(self,value):\n  Parser.parse_file=Model.parse_file\n  return self\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ntrigger+=1\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer comparison callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __lt__(self,value):\n  Parser.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ntrigger<0\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer comparison callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __lt__(self,value):\n  Parser.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ntrigger<0\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer unary callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\n-trigger\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer unary callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\n-trigger\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer chained comparison callback before later operand default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __lt__(self,value):\n  Parser.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nresult=(trigger < None is not (answer:=Parser.parse_file("x")))\n' 0 unknown
  _qm_receiver_case 'protocol consumer chained comparison callback before later operand strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __lt__(self,value):\n  Parser.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nresult=(trigger < None is not (answer:=Parser.parse_file("x")))\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer identity first lookup precedes later comparison default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __lt__(self,value):\n  Parser.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nresult=(None is not trigger < (answer:=Parser.parse_file("x")))\n' 0 plain
  _qm_receiver_case 'protocol consumer identity first lookup precedes later comparison strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __lt__(self,value):\n  Parser.parse_file=Model.parse_file\n  return True\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nresult=(None is not trigger < (answer:=Parser.parse_file("x")))\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer first Model evidence precedes future operator default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nanswer=Model.parse_file("x")\n-trigger\n' 1 model
  _qm_receiver_case 'protocol consumer first Model evidence precedes future operator strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nanswer=Model.parse_file("x")\n-trigger\n' 1 model 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer instance namespace update mutator default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nobj=Parser()\nobj.__dict__.update(parse_file=Model.parse_file)\nanswer=obj.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer instance namespace update mutator strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nobj=Parser()\nobj.__dict__.update(parse_file=Model.parse_file)\nanswer=obj.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer unproved namespace getter before update kwargs default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":\n   Parser.parse_file=Model.parse_file\n   return {}\n  return object.__getattribute__(self,name)\ndef make():return Proxy()\nobj=make()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nobj.__dict__.update(seen=(answer:=Parser.parse_file("x")))\n' 0 unknown
  _qm_receiver_case 'protocol consumer unproved namespace getter before update kwargs strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Proxy:\n def __getattribute__(self,name):\n  if name=="__dict__":\n   Parser.parse_file=Model.parse_file\n   return {}\n  return object.__getattribute__(self,name)\ndef make():return Proxy()\nobj=make()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nobj.__dict__.update(seen=(answer:=Parser.parse_file("x")))\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer ordinary instance namespace getter retains kwarg prefix default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nobj=Parser()\nobj.__dict__.update(seen=(answer:=Parser.parse_file("x")))\n' 0 plain
  _qm_receiver_case 'protocol consumer ordinary instance namespace getter retains kwarg prefix strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nobj=Parser()\nobj.__dict__.update(seen=(answer:=Parser.parse_file("x")))\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer instance namespace setdefault mutator default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nobj=Parser()\nobj.__dict__.setdefault("parse_file",Model.parse_file)\nanswer=obj.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer instance namespace setdefault mutator strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n def parse_file(self,path):return "Parser"\nobj=Parser()\nobj.__dict__.setdefault("parse_file",Model.parse_file)\nanswer=obj.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer nested helper consumes stored int default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,value):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef poison():Holder.note=Evil()\ndef inner():Holder.note+=1\ndef outer():\n poison()\n inner()\nouter()\nanswer=Holder.target.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer nested helper consumes stored int strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\nclass Holder:pass\nclass Evil:\n def __iadd__(self,value):\n  Holder.target=Model\n  return self\nHolder.target=Parser\nHolder.note=1\ndef poison():Holder.note=Evil()\ndef inner():Holder.note+=1\ndef outer():\n poison()\n inner()\nouter()\nanswer=Holder.target.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer direct full-mode reference default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\nbump()\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer direct full-mode reference strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\nbump()\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer comprehension outward known callee default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\n[bump() for item in [1]]\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer comprehension outward known callee strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\n[bump() for item in [1]]\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer loop outward known callee default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\nfor item in [1]:bump()\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer loop outward known callee strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\nfor item in [1]:bump()\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer anchored deferred before known callee default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\ndef load():return Parser.parse_file("x")\nbump()\nanswer=load()\n' 0 unknown
  _qm_receiver_case 'protocol consumer anchored deferred before known callee strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef bump():-trigger\ndef load():return Parser.parse_file("x")\nbump()\nanswer=load()\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer known invoke Name callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ndef cb():-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer known invoke Name callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ndef cb():-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer known invoke Lambda callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer known invoke Lambda callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer lifecycle branch union default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\nflag=False\nif flag:cb=lambda:None\nelse:cb=lambda:-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer lifecycle branch union strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\nflag=False\nif flag:cb=lambda:None\nelse:cb=lambda:-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer lifecycle empty loop retains callback default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:-trigger\nfor item in []:cb=None\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer lifecycle empty loop retains callback strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:-trigger\nfor item in []:cb=None\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer lifecycle hidden local stays local default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:None\ndef hidden():\n cb=lambda:-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 0 plain
  _qm_receiver_case 'protocol consumer lifecycle hidden local stays local strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:None\ndef hidden():\n cb=lambda:-trigger\ninvoke(cb)\nanswer=Parser.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer lifecycle Name copy default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:-trigger\nalias=cb\ninvoke(alias)\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer lifecycle Name copy strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(cb):cb()\ncb=lambda:-trigger\nalias=cb\ninvoke(alias)\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer lifecycle captured pure callee before rebind default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef safe(value):return None\ncb=safe\nbad=lambda:-trigger\ncb((cb:=bad))\nanswer=Parser.parse_file("x")\n' 0 plain
  _qm_receiver_case 'protocol consumer lifecycle captured pure callee before rebind strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef safe(value):return None\ncb=safe\nbad=lambda:-trigger\ncb((cb:=bad))\nanswer=Parser.parse_file("x")\n' 0 plain 'mandate.pydantic_v1_ambiguous=block\n'
  _qm_receiver_case 'protocol consumer lifecycle early callback argument before rebind default' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(first,second):first()\ncb=lambda:-trigger\npure=lambda:None\ninvoke(cb,(cb:=pure))\nanswer=Parser.parse_file("x")\n' 0 unknown
  _qm_receiver_case 'protocol consumer lifecycle early callback argument before rebind strict' 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\ndef invoke(first,second):first()\ncb=lambda:-trigger\npure=lambda:None\ninvoke(cb,(cb:=pure))\nanswer=Parser.parse_file("x")\n' 1 unknown 'mandate.pydantic_v1_ambiguous=block\n'
}

# Protects: setup summaries exclude only future implicit protocol contributions.
# Detects: cold capture poisoning, lost explicit mutation or a disabled full mode.
# Needs: Python stdlib and the checked-out scanner; no Pydantic import/execution.
# Breadcrumb: hooks/common/mandate_scan.py call_effects/namespace_effects/field_body.
# The maintained module prescan runs; only its top-level body walk is suppressed.
# Warm cache checks use real visitors, never injected catalogue/effect bits.
_qm_receiver_protocol_modes_contract() {
  if ! gg_has_python; then
    t_skip 'receiver protocol summary mode contract (13 controls) needs Python'
    return 0
  fi
  _qmr_contract_log="$GG_T_TMPROOT/_qm_receiver_protocol_modes_contract.log"
  if "$(gg_python)" -I -B - "$GG_ROOT" >"$_qmr_contract_log" 2>&1 <<'PY'
import ast
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("receiver_contract_scanner", root / "hooks/common/mandate_scan.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

import ast
import hashlib


def run(module):
    preconditions=[]
    def cold(text):
     local=module.PydanticReceivers(text);tree=ast.parse(text);initial=dict(local.env);initial_capture=local.capture_call_effect;had_override='generic_visit' in local.__dict__;previous=local.generic_visit;suppressed=[]
     def skip_top(node):
      assert node is tree and isinstance(node,ast.Module)
      suppressed.append(type(node).__name__)
     local.generic_visit=skip_top
     try:local.visit(tree)
     finally:
      if had_override:local.generic_visit=previous
      else:del local.generic_visit
     expected={n.name for n in tree.body if isinstance(n,ast.FunctionDef)}
     restored=local.generic_visit==previous
     assert local.env==initial and local.capture_call_effect==initial_capture and suppressed==['Module'] and restored
     assert expected<=set(local.field_definitions)
     preconditions.append(dict(source_sha256=hashlib.sha256(text.encode()).hexdigest(),registered=sorted(local.field_definitions),env_initial_count=len(initial),env_cold_equal=True,capture_restored=True,generic_visit_restored=restored,suppressed=suppressed))
     return local,tree
    rows=[]
    def check(label,passed,**facts):rows.append(dict(label=label,pass_=passed,**facts))
    sources={
     'cold Aug':'class Holder:pass\nHolder.note=1\ndef bump():Holder.note+=1\nbump()\n',
     'cold Compare':'def compare():trigger<0\ncompare()\n',
     'cold mutator':'def mutate():obj.__dict__.update(parse_file=value)\nmutate()\n',
     'transitive Aug':'class Holder:pass\nHolder.note=1\ndef inner():Holder.note+=1\ndef outer():inner()\nouter()\n',
     'explicit builtin':'def graft():setattr(Holder,"parse_file",Model.parse_file)\ngraft()\n',
    }
    for label,text in sources.items():
     local,tree=cold(text)
     for full in (False,True):
      effect=local.call_effects(tree.body,include_protocols=full)[1];expected=full or label=='explicit builtin'
      check(label+' mode='+str(full),bool(effect&module.ReceiverEffect.NAMESPACE)==expected,actual_effect=int(effect),expected_namespace=expected)
    # Obtain cache entries only through maintained source visitors. No map/effect injection.
    text=sources['explicit builtin'];local,tree=cold(text);local.visit(tree.body[0]);call=tree.body[-1].value
    effect=local.namespace_effects([call],include_protocols=False)
    check('explicit sensitive input retained in False',bool(effect&module.ReceiverEffect.NAMESPACE),actual_effect=int(effect),producer='visit_FunctionDef',sensitive_graft=int(local.sensitive_call_effects.get('graft',0)))
    text='obj.__dict__.update()';local,tree=cold(text);call=tree.body[0].value;initial=dict(local.env);local.visit(call)
    assert local.env==initial and call in local.namespace_call_effects
    effect=local.namespace_effects([call],include_protocols=False)
    check('False does not import mixed protocol observation',effect==module.ReceiverEffect.NONE,actual_effect=int(effect),producer='visit_Call',observed_effect=int(local.namespace_call_effects[call]),env_remains_cold=True)
    check('default remains full True',local.namespace_effects([call])==local.namespace_effects([call],include_protocols=True),default=int(local.namespace_effects([call])),full=int(local.namespace_effects([call],include_protocols=True)))
    return {"rows": rows, "preconditions": preconditions, "passed": sum(r["pass_"] for r in rows), "failed": sum(not r["pass_"] for r in rows)}

result = run(module)
print(json.dumps(result, sort_keys=True))
raise SystemExit(0 if result["passed"] == 13 and result["failed"] == 0 else 1)
PY
  then
    t_ok 'receiver protocol summary mode contract (13 controls)'
  else
    t_fail 'receiver protocol summary mode contract (13 controls)'
    cat "$_qmr_contract_log" >&2
  fi
}

# Protects: negative callback effects survive copies/joins/may-loss and expire
# on definite replacement or a genuinely different lexical binding.
# Detects: empty-loop mask loss, local leakage, stale argument rereads and lost
# deferred constructor-slot metadata without granting any positive callable kind.
# Needs: Python stdlib; dispatch uses an inert FakeBase, no file/provider I/O.
# Breadcrumb: hooks/common/mandate_scan.py ReceiverBinding/receiver_join,
# receiver_effect/apply_written/deferred_bindings/visit_Call.
_qm_receiver_protocol_lifecycle_contract() {
  if ! gg_has_python; then
    t_skip 'receiver callback provenance lifecycle contract (7 controls) needs Python'
    return 0
  fi
  _qmr_contract_log="$GG_T_TMPROOT/_qm_receiver_protocol_lifecycle_contract.log"
  if "$(gg_python)" -I -B - "$GG_ROOT" >"$_qmr_contract_log" 2>&1 <<'PY'
import ast
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("receiver_contract_scanner", root / "hooks/common/mandate_scan.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

from types import SimpleNamespace
class FakeBase:
    @classmethod
    def parse_file(cls, path):
        return "Model"

"""Negative callback provenance contracts; no positive callback identity oracle."""
import ast


def source_cases():
    prefix = 'from pydantic import BaseModel\nclass Model(BaseModel):pass\nclass Trigger:\n def __neg__(self):\n  Parser.parse_file=Model.parse_file\n  return 0\ntrigger=Trigger()\nclass Parser:\n @classmethod\n def parse_file(cls,path):return "Parser"\n'
    invoke = 'def invoke(cb):cb()\n'
    finish = 'answer=Parser.parse_file("x")\n'
    return [
        ('lifecycle branch union', prefix+invoke+'flag=False\nif flag:cb=lambda:None\nelse:cb=lambda:-trigger\ninvoke(cb)\n'+finish, 'unknown', 'Model'),
        ('lifecycle empty loop retains callback', prefix+invoke+'cb=lambda:-trigger\nfor item in []:cb=None\ninvoke(cb)\n'+finish, 'unknown', 'Model'),
        ('lifecycle hidden local stays local', prefix+invoke+'cb=lambda:None\ndef hidden():\n cb=lambda:-trigger\ninvoke(cb)\n'+finish, 'plain', 'Parser'),
        ('lifecycle Name copy', prefix+invoke+'cb=lambda:-trigger\nalias=cb\ninvoke(alias)\n'+finish, 'unknown', 'Model'),
        ('lifecycle captured pure callee before rebind', prefix+'def safe(value):return None\ncb=safe\nbad=lambda:-trigger\ncb((cb:=bad))\n'+finish, 'plain', 'Parser'),
        ('lifecycle early callback argument before rebind', prefix+'def invoke(first,second):first()\ncb=lambda:-trigger\npure=lambda:None\ninvoke(cb,(cb:=pure))\n'+finish, 'unknown', 'Model'),
    ]


def run(module, helpers):
    results = []
    contracts = []
    for label, source, expected, runtime in source_cases():
        resolver = module.PydanticReceivers(source)
        resolver.visit(ast.parse(source))
        actual = set().union(*resolver.calls.values())
        scope = {'BaseModel': helpers.FakeBase}
        error = None
        try:
            exec(compile(source.replace('from pydantic import BaseModel\n', '', 1), label, 'exec'), scope)
        except Exception as caught:
            error = type(caught).__name__
        passed = actual == {expected} and error is None and scope.get('answer') == runtime
        contracts.append(dict(label=label, actual=sorted(actual), expected=expected,
                              runtime=scope.get('answer'), expected_runtime=runtime,
                              runtime_error=error, passed=passed))
    for index, label in [(0,'branch union'),(1,'empty loop'),(2,'hidden local'),(3,'Name copy')]:
        results.append(dict(label=label, passed=contracts[index]['passed']))

    # These are binding-lifetime checks through maintained visitors. Imports,
    # deletion and a formal shadow are not invented successful runtime calls.
    reset_checks = []
    for label, tail in [
        ('definite replacement', 'cb=lambda:None\n'),
        ('definite import', 'import math as cb\n'),
        ('definite deletion', 'del cb\n'),
    ]:
        resolver = module.PydanticReceivers('cb=lambda:-trigger\n'+tail)
        resolver.visit(ast.parse(resolver.source))
        reset_checks.append(dict(label=label, passed=resolver.env['cb'].protocol_effect == module.ReceiverEffect.NONE))
    text = 'cb=lambda:-trigger\ndef invoke(value):return None\ndef frame(cb):\n invoke(cb)\n'
    target = ast.parse(text).body[-1].body[0].value.args[0].lineno
    masks = []
    class Probe(module.PydanticReceivers):
        def value(self, node):
            value = super().value(node)
            if (isinstance(node, ast.Name) and node.id == 'cb' and node.lineno == target
                    and self.deferred_horizon and self.env is not self.field_module_env):
                masks.append(int(value.protocol_effect))
            return value
    resolver = Probe(text)
    resolver.visit(ast.parse(text))
    reset_checks.append(dict(label='formal shadow', passed=bool(masks) and all(mask == 0 for mask in masks), observed_masks=masks))
    text = 'cb=lambda:-trigger\nfrom unexecuted_module import *\n'
    resolver = module.PydanticReceivers(text)
    resolver.visit(ast.parse(text))
    reset_checks.append(dict(label='uncertain star import retains possible callback', passed=bool(resolver.env['cb'].protocol_effect & module.ReceiverEffect.NAMESPACE)))
    results.append(dict(label='definite reset versus uncertain loss', passed=all(r['passed'] for r in reset_checks), subchecks=reset_checks))
    results.append(dict(label='callee and argument capture', passed=contracts[4]['passed'] and contracts[5]['passed']))

    # Capture the real deferred visitor's result before a later definite store.
    text = 'class Holder:\n def __init__(self):self.cb=0\ncb=lambda:-trigger\nHolder.cb=cb\ndef later():pass\nHolder.cb=0\n'
    captured = []
    class SlotProbe(module.PydanticReceivers):
        def deferred_bindings(self, outer=None, *, capture=None):
            result = super().deferred_bindings(outer, capture=capture)
            if isinstance(capture, ast.FunctionDef) and capture.name == 'later':
                owner = self.env['Holder']
                key = self.class_member_key(owner.identity, 'cb')
                captured.append(int(result[1].get(key, module.UNKNOWN_RECEIVER).protocol_effect))
            return result
    resolver = SlotProbe(text)
    resolver.visit(ast.parse(text))
    key = resolver.class_member_key(resolver.env['Holder'].identity, 'cb')
    final = int(resolver.env.get(key, module.UNKNOWN_RECEIVER).protocol_effect)
    results.append(dict(label='future constructor slot expiry preserves may mask',
                        passed=bool(captured) and all(mask & int(module.ReceiverEffect.NAMESPACE) for mask in captured) and final == 0,
                        captured_masks=captured, after_definite_store=final,
                        runtime_scope='AST metadata only; no Model dispatch claimed'))
    assert len(results) == 7
    return dict(rows=results, source_contracts=contracts,
                passed=sum(row['passed'] for row in results), failed=sum(not row['passed'] for row in results))
result = run(module, SimpleNamespace(FakeBase=FakeBase))
print(json.dumps(result, sort_keys=True))
raise SystemExit(0 if result["passed"] == 7 and result["failed"] == 0 else 1)
PY
  then
    t_ok 'receiver callback provenance lifecycle contract (7 controls)'
  else
    t_fail 'receiver callback provenance lifecycle contract (7 controls)'
    cat "$_qmr_contract_log" >&2
  fi
}
