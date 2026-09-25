#!/bin/sh
#
# git-guard installer — IDEMPOTENT, REVERSIBLE, cross-platform (Git-Bash / WSL /
# Linux / macOS).
#
# DEFAULT MODE (since PR-4): installs a VERSIONED, IMMUTABLE release.
#   `git archive <tag>` materializes the tagged tree into
#   ~/.local/share/git-guard/<tag>/ (never mutated once written), an atomic
#   symlink-swap points ~/.local/share/git-guard/current -> that version dir,
#   and ~/.git-hooks (and the docs symlinks) point at `current`. A `git-guard
#   update --to <tag>` later just re-runs this and flips `current` — every
#   consuming repo's hooks change in one atomic rename, never a half-installed
#   state, and a `git checkout`/branch switch in the git-guard WORKING CHECKOUT
#   has no effect on any installed hooks (that is the bug this closes: hooks
#   used to be a live symlink into the checkout).
#
# LEGACY MODE (--dev-symlink, opt-in only): the pre-PR-4 behavior — symlink
# ~/.git-hooks straight at THIS checkout's hooks/ directory, so hook behavior
# tracks whatever is checked out live. Only for git-guard's OWN development
# loop (iterating on hooks/qa_gate.sh and wanting immediate effect without a
# tag+install round-trip). Never use this on a host whose repos you don't want
# to silently re-hook on every `git checkout`/`git pull` in this working tree.
#
# What `--to <tag>` does (re-running is safe — it converges, never duplicates):
#   1. Verify <tag> exists in THIS checkout's history; resolve its commit.
#   2. Materialize (git archive | tar -x) into a temp dir, then atomically
#      `mv` it into ~/.local/share/git-guard/<tag>/ (skipped if that version
#      dir already exists with a matching commit marker; refuses to clobber a
#      mismatched one).
#   3. Carry forward the persistent local rules overlay
#      (~/.local/share/git-guard/qa-gate.conf.local, if present) into the
#      newly materialized version's hooks/common/qa-gate.conf.local, so a
#      `--rules-dir` overlay survives every future `update`.
#   4. Atomically swap ~/.local/share/git-guard/current -> the version dir
#      (temp symlink + `mv -T`, which is an atomic rename over the existing
#      `current` symlink — see flip_current() for why plain `mv` is NOT safe
#      here without -T).
#   5. Symlink ~/.git-hooks -> ~/.local/share/git-guard/current/hooks (only
#      needs doing once; idempotent thereafter since `current`'s TARGET moves,
#      not the ~/.git-hooks symlink itself).
#   6. git config --global core.hooksPath ~/.git-hooks (account-wide).
#   7. Symlink ~/.agents/QA_TOOLING.md, ~/.agents/GIT_COMMIT_SAFETY.md ->
#      ~/.local/share/git-guard/current/docs/*  (originals backed up once).
#   8. With --rules-dir DIR: write `rules_dir=DIR` into the PERSISTENT overlay
#      (~/.local/share/git-guard/qa-gate.conf.local) AND copy it into the
#      just-materialized version dir immediately, so it takes effect now
#      (not just on the next update).
#
# With no --to and no --dev-symlink, the default is `--to v$(cat VERSION)` —
# i.e. "install the version this checkout itself declares", which must exist
# as a tag reachable from this checkout.
#
# Usage:
#   ./install.sh [--to <tag>] [--store <dir>] [--rules-dir <abs-path>]
#                [--hooks-link <path>] [--dry-run]
#   ./install.sh --dev-symlink [--rules-dir <abs-path>] [--hooks-link <path>] [--dry-run]
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
STORE_ROOT="${GIT_GUARD_STORE:-$HOME/.local/share/git-guard}"
DRY=0
UNINSTALL=0
DEV_SYMLINK=0
RULES_DIR=""
TO_TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO_TAG="${2:-}"; shift 2 ;;
    --store) STORE_ROOT="${2:-}"; shift 2 ;;
    --rules-dir) RULES_DIR="${2:-}"; shift 2 ;;
    --hooks-link) HOME_HOOKS="${2:-}"; shift 2 ;;
    --dev-symlink) DEV_SYMLINK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --status) exec sh "$GG_ROOT/bin/git-guard" status ;;
    -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  echo "  NOTE: materialized versions under $STORE_ROOT are left in place; remove that directory manually if you want a full teardown."
  echo "uninstall complete."
  exit 0
fi

echo "git-guard install (root: $GG_ROOT)"
[ "$DRY" = "1" ] && echo "  (dry run — no changes will be made)"

# ------------------------------------------------------------------------
# Materialize + atomically point ~/.git-hooks at a VERSIONED, IMMUTABLE copy
# (default). --dev-symlink opts back into the pre-PR-4 live-checkout symlink.
# ------------------------------------------------------------------------
materialize_version() {  # $1 = tag; echoes the version dir on success
  tag="$1"
  ver_dir="$STORE_ROOT/$tag"
  commit="$(git -C "$GG_ROOT" rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null)" \
    || { echo "git-guard install: tag '$tag' not found in $GG_ROOT (create it first: git -C \"$GG_ROOT\" tag $tag <sha>)" >&2; return 2; }

  if [ -d "$ver_dir" ]; then
    if [ -f "$ver_dir/.git-guard-commit" ] && [ "$(cat "$ver_dir/.git-guard-commit" 2>/dev/null)" = "$commit" ]; then
      echo "  ok (already materialized): $ver_dir @ ${commit}" >&2
      printf '%s' "$ver_dir"; return 0
    fi
    echo "git-guard install: $ver_dir already exists but its commit marker does not match tag '$tag' (expected $commit). Refusing to overwrite a materialized version — remove $ver_dir manually if you intend to re-materialize it." >&2
    return 2
  fi

  if [ "$DRY" = "1" ]; then
    echo "  DRY: git archive $tag (commit $commit) -> $ver_dir" >&2
    printf '%s' "$ver_dir"; return 0
  fi

  tmp_dir="$(mktemp -d "$STORE_ROOT/.materializing.XXXXXX")" || { echo "git-guard install: mktemp failed under $STORE_ROOT" >&2; return 2; }
  if ! (git -C "$GG_ROOT" archive "$tag" | (cd "$tmp_dir" && tar -xf -)); then
    echo "git-guard install: 'git archive $tag | tar -x' failed" >&2
    rm -rf "$tmp_dir"; return 2
  fi
  printf '%s' "$commit" > "$tmp_dir/.git-guard-commit"

  # Carry the persistent private-rules overlay forward into the freshly
  # materialized tree BEFORE it becomes reachable as a version dir, so a
  # concurrent reader of $ver_dir never sees it half-populated.
  if [ -f "$STORE_ROOT/qa-gate.conf.local" ]; then
    cp "$STORE_ROOT/qa-gate.conf.local" "$tmp_dir/hooks/common/qa-gate.conf.local"
    echo "  carried forward overlay: $STORE_ROOT/qa-gate.conf.local" >&2
  fi

  mv "$tmp_dir" "$ver_dir" || { echo "git-guard install: could not move materialized tree into place" >&2; rm -rf "$tmp_dir"; return 2; }
  echo "  materialized: $ver_dir (tag=$tag commit=$commit)" >&2
  printf '%s' "$ver_dir"
}

flip_current() {  # $1 = version dir to point `current` at
  ver_dir="$1"
  cur="$STORE_ROOT/current"
  if [ "$DRY" = "1" ]; then echo "  DRY: atomically swap $cur -> $ver_dir"; return 0; fi
  tmp_link="$STORE_ROOT/.current.tmp.$$"
  rm -f "$tmp_link"
  ln -s "$ver_dir" "$tmp_link" || { echo "git-guard install: could not create temp symlink for atomic swap" >&2; return 2; }
  if mv --version >/dev/null 2>&1; then
    # GNU mv: -T is REQUIRED. Without it, `mv tmp_link current` STATs THROUGH
    # an existing `current` symlink-to-directory and would move tmp_link
    # *inside* the version dir `current` already points to, instead of
    # atomically replacing the `current` symlink itself. `-T` forces "treat
    # DEST as a normal file/symlink, never as a directory to descend into",
    # which is exactly the atomic symlink-swap semantics this needs: no
    # hook invocation, anywhere, ever sees `current` half-updated.
    mv -T "$tmp_link" "$cur" || { rm -f "$tmp_link"; echo "git-guard install: atomic current-swap failed" >&2; return 2; }
  else
    # Non-GNU mv (macOS/BSD have no -T). rename(2) is still atomic at the
    # syscall level; the gap is entirely in mv's own directory pre-check. A
    # plain remove+relink is NOT atomic (a window exists with no `current` at
    # all) but is the best available fallback outside GNU coreutils.
    rm -f "$cur"
    ln -s "$ver_dir" "$cur" || { rm -f "$tmp_link"; return 2; }
    rm -f "$tmp_link"
  fi
  echo "  current -> $ver_dir (atomic swap)"
}

if [ "$DEV_SYMLINK" = "1" ]; then
  echo "  mode: --dev-symlink (LEGACY, live checkout — see header comment)"
  backup_once "$HOME_HOOKS"
  ln_symlink "$GG_HOOKS" "$HOME_HOOKS"
  DOCS_SRC="$GG_DOCS"
  RULES_LOCAL_TARGET="$GG_HOOKS/common/qa-gate.conf.local"
else
  [ -n "$TO_TAG" ] || TO_TAG="v$(cat "$GG_ROOT/VERSION" 2>/dev/null || echo '0.0.0')"
  echo "  mode: versioned install (--to $TO_TAG)"
  run "mkdir -p \"$STORE_ROOT\""
  if [ "$DRY" = "1" ]; then
    VER_DIR="$STORE_ROOT/$TO_TAG"
  else
    VER_DIR="$(materialize_version "$TO_TAG")" || exit 2
  fi
  flip_current "$VER_DIR" || exit 2
  ln_symlink "$STORE_ROOT/current/hooks" "$HOME_HOOKS"
  DOCS_SRC="$STORE_ROOT/current/docs"
  RULES_LOCAL_TARGET="$STORE_ROOT/current/hooks/common/qa-gate.conf.local"
fi

# Point git's global hooksPath at it (both modes).
run "git config --global core.hooksPath \"$HOME_HOOKS\"" && echo "  core.hooksPath = $HOME_HOOKS"

# Docs symlinks (originals backed up once).
run "mkdir -p \"$AGENTS_DIR\""
for d in QA_TOOLING.md GIT_COMMIT_SAFETY.md; do
  backup_once "$AGENTS_DIR/$d"
  ln_symlink "$DOCS_SRC/$d" "$AGENTS_DIR/$d"
done

# Optional private-rules overlay.
#   --dev-symlink: written straight into the live checkout's gitignored
#     qa-gate.conf.local, exactly as before PR-4.
#   versioned mode: written into the PERSISTENT, version-independent overlay
#     (so `update --to <new-tag>` carries it forward automatically — see
#     materialize_version) AND copied into the just-installed version now, so
#     it takes effect immediately rather than on the next update.
if [ -n "$RULES_DIR" ]; then
  if [ -d "$RULES_DIR" ]; then
    if [ "$DEV_SYMLINK" = "1" ]; then
      LOCAL_CONF="$RULES_LOCAL_TARGET"
      if [ "$DRY" = "1" ]; then
        echo "  DRY: write rules_dir=$RULES_DIR -> $LOCAL_CONF"
      else
        printf '# git-guard machine-local overlay (gitignored). Written by install.sh.\nrules_dir=%s\n' "$RULES_DIR" > "$LOCAL_CONF"
        echo "  overlay: rules_dir=$RULES_DIR -> $LOCAL_CONF"
      fi
    else
      PERSIST_CONF="$STORE_ROOT/qa-gate.conf.local"
      if [ "$DRY" = "1" ]; then
        echo "  DRY: write rules_dir=$RULES_DIR -> $PERSIST_CONF (persistent overlay, carried across updates)"
        echo "  DRY: copy $PERSIST_CONF -> $RULES_LOCAL_TARGET (take effect now)"
      else
        printf '# git-guard machine-local overlay (persistent across `update --to`). Written by install.sh.\nrules_dir=%s\n' "$RULES_DIR" > "$PERSIST_CONF"
        cp "$PERSIST_CONF" "$RULES_LOCAL_TARGET"
        echo "  overlay: rules_dir=$RULES_DIR -> $PERSIST_CONF (+ copied into $TO_TAG now)"
      fi
    fi
  else
    echo "  WARN: --rules-dir '$RULES_DIR' is not a directory; skipping overlay (will use bundled examples)." >&2
  fi
fi

echo ""
echo "install complete. Verify with:  sh \"$GG_ROOT/bin/git-guard\" status && sh \"$GG_ROOT/bin/git-guard\" verify"
