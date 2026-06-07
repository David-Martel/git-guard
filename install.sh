#!/bin/sh
#
# git-guard installer — IDEMPOTENT, REVERSIBLE, cross-platform (Git-Bash / WSL /
# Linux / macOS). Makes the versioned git-guard the single source of truth via
# SYMLINKS, so the original on-machine configuration is preserved (backed up) and
# every machine re-derives the same state from the repo.
#
# What it does (re-running is safe — it converges, never duplicates):
#   1. Back up an existing real ~/.git-hooks dir -> ~/.git-hooks.pre-git-guard-backup
#      (only the FIRST time; never clobbers an existing backup).
#   2. Symlink ~/.git-hooks  ->  <git-guard>/hooks      (the engine + hooks)
#   3. git config --global core.hooksPath ~/.git-hooks  (account-wide)
#   4. Symlink ~/.agents/QA_TOOLING.md, ~/.agents/GIT_COMMIT_SAFETY.md
#      -> <git-guard>/docs/*  (docs follow the repo; originals backed up once)
#   5. With --rules-dir DIR: write `rules_dir=DIR` into a GITIGNORED
#      qa-gate.conf.local overlay so this machine uses a private rule corpus
#      while the committed defaults stay public-safe. (A config FILE, not an env
#      var — inspectable, versionable, hot-reloadable.)
#
# Usage:
#   ./install.sh [--rules-dir <abs-path>] [--hooks-link <path>] [--dry-run]
#   ./install.sh --uninstall            # restore the pre-git-guard backup
#   ./install.sh --status               # delegate to: bin/git-guard status
#
# SAFETY: this MUTATES the live machine's global git hooks. It is intentionally
# NOT run by bootstrap automatically on first clone — invoke it deliberately.
# The real->symlink swap of ~/.git-hooks is the one sensitive step; the backup
# makes it fully reversible (--uninstall).

set -u

GG_ROOT="$(cd "$(dirname "$0")" && pwd)"
GG_HOOKS="$GG_ROOT/hooks"
GG_DOCS="$GG_ROOT/docs"
HOME_HOOKS="${GIT_GUARD_HOOKS_LINK:-$HOME/.git-hooks}"
AGENTS_DIR="$HOME/.agents"
DRY=0
UNINSTALL=0
RULES_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --rules-dir) RULES_DIR="${2:-}"; shift 2 ;;
    --hooks-link) HOME_HOOKS="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --status) exec sh "$GG_ROOT/bin/git-guard" status ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "git-guard install: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

run() { if [ "$DRY" = "1" ]; then echo "  DRY: $*"; else eval "$*"; fi }
ln_symlink() {  # $1 target, $2 linkname — portable, idempotent
  tgt="$1"; lnk="$2"
  if [ -L "$lnk" ] && [ "$(readlink "$lnk" 2>/dev/null)" = "$tgt" ]; then
    echo "  ok (already linked): $lnk -> $tgt"; return 0
  fi
  run "ln -sfn \"$tgt\" \"$lnk\"" && echo "  linked: $lnk -> $tgt"
}

backup_once() {  # $1 path -> back up to <path>.pre-git-guard-backup, once
  p="$1"; bk="${p}.pre-git-guard-backup"
  if [ -e "$p" ] && [ ! -L "$p" ] && [ ! -e "$bk" ]; then
    run "mv \"$p\" \"$bk\"" && echo "  backed up: $p -> $bk"
  fi
}

if [ "$UNINSTALL" = "1" ]; then
  echo "git-guard uninstall"
  # Remove our symlink, restore the backup if present.
  if [ -L "$HOME_HOOKS" ]; then run "rm -f \"$HOME_HOOKS\""; echo "  removed symlink: $HOME_HOOKS"; fi
  if [ -e "${HOME_HOOKS}.pre-git-guard-backup" ]; then
    run "mv \"${HOME_HOOKS}.pre-git-guard-backup\" \"$HOME_HOOKS\""; echo "  restored: $HOME_HOOKS"
  fi
  for d in QA_TOOLING.md GIT_COMMIT_SAFETY.md; do
    if [ -L "$AGENTS_DIR/$d" ]; then run "rm -f \"$AGENTS_DIR/$d\""; fi
    if [ -e "$AGENTS_DIR/$d.pre-git-guard-backup" ]; then run "mv \"$AGENTS_DIR/$d.pre-git-guard-backup\" \"$AGENTS_DIR/$d\""; fi
  done
  echo "  NOTE: core.hooksPath left as-is ($(git config --global core.hooksPath 2>/dev/null || echo unset)); reset manually if desired."
  echo "uninstall complete."
  exit 0
fi

echo "git-guard install (root: $GG_ROOT)"
[ "$DRY" = "1" ] && echo "  (dry run — no changes will be made)"

# 1+2. ~/.git-hooks -> git-guard/hooks (back up an existing real dir first).
backup_once "$HOME_HOOKS"
ln_symlink "$GG_HOOKS" "$HOME_HOOKS"

# 3. Point git's global hooksPath at it.
run "git config --global core.hooksPath \"$HOME_HOOKS\"" && echo "  core.hooksPath = $HOME_HOOKS"

# 4. Docs symlinks (originals backed up once).
run "mkdir -p \"$AGENTS_DIR\""
for d in QA_TOOLING.md GIT_COMMIT_SAFETY.md; do
  backup_once "$AGENTS_DIR/$d"
  ln_symlink "$GG_DOCS/$d" "$AGENTS_DIR/$d"
done

# 5. Optional private-rules overlay via gitignored qa-gate.conf.local.
if [ -n "$RULES_DIR" ]; then
  if [ -d "$RULES_DIR" ]; then
    LOCAL_CONF="$GG_HOOKS/common/qa-gate.conf.local"
    if [ "$DRY" = "1" ]; then
      echo "  DRY: write rules_dir=$RULES_DIR -> $LOCAL_CONF"
    else
      printf '# git-guard machine-local overlay (gitignored). Written by install.sh.\nrules_dir=%s\n' "$RULES_DIR" > "$LOCAL_CONF"
      echo "  overlay: rules_dir=$RULES_DIR -> $LOCAL_CONF"
    fi
  else
    echo "  WARN: --rules-dir '$RULES_DIR' is not a directory; skipping overlay (will use bundled examples)." >&2
  fi
fi

echo ""
echo "install complete. Verify with:  sh \"$GG_ROOT/bin/git-guard\" status && sh \"$GG_ROOT/bin/git-guard\" verify"
