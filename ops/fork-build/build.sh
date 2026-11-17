#!/bin/sh
# Build a desktop-runtime package from one commit of this fork.
#
# The result has the same layout as ~/.timon/desktop-runtime/releases/<id>/.
# It is written under the preparation directory, never under the live home
# and never where the running daemon is executing.
#
# Run it under the VPS memory cap (do not call npm run build in the live tree):
#
#   systemd-run --user --wait --collect \
#     -p MemoryMax=6G -p MemorySwapMax=0 -p KillMode=control-group -p RuntimeMaxSec=3600 \
#     -- ops/fork-build/build.sh --commit <sha>
#
# See ops/fork-build/README.md.
set -eu

SCRIPT=$0
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$SCRIPT")" && pwd)/lib.sh"

COMMIT=HEAD
PREP=${TIMON_FORK_PREP:-$HOME/timon-fork-prep}
SHELL_RELEASE=
MODULES=

while [ $# -gt 0 ]; do
  case $1 in
    --commit) COMMIT=$2; shift 2 ;;
    --prep) PREP=$2; shift 2 ;;
    --shell) SHELL_RELEASE=$2; shift 2 ;;
    --modules) MODULES=$2; shift 2 ;;
    *) fork_die "unknown argument $1" ;;
  esac
done

REPO=$(fork_repo "$SCRIPT")
PREP=$(fork_canonical_path "$PREP")
fork_assert_outside_home "$PREP" "preparation directory"
mkdir -p -- "$PREP"

if [ -z "$SHELL_RELEASE" ]; then
  active=$(tr -d '[:space:]' < "$(fork_home)/desktop-runtime/active-release")
  SHELL_RELEASE="$(fork_home)/desktop-runtime/releases/$active"
fi
[ -d "$SHELL_RELEASE/resources/orchestrator" ] || fork_die "official release not found at $SHELL_RELEASE"
[ -z "$MODULES" ] && MODULES="$REPO/orchestrator/node_modules"
[ -f "$MODULES/typescript/bin/tsc" ] || fork_die "typescript is missing under $MODULES (this script does not install dependencies)"

COMMIT=$(git -C "$REPO" rev-parse "$COMMIT")
SHORT=$(git -C "$REPO" rev-parse --short=12 "$COMMIT")
UPSTREAM=$(git -C "$REPO" show "$COMMIT:orchestrator/package.json" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$UPSTREAM" ] || fork_die "no version in orchestrator/package.json at $COMMIT"
VERSION_ID="${UPSTREAM}-fork.${SHORT}"
fork_version_id_ok "$VERSION_ID"

# Resolve every path this run will create. A symlink under the preparation
# directory that points elsewhere (the live home included) is refused here,
# before a worktree, a key, or a stage directory is created.
stage_want="$PREP/stage/$VERSION_ID"
out_want="$PREP/out/$VERSION_ID"
src_want="$PREP/src/$COMMIT"
keys_want="$PREP/keys/$VERSION_ID"
STAGE=$(fork_confine "$stage_want" "$PREP" "stage")
OUT=$(fork_confine "$out_want" "$PREP" "output")
SRC=$(fork_confine "$src_want" "$PREP" "checkout")
KEYS=$(fork_confine "$keys_want" "$PREP" "keys")
[ "$STAGE" = "$stage_want" ] || fork_die "stage leaves the preparation root ($STAGE)"
[ "$OUT" = "$out_want" ] || fork_die "output leaves the preparation root ($OUT)"
[ "$SRC" = "$src_want" ] || fork_die "checkout leaves the preparation root ($SRC)"
[ "$KEYS" = "$keys_want" ] || fork_die "keys leave the preparation root ($KEYS)"

if [ -e "$OUT" ]; then
  fork_die "package already exists at $OUT (remove it to rebuild)"
fi

added_worktree=0
added_modules_link=0
if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/.git" ]; then
  mkdir -p -- "$(dirname -- "$SRC")"
  git -C "$REPO" worktree add --detach "$SRC" "$COMMIT"
  added_worktree=1
fi
if [ ! -e "$SRC/orchestrator/node_modules" ]; then
  ln -s "$MODULES" "$SRC/orchestrator/node_modules"
  added_modules_link=1
fi

mkdir -p -- "$KEYS" "$PREP/stage" "$PREP/out"
if [ ! -f "$KEYS/fork-release.key.pem" ]; then
  umask 077
  openssl genpkey -algorithm ED25519 -out "$KEYS/fork-release.key.pem"
  openssl pkey -in "$KEYS/fork-release.key.pem" -pubout -out "$KEYS/fork-release.pub.pem"
  umask 022
fi

node "$REPO/ops/fork-build/assemble-release.mjs" \
  --checkout "$SRC" \
  --stage "$STAGE" \
  --output "$OUT" \
  --shell "$SHELL_RELEASE" \
  --key-dir "$KEYS" \
  --version-id "$VERSION_ID" \
  --commit "$COMMIT" \
  --modules "$MODULES"

LIST="$PREP/out/${VERSION_ID}.files.sha256"
HASH_FILE="$PREP/out/${VERSION_ID}.sha256"
(
  cd -- "$OUT"
  find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$LIST"
HASH=$(sha256sum "$LIST" | awk '{print $1}')
printf '%s  %s\n' "$HASH" "$VERSION_ID" > "$HASH_FILE"

fork_remove_script_stage "$STAGE" "$PREP/stage" "$VERSION_ID"
if [ "$added_modules_link" -eq 1 ]; then
  rm -f -- "$SRC/orchestrator/node_modules"
fi
if [ "$added_worktree" -eq 1 ]; then
  git -C "$REPO" worktree remove --force "$SRC" || printf 'fork-build: checkout left at %s\n' "$SRC" >&2
fi
printf 'package %s\n' "$OUT"
printf 'content-sha256 %s\n' "$HASH"
printf 'commit %s\n' "$COMMIT"
