#!/bin/sh
# Install a fork runtime as the next desktop-runtime release and point the
# service at it. Without --apply it only checks that no mission is running
# and prints the plan. It does not call `timon update apply`.
#
#   ops/fork-build/install.sh --package DIR            # plan
#   ops/fork-build/install.sh --package DIR --apply    # switch
#
# On a failed health check the previous unit is put back. Each database
# that existed in the backup this run just took is replaced by that copy.
# The live file is moved aside under the backup, not deleted. A database
# this run created is moved aside too.
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
PACKAGE=$(fork_existing_dir "$PACKAGE" "package")
fork_assert_outside_home "$PACKAGE" "package"
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

# Held until this process exits, so the mission checks, the file swap and
# the EXIT trap cannot overlap another apply or rollback on this home.
if [ "$APPLY" -eq 1 ]; then
  fork_acquire_apply_lock
fi

printf 'unit %s\n' "$UNIT_NAME"
printf 'port %s\n' "$PORT"
printf 'active %s\n' "$ACTIVE"
printf 'install %s\n' "$VERSION_ID"
fork_assert_idle "$HOME_DIR" "$PORT" "$SCRIPT"

if [ -L "$HOME_DIR/desktop-runtime/releases" ]; then
  fork_die "releases directory is a symlink"
fi
[ -d "$HOME_DIR/desktop-runtime/releases" ] || fork_die "no releases directory"
canon_target=$(fork_canonical_path "$TARGET")
canon_home=$(fork_live_home_path)
case "$canon_target" in
  "$canon_home"/desktop-runtime/releases/"$VERSION_ID") ;;
  *) fork_die "release path is outside the live home releases directory" ;;
esac
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  fork_die "release already exists: $TARGET"
fi

if [ "$APPLY" -ne 1 ]; then
  # Resolve the backup root and refuse a shared directory. Do not create it.
  BACKUP_ROOT=$(fork_prepare_private_dir "$BACKUP_ROOT" "backup directory" check)
  printf 'dry-run: no file was written and the service was not restarted\n'
  printf 'apply: %s --package %s --apply\n' "$SCRIPT" "$PACKAGE"
  exit 0
fi

# 077 so a directory created here is 0700 and a file created here is 0600.
# cp and rsync still copy the source mode; fork_privatize_tree corrects that.
# An existing backup root is not chmodded.
umask 077
BACKUP_ROOT=$(fork_prepare_private_dir "$BACKUP_ROOT" "backup directory" create)

# Stop before copying. The daemon keeps writing the home, so a second rsync
# would never match, and a hot copy would not be the tree we can restore.
# A failure before the backup exists starts the previous unit again.
# After the backup exists, a failure restores it in a subshell. The restore
# returns on error instead of exiting, so the branch below still starts the
# unit. The unit and pointer are written back before the databases and the
# health check, so that start runs the saved unit when a later step fails.
phase=idle
created_release=
created_release_token=
put_service_back() {
  ec=$?
  current=$phase
  phase="done"
  case "$current" in
    stopped)
      printf 'starting the previous service\n' >&2
      systemctl --user start "$UNIT_NAME" || true # portability: VPS-only fork tooling (Linux, systemd user unit)
      ;;
    backed-up)
      printf 'restoring the previous service\n' >&2
      if ( fork_restore_backup "$DEST" ); then
        # The copy is not what the unit runs anymore. A retry can install it again.
        # Only the directory this run created is removed.
        if [ -n "$created_release" ]; then
          fork_remove_created_dir "$created_release" "$HOME_DIR/desktop-runtime/releases" "$created_release_token" || true
        fi
      else
        systemctl --user start "$UNIT_NAME" || true # portability: VPS-only fork tooling (Linux, systemd user unit)
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
systemctl --user stop "$UNIT_NAME" # portability: VPS-only fork tooling (Linux, systemd user unit)

STAMP=$(fork_backup_stamp)
DEST="$BACKUP_ROOT/$STAMP"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  fork_die "backup already exists: $DEST"
fi
mkdir -m 0700 -- "$DEST" || fork_die "cannot create $DEST"
mkdir -m 0700 -- "$DEST/db" "$DEST/home" || fork_die "cannot create $DEST"
dest_mode=$(stat -c %a -- "$DEST") # portability: VPS-only fork tooling (Linux, systemd user unit)
[ "$dest_mode" = "700" ] || fork_die "timestamped backup is mode $dest_mode, expected 700"

FP_TIMON=$(fork_sqlite_backup "$HOME_DIR/timon.db" "$DEST/db/timon.db")
FP_INTEGRATIONS=$(fork_sqlite_backup "$HOME_DIR/integrations.db" "$DEST/db/integrations.db")

RSYNC_EXCLUDES="--exclude /desktop-runtime --exclude /worktrees --exclude /provider-runs --exclude /backups --exclude /run --exclude /tmp --exclude /updates --exclude /provider-cache --exclude /trash --exclude /timon.db --exclude /timon.db-wal --exclude /timon.db-shm --exclude /integrations.db --exclude /integrations.db-wal --exclude /integrations.db-shm"
# shellcheck disable=SC2086
rsync -a $RSYNC_EXCLUDES "$HOME_DIR/" "$DEST/home/" # portability: VPS-only fork tooling (Linux, systemd user unit)
# shellcheck disable=SC2086
leftover=$(rsync -a --dry-run --itemize-changes $RSYNC_EXCLUDES "$HOME_DIR/" "$DEST/home/") # portability: VPS-only fork tooling (Linux, systemd user unit)
[ -z "$leftover" ] || fork_die "home backup does not match the source"

RELEASE_SRC="$HOME_DIR/desktop-runtime/releases/$ACTIVE"
release_backup=$(fork_confine_file "$DEST/official-release" "$DEST" "official release backup") || exit 1
cp -a -- "$RELEASE_SRC" "$release_backup" # portability: VPS-only fork tooling (Linux, systemd user unit)
src_sum=$(sha256sum "$RELEASE_SRC/resources/orchestrator/release-manifest.json" | awk '{print $1}') # portability: VPS-only fork tooling (Linux, systemd user unit)
dst_sum=$(sha256sum "$DEST/official-release/resources/orchestrator/release-manifest.json" | awk '{print $1}') # portability: VPS-only fork tooling (Linux, systemd user unit)
[ "$src_sum" = "$dst_sum" ] || fork_die "official release backup does not match the manifest"
src_n=$(find "$RELEASE_SRC" -type f | wc -l) # portability: VPS-only fork tooling (Linux, systemd user unit)
dst_n=$(find "$DEST/official-release" -type f | wc -l) # portability: VPS-only fork tooling (Linux, systemd user unit)
[ "$src_n" = "$dst_n" ] || fork_die "official release backup file count differs ($src_n vs $dst_n)"

unit_backup=$(fork_confine_file "$DEST/unit.service" "$DEST" "unit backup") || exit 1
cp -a -- "$UNIT_FILE" "$unit_backup" # portability: VPS-only fork tooling (Linux, systemd user unit)
active_backup=$(fork_confine_file "$DEST/active-release" "$DEST" "active-release backup") || exit 1
cp -a -- "$HOME_DIR/desktop-runtime/active-release" "$active_backup" # portability: VPS-only fork tooling (Linux, systemd user unit)
manifest=$(fork_confine_file "$DEST/manifest.json" "$DEST" "backup manifest") || exit 1
jq -n \
  --arg stamp "$STAMP" \
  --arg unit "$UNIT_NAME" \
  --arg port "$PORT" \
  --arg active "$ACTIVE" \
  --arg package "$VERSION_ID" \
  --arg timon "$FP_TIMON" \
  --arg integrations "$FP_INTEGRATIONS" \
  '{stamp: $stamp, unit: $unit, port: $port, activeRelease: $active, packageVersionId: $package, databases: {"timon.db": {fingerprint: $timon}, "integrations.db": {fingerprint: $integrations}}}' \
  > "$manifest"
fork_privatize_tree "$DEST"
for db_name in timon.db integrations.db; do
  db_copy="$DEST/db/$db_name"
  [ -f "$db_copy" ] || continue
  db_mode=$(stat -c %a -- "$db_copy") # portability: VPS-only fork tooling (Linux, systemd user unit)
  [ "$db_mode" = "600" ] || fork_die "backup of $db_name is mode $db_mode, expected 600"
done
printf 'backup %s\n' "$DEST"
phase=backed-up

partial="$HOME_DIR/desktop-runtime/releases/$VERSION_ID.partial"
if [ -e "$partial" ] || [ -L "$partial" ]; then
  fork_die "partial release already exists: $partial"
fi
partial=$(fork_confine_file "$partial" "$(dirname -- "$partial")" "partial release") || exit 1
if ! cp -a -- "$PACKAGE" "$partial"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
  if [ -d "$partial" ] && [ ! -L "$partial" ]; then
    fork_remove_created_dir "$partial" "$HOME_DIR/desktop-runtime/releases" "$(stat -c '%d:%i' -- "$partial")" || true # portability: VPS-only fork tooling (Linux, systemd user unit)
  fi
  fork_die "cannot copy the package"
fi
created_release_token=$(stat -c '%d:%i' -- "$partial") # portability: VPS-only fork tooling (Linux, systemd user unit)
created_release=$partial
if ! mv -T -- "$partial" "$TARGET"; then
  fork_die "cannot install release directory"
fi
created_release=$TARGET
[ -f "$TARGET/resources/orchestrator/dist/host/packaged-runner.js" ] || fork_die "copied package has no service runner"

OLD_PATH="$HOME_DIR/desktop-runtime/releases/$ACTIVE"
NEW_PATH="$TARGET"
unit_file=$(fork_confine_file "$UNIT_FILE" "$(dirname -- "$UNIT_FILE")" "unit file") || exit 1
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
' "$unit_file" "$OLD_PATH" "$NEW_PATH" "$VERSION_ID"

active_pointer=$(fork_confine_file "$HOME_DIR/desktop-runtime/active-release" "$HOME_DIR/desktop-runtime" "active release") || exit 1
printf '%s\n' "$VERSION_ID" > "$active_pointer"
systemctl --user daemon-reload # portability: VPS-only fork tooling (Linux, systemd user unit)
systemctl --user restart "$UNIT_NAME" # portability: VPS-only fork tooling (Linux, systemd user unit)
UNIT_HOME=$(fork_unit_home "$UNIT_FILE")
fork_health "$PORT" 60 "$UNIT_HOME" "$UNIT_NAME" >/dev/null
phase="done"
printf 'active-release %s\n' "$VERSION_ID"
printf 'rollback: %s --backup %s --apply\n' "$(fork_script_dir "$SCRIPT")/rollback.sh" "$DEST"
