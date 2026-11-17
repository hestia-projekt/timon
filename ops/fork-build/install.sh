#!/bin/sh
# Install a fork runtime as the next desktop-runtime release and point the
# service at it. Without --apply it only checks that no mission is running
# and prints the plan. It does not call `timon update apply`.
#
#   ops/fork-build/install.sh --package DIR            # plan
#   ops/fork-build/install.sh --package DIR --apply    # switch
#
# On a failed health check the previous unit is put back and a database
# whose schema changed is restored from the backup this run just took.
# See ops/fork-build/README.md.
set -eu

SCRIPT=$0
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$SCRIPT")" && pwd)/lib.sh"

APPLY=0
PACKAGE=
BACKUP_ROOT=${TIMON_FORK_BACKUP_ROOT:-$HOME/timon-fork-backups}

while [ $# -gt 0 ]; do
  case $1 in
    --apply) APPLY=1; shift ;;
    --package) PACKAGE=$2; shift 2 ;;
    --backup-root) BACKUP_ROOT=$2; shift 2 ;;
    *) fork_die "unknown argument $1" ;;
  esac
done
[ -n "$PACKAGE" ] || fork_die "pass --package DIR"
[ -d "$PACKAGE/resources/orchestrator" ] || fork_die "not a runtime package: $PACKAGE"
[ -f "$PACKAGE/fork-build.json" ] || fork_die "package has no fork-build.json"

HOME_DIR=$(fork_home)
UNIT_NAME=$(fork_unit_name)
UNIT_FILE=$(fork_unit_file)
PORT=$(fork_port_from_unit "$UNIT_FILE")
VERSION_ID=$(node --input-type=module -e 'import { readFileSync } from "node:fs"; const body = JSON.parse(readFileSync(process.argv[1], "utf8")); if (!body.versionId) process.exit(1); process.stdout.write(body.versionId);' "$PACKAGE/fork-build.json")
fork_version_id_ok "$VERSION_ID"
ACTIVE=$(tr -d '[:space:]' < "$HOME_DIR/desktop-runtime/active-release")
fork_version_id_ok "$ACTIVE"
TARGET="$HOME_DIR/desktop-runtime/releases/$VERSION_ID"

printf 'unit %s\n' "$UNIT_NAME"
printf 'port %s\n' "$PORT"
printf 'active %s\n' "$ACTIVE"
printf 'install %s\n' "$VERSION_ID"
fork_assert_idle "$HOME_DIR" "$PORT" "$SCRIPT"

if [ "$APPLY" -ne 1 ]; then
  printf 'dry-run: no file was written and the service was not restarted\n'
  printf 'apply: %s --package %s --apply\n' "$SCRIPT" "$PACKAGE"
  exit 0
fi

[ ! -e "$TARGET" ] || fork_die "release already exists: $TARGET"
# 077 so a directory created here is 0700 and a file created here is 0600.
# cp and rsync still copy the source mode; fork_privatize_tree corrects that.
umask 077
mkdir -p -- "$BACKUP_ROOT"
fork_assert_outside_home "$BACKUP_ROOT" "backup directory"
chmod 0700 "$BACKUP_ROOT" || fork_die "cannot restrict $BACKUP_ROOT"
root_mode=$(stat -c %a -- "$BACKUP_ROOT")
[ "$root_mode" = "700" ] || fork_die "backup root is mode $root_mode, expected 700"

# Stop before copying. The daemon keeps writing the home, so a second rsync
# would never match, and a hot copy would not be the tree we can restore.
# A failure before the backup exists starts the previous unit again.
# After the backup exists, a failure restores it in a subshell. The restore
# returns on error instead of exiting, so the branch below still starts the
# unit. The unit and pointer are written back before the databases and the
# health check, so that start runs the saved unit when a later step fails.
phase=idle
put_service_back() {
  ec=$?
  current=$phase
  phase="done"
  case "$current" in
    stopped)
      printf 'starting the previous service\n' >&2
      systemctl --user start "$UNIT_NAME" || true
      ;;
    backed-up)
      printf 'restoring the previous service\n' >&2
      if ( fork_restore_backup "$DEST" ); then
        # The copy is not what the unit runs anymore. A retry can install it again.
        rm -rf -- "$TARGET"
      else
        systemctl --user start "$UNIT_NAME" || true
      fi
      ;;
  esac
  exit "$ec"
}
trap put_service_back EXIT
# The release in service (0.1.8) has no pause for new launches: the live-mission
# cap does not bind chat, and the day profile never goes below one mission.
# Ask again as the last step before stop. phase stays idle until the check
# passes, so a refusal leaves the running unit alone.
fork_assert_idle "$HOME_DIR" "$PORT" "$SCRIPT"
phase=stopped
systemctl --user stop "$UNIT_NAME"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$BACKUP_ROOT/$STAMP"
mkdir -p -- "$DEST/db" "$DEST/home"
chmod 0700 "$DEST" "$DEST/db" "$DEST/home" || fork_die "cannot restrict $DEST"

FP_TIMON=$(fork_sqlite_backup "$HOME_DIR/timon.db" "$DEST/db/timon.db")
FP_INTEGRATIONS=$(fork_sqlite_backup "$HOME_DIR/integrations.db" "$DEST/db/integrations.db")

RSYNC_EXCLUDES="--exclude /desktop-runtime --exclude /worktrees --exclude /provider-runs --exclude /backups --exclude /run --exclude /tmp --exclude /updates --exclude /provider-cache --exclude /trash --exclude /timon.db --exclude /timon.db-wal --exclude /timon.db-shm --exclude /integrations.db --exclude /integrations.db-wal --exclude /integrations.db-shm"
# shellcheck disable=SC2086
rsync -a $RSYNC_EXCLUDES "$HOME_DIR/" "$DEST/home/"
# shellcheck disable=SC2086
leftover=$(rsync -a --dry-run --itemize-changes $RSYNC_EXCLUDES "$HOME_DIR/" "$DEST/home/")
[ -z "$leftover" ] || fork_die "home backup does not match the source"

RELEASE_SRC="$HOME_DIR/desktop-runtime/releases/$ACTIVE"
cp -a -- "$RELEASE_SRC" "$DEST/official-release"
src_sum=$(sha256sum "$RELEASE_SRC/resources/orchestrator/release-manifest.json" | awk '{print $1}')
dst_sum=$(sha256sum "$DEST/official-release/resources/orchestrator/release-manifest.json" | awk '{print $1}')
[ "$src_sum" = "$dst_sum" ] || fork_die "official release backup does not match the manifest"
src_n=$(find "$RELEASE_SRC" -type f | wc -l)
dst_n=$(find "$DEST/official-release" -type f | wc -l)
[ "$src_n" = "$dst_n" ] || fork_die "official release backup file count differs ($src_n vs $dst_n)"

cp -a -- "$UNIT_FILE" "$DEST/unit.service"
cp -a -- "$HOME_DIR/desktop-runtime/active-release" "$DEST/active-release"
jq -n \
  --arg stamp "$STAMP" \
  --arg unit "$UNIT_NAME" \
  --arg port "$PORT" \
  --arg active "$ACTIVE" \
  --arg package "$VERSION_ID" \
  --arg timon "$FP_TIMON" \
  --arg integrations "$FP_INTEGRATIONS" \
  '{stamp: $stamp, unit: $unit, port: $port, activeRelease: $active, packageVersionId: $package, databases: {"timon.db": {fingerprint: $timon}, "integrations.db": {fingerprint: $integrations}}}' \
  > "$DEST/manifest.json"
fork_privatize_tree "$DEST"
for db_name in timon.db integrations.db; do
  db_copy="$DEST/db/$db_name"
  [ -f "$db_copy" ] || continue
  db_mode=$(stat -c %a -- "$db_copy")
  [ "$db_mode" = "600" ] || fork_die "backup of $db_name is mode $db_mode, expected 600"
done
printf 'backup %s\n' "$DEST"
phase=backed-up

cp -a -- "$PACKAGE" "$TARGET"
[ -f "$TARGET/resources/orchestrator/dist/host/packaged-runner.js" ] || fork_die "copied package has no service runner"

OLD_PATH="$HOME_DIR/desktop-runtime/releases/$ACTIVE"
NEW_PATH="$TARGET"
# shellcheck disable=SC2016 # node source stays single-quoted so the shell does not expand it
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const file = process.argv[1];
  const oldPath = process.argv[2];
  const newPath = process.argv[3];
  const version = process.argv[4];
  let text = readFileSync(file, "utf8");
  if (!text.includes(oldPath)) throw new Error("unit does not point at the active release");
  text = text.split(oldPath).join(newPath);
  const marker = "Environment=\"TIMON_DESKTOP_VERSION=";
  if (!text.includes(marker)) throw new Error("unit has no TIMON_DESKTOP_VERSION");
  text = text.replace(/Environment="TIMON_DESKTOP_VERSION=[^"]*"/, `Environment="TIMON_DESKTOP_VERSION=${version}"`);
  writeFileSync(file, text);
' "$UNIT_FILE" "$OLD_PATH" "$NEW_PATH" "$VERSION_ID"

printf '%s\n' "$VERSION_ID" > "$HOME_DIR/desktop-runtime/active-release"
systemctl --user daemon-reload
systemctl --user restart "$UNIT_NAME"
UNIT_HOME=$(fork_unit_home "$UNIT_FILE")
fork_health "$PORT" 60 "$UNIT_HOME" "$UNIT_NAME" >/dev/null
phase="done"
printf 'active-release %s\n' "$VERSION_ID"
printf 'rollback: %s --backup %s --apply\n' "$(fork_script_dir "$SCRIPT")/rollback.sh" "$DEST"
