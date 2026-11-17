#!/bin/sh
# Point the service back at the official release saved by install.sh.
# A saved database is restored when the live file is missing or its schema
# differs. A database that did not exist at backup time is removed if the
# fork created it. See fork_maybe_restore_db in lib.sh.
# Without --apply it prints the plan and does not restart anything.
#
#   ops/fork-build/rollback.sh --backup DIR
#   ops/fork-build/rollback.sh --backup DIR --apply
#
# See ops/fork-build/README.md. This is not `timon update apply`.
set -eu

SCRIPT=$0
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$SCRIPT")" && pwd)/lib.sh"

APPLY=0
BACKUP=
while [ $# -gt 0 ]; do
  case $1 in
    --apply) APPLY=1; shift ;;
    --backup) BACKUP=$2; shift 2 ;;
    *) fork_die "unknown argument $1" ;;
  esac
done
[ -n "$BACKUP" ] || fork_die "pass --backup DIR"
# Resolve the directory. Do not chmod it: a shared path is refused instead.
BACKUP=$(fork_prepare_private_dir "$BACKUP" "backup" existing)
[ -f "$BACKUP/manifest.json" ] || fork_die "no manifest in $BACKUP"

UNIT_FILE=$(fork_unit_file)
UNIT_NAME=$(fork_unit_name)
UNIT_HOME=$(fork_unit_home "$UNIT_FILE")
PORT=$(jq -r '.port' "$BACKUP/manifest.json")
ACTIVE=$(jq -r '.activeRelease' "$BACKUP/manifest.json")
printf 'restore-release %s\n' "$ACTIVE"
printf 'backup %s\n' "$BACKUP"

if fork_health "$PORT" 1 "$UNIT_HOME" "$UNIT_NAME" >/dev/null; then
  fork_assert_idle "$(fork_home)" "$PORT" "$SCRIPT"
else
  printf 'daemon is not answering; rollback continues\n'
fi

if [ "$APPLY" -ne 1 ]; then
  printf 'dry-run: the service was not restarted\n'
  printf 'apply: %s --backup %s --apply\n' "$SCRIPT" "$BACKUP"
  exit 0
fi

fork_restore_backup "$BACKUP" recheck
printf 'active-release %s\n' "$(tr -d '[:space:]' < "$(fork_home)/desktop-runtime/active-release")"
printf 'unit %s\n' "$UNIT_FILE"
