#!/bin/sh
# Point the service back at the official release saved by install.sh.
# Every database that existed at backup time is replaced by that copy.
# The live file is moved aside, not deleted. A database the fork created
# is moved aside too. See fork_maybe_restore_db in lib.sh.
# Without --apply it prints the plan and does not restart anything.
# With --apply, a failure after the unit has been stopped starts it again.
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

# Same lock as install.sh --apply, taken before the mission check and held
# through the EXIT trap. A second apply is refused instead of waiting.
if [ "$APPLY" -eq 1 ]; then
  fork_acquire_apply_lock
fi

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

# fork_restore_backup stops the unit and returns on failure instead of
# exiting. Under set -e an unguarded failure would still run an EXIT trap,
# but the call stays in this if so the failure is the script's own exit.
fork_restore_stopped=0
fork_restore_healthy=0
fork_restore_unit_file=0
fork_restore_pointer=0
fork_restore_release=0
fork_restore_dbs=0

rollback_restore_word() {
  case "$1" in
    1) printf 'restored' ;;
    2) printf 'already in place' ;;
    *) printf 'not restored' ;;
  esac
}

rollback_finish() {
  ec=$?
  trap - EXIT
  if [ "$fork_restore_stopped" -eq 1 ] && [ "$fork_restore_healthy" -ne 1 ]; then
    printf 'rollback: the unit was stopped and the restore did not finish\n' >&2
    printf 'rollback: unit file %s; active-release %s; release %s; databases %s\n' \
      "$(rollback_restore_word "$fork_restore_unit_file")" \
      "$(rollback_restore_word "$fork_restore_pointer")" \
      "$(rollback_restore_word "$fork_restore_release")" \
      "$(rollback_restore_word "$fork_restore_dbs")" >&2
    printf 'rollback: starting %s again\n' "$UNIT_NAME" >&2
    if systemctl --user start "$UNIT_NAME"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
      if fork_health "$PORT" 60 "$(fork_unit_home "$UNIT_FILE")" "$UNIT_NAME" >/dev/null; then
        printf 'rollback: %s is answering on port %s; the saved copy was not fully restored\n' "$UNIT_NAME" "$PORT" >&2
      else
        printf 'rollback: %s was started but is not answering on port %s; the saved copy was not fully restored\n' "$UNIT_NAME" "$PORT" >&2
      fi
    else
      printf 'rollback: could not start %s; the saved copy was not fully restored\n' "$UNIT_NAME" >&2
    fi
  fi
  exit "$ec"
}
trap rollback_finish EXIT

if ! fork_restore_backup "$BACKUP" recheck; then
  exit 1
fi
printf 'active-release %s\n' "$(tr -d '[:space:]' < "$(fork_home)/desktop-runtime/active-release")"
printf 'unit %s\n' "$UNIT_FILE"
