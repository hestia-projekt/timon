#!/bin/sh
# Replay database restore against a temporary home.
# Never writes ~/.timon and never calls systemd.
set -eu

SCRIPT=$0
ROOT=$(cd -- "$(dirname -- "$SCRIPT")" && pwd)
# shellcheck disable=SC1091
. "$ROOT/lib.sh"

ROOT_TMP=$(mktemp -d /tmp/fork-restore-db.XXXXXX)
trap 'rm -rf -- "$ROOT_TMP"' EXIT

case "$ROOT_TMP" in
  /tmp/*) ;;
  *)
    printf 'refusing temp dir %s\n' "$ROOT_TMP" >&2
    exit 1
    ;;
esac
case "$ROOT_TMP" in
  "$HOME/.timon"|"$HOME/.timon"/*)
    printf 'refusing to use the live Timon home\n' >&2
    exit 1
    ;;
esac

HOME_DIR=$ROOT_TMP/home
BACKUP=$ROOT_TMP/backup
export TIMON_HOME="$HOME_DIR"
export TIMON_FORK_DATA_HOME="$HOME_DIR"
export FORK_TEST_SYSTEMCTL_LOG="$ROOT_TMP/systemctl.log"

mkdir -p -- "$ROOT_TMP/bin"
cat > "$ROOT_TMP/bin/systemctl" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FORK_TEST_SYSTEMCTL_LOG"
exit 99
EOF
chmod 755 "$ROOT_TMP/bin/systemctl"
export PATH="$ROOT_TMP/bin:$PATH"
: > "$FORK_TEST_SYSTEMCTL_LOG"

systemctl_path=$(command -v systemctl)
case "$systemctl_path" in
  "$ROOT_TMP/bin/systemctl") ;;
  *)
    printf 'systemctl is %s, not the test fake\n' "$systemctl_path" >&2
    exit 1
    ;;
esac

printf 'temporary home %s\n' "$HOME_DIR"

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL %s\n got [%s]\n expected [%s]\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

assert_file() {
  if [ ! -f "$1" ]; then
    printf 'FAIL missing file %s\n' "$1" >&2
    exit 1
  fi
}

assert_gone() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    printf 'FAIL still present %s\n' "$1" >&2
    exit 1
  fi
}

assert_out() {
  if ! grep -F -q -- "$1" "$ROOT_TMP/out"; then
    printf 'FAIL stdout missing [%s]\n' "$1" >&2
    cat "$ROOT_TMP/out" >&2
    printf 'stderr:\n' >&2
    cat "$ROOT_TMP/err" >&2
    exit 1
  fi
}

assert_err() {
  if ! grep -F -q -- "$1" "$ROOT_TMP/err"; then
    printf 'FAIL stderr missing [%s]\n' "$1" >&2
    cat "$ROOT_TMP/err" >&2
    exit 1
  fi
}

no_restore_leftovers() {
  found=$(find "$HOME_DIR" -name '.restore-*' -print)
  if [ -n "$found" ]; then
    printf 'FAIL leftover restore file:\n%s\n' "$found" >&2
    exit 1
  fi
}

reset_dirs() {
  umask 022
  rm -rf -- "$HOME_DIR" "$BACKUP"
  mkdir -- "$HOME_DIR" "$BACKUP"
  mkdir -- "$BACKUP/db"
  chmod 0700 "$HOME_DIR" "$BACKUP" "$BACKUP/db"
  : > "$ROOT_TMP/out"
  : > "$ROOT_TMP/err"
}

run_ok() {
  set +e
  "$@" > "$ROOT_TMP/out" 2> "$ROOT_TMP/err"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    printf 'FAIL expected success, status %s\n' "$status" >&2
    cat "$ROOT_TMP/out" >&2
    cat "$ROOT_TMP/err" >&2
    exit 1
  fi
}

expect_fail() {
  set +e
  "$@" > "$ROOT_TMP/out" 2> "$ROOT_TMP/err"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf 'FAIL expected failure\n' >&2
    cat "$ROOT_TMP/out" >&2
    cat "$ROOT_TMP/err" >&2
    exit 1
  fi
}

make_original() {
  rm -f -- "$1" "$1-wal" "$1-shm"
  sqlite3 "$1" "CREATE TABLE t(id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t(note) VALUES ('original');"
}

make_fork() {
  rm -f -- "$1" "$1-wal" "$1-shm"
  sqlite3 "$1" "CREATE TABLE other(id INTEGER PRIMARY KEY, note TEXT); INSERT INTO other(note) VALUES ('fork-row');"
}

mark_journal() {
  printf 'stale-wal\n' > "$1-wal"
  printf 'stale-shm\n' > "$1-shm"
}

write_manifest() {
  jq -n --arg timon "$1" --arg integrations "$2" \
    '{databases: {"timon.db": {fingerprint: $timon}, "integrations.db": {fingerprint: $integrations}}}' \
    > "$BACKUP/manifest.json"
}

# Live file removed after the backup: the saved copy comes back, mode 0600,
# and a leftover journal is deleted. The backup's own mode is left as it was.
reset_dirs
make_original "$HOME_DIR/integrations.db"
fp=$(fork_schema_fingerprint "$HOME_DIR/integrations.db")
cp -a -- "$HOME_DIR/integrations.db" "$BACKUP/db/integrations.db"
chmod 0644 "$BACKUP/db/integrations.db"
rm -f -- "$HOME_DIR/integrations.db"
mark_journal "$HOME_DIR/integrations.db"
run_ok fork_maybe_restore_db "$BACKUP" integrations.db "$fp"
assert_out "integrations.db restored"
assert_file "$HOME_DIR/integrations.db"
assert_eq "$(stat -c %a -- "$HOME_DIR/integrations.db")" "600" "restored mode"
assert_eq "$(stat -c %a -- "$BACKUP/db/integrations.db")" "644" "backup mode unchanged"
assert_eq "$(sqlite3 "$HOME_DIR/integrations.db" "PRAGMA integrity_check;")" "ok" "integrity"
assert_eq "$(sqlite3 "$HOME_DIR/integrations.db" "SELECT note FROM t;")" "original" "restored row"
assert_eq "$(fork_schema_fingerprint "$HOME_DIR/integrations.db")" "$fp" "restored fingerprint"
assert_gone "$HOME_DIR/integrations.db-wal"
assert_gone "$HOME_DIR/integrations.db-shm"
no_restore_leftovers

# Same schema: keep the live file, including a row written after the backup.
# The inode stays, so the backup was not copied over it.
reset_dirs
make_original "$HOME_DIR/timon.db"
fp=$(fork_schema_fingerprint "$HOME_DIR/timon.db")
cp -a -- "$HOME_DIR/timon.db" "$BACKUP/db/timon.db"
sqlite3 "$HOME_DIR/timon.db" "INSERT INTO t(note) VALUES ('later');"
before=$(stat -c %i -- "$HOME_DIR/timon.db")
rm -f -- "$BACKUP/db/timon.db"
run_ok fork_maybe_restore_db "$BACKUP" timon.db "$fp"
assert_out "timon.db schema unchanged"
assert_eq "$(stat -c %i -- "$HOME_DIR/timon.db")" "$before" "live inode"
notes=$(sqlite3 "$HOME_DIR/timon.db" "SELECT note FROM t ORDER BY id;")
assert_eq "$notes" "original
later" "rows kept"
no_restore_leftovers

# Different schema: replace the live file and drop its journal.
reset_dirs
make_original "$ROOT_TMP/official.db"
fp=$(fork_schema_fingerprint "$ROOT_TMP/official.db")
cp -a -- "$ROOT_TMP/official.db" "$BACKUP/db/timon.db"
make_fork "$HOME_DIR/timon.db"
mark_journal "$HOME_DIR/timon.db"
run_ok fork_maybe_restore_db "$BACKUP" timon.db "$fp"
assert_out "timon.db restored"
assert_eq "$(sqlite3 "$HOME_DIR/timon.db" "SELECT note FROM t;")" "original" "replaced row"
assert_eq "$(stat -c %a -- "$HOME_DIR/timon.db")" "600" "replaced mode"
assert_eq "$(sqlite3 "$HOME_DIR/timon.db" "PRAGMA integrity_check;")" "ok" "replaced integrity"
assert_gone "$HOME_DIR/timon.db-wal"
assert_gone "$HOME_DIR/timon.db-shm"
no_restore_leftovers

# absent: a database the fork created is removed, and so is a journal left
# behind without a main file. A dangling symlink is removed, not its target.
reset_dirs
make_fork "$HOME_DIR/timon.db"
mark_journal "$HOME_DIR/timon.db"
cp -a -- "$HOME_DIR/timon.db" "$BACKUP/db/timon.db"
run_ok fork_maybe_restore_db "$BACKUP" timon.db absent
assert_out "timon.db removed (absent at backup)"
assert_gone "$HOME_DIR/timon.db"
assert_gone "$HOME_DIR/timon.db-wal"
assert_gone "$HOME_DIR/timon.db-shm"
assert_file "$BACKUP/db/timon.db"

reset_dirs
mark_journal "$HOME_DIR/integrations.db"
run_ok fork_maybe_restore_db "$BACKUP" integrations.db absent
assert_out "integrations.db removed (absent at backup)"
assert_gone "$HOME_DIR/integrations.db"
assert_gone "$HOME_DIR/integrations.db-wal"
assert_gone "$HOME_DIR/integrations.db-shm"

reset_dirs
make_original "$ROOT_TMP/outside.db"
ln -s "$ROOT_TMP/outside.db" "$HOME_DIR/timon.db"
run_ok fork_maybe_restore_db "$BACKUP" timon.db absent
assert_gone "$HOME_DIR/timon.db"
assert_file "$ROOT_TMP/outside.db"
assert_eq "$(sqlite3 "$ROOT_TMP/outside.db" "SELECT note FROM t;")" "original" "symlink target kept"

reset_dirs
run_ok fork_maybe_restore_db "$BACKUP" timon.db absent
assert_out "timon.db absent"
assert_gone "$HOME_DIR/timon.db"

# A bad copy is not installed. The leftover journal stays, because it is
# removed only after the copy has passed its checks.
reset_dirs
printf 'not a database\n' > "$BACKUP/db/timon.db"
mark_journal "$HOME_DIR/timon.db"
expect_fail fork_maybe_restore_db "$BACKUP" timon.db "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_err "restored timon.db failed integrity_check"
assert_gone "$HOME_DIR/timon.db"
assert_eq "$(cat "$HOME_DIR/timon.db-wal")" "stale-wal" "wal kept after bad copy"
assert_eq "$(cat "$HOME_DIR/timon.db-shm")" "stale-shm" "shm kept after bad copy"
no_restore_leftovers

reset_dirs
make_original "$ROOT_TMP/official.db"
cp -a -- "$ROOT_TMP/official.db" "$BACKUP/db/timon.db"
mark_journal "$HOME_DIR/timon.db"
expect_fail fork_maybe_restore_db "$BACKUP" timon.db "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
assert_err "schema does not match the backup"
assert_gone "$HOME_DIR/timon.db"
assert_eq "$(cat "$HOME_DIR/timon.db-wal")" "stale-wal" "wal kept after fingerprint mismatch"
no_restore_leftovers

# Different schema, backup file missing: the fork's database stays.
reset_dirs
make_original "$ROOT_TMP/official.db"
fp=$(fork_schema_fingerprint "$ROOT_TMP/official.db")
make_fork "$HOME_DIR/timon.db"
expect_fail fork_maybe_restore_db "$BACKUP" timon.db "$fp"
assert_err "backup of timon.db is missing"
assert_eq "$(sqlite3 "$HOME_DIR/timon.db" "SELECT note FROM other;")" "fork-row" "fork row kept"

# Not a regular file: refuse, and do not delete the directory.
reset_dirs
mkdir -p -- "$HOME_DIR/timon.db"
expect_fail fork_maybe_restore_db "$BACKUP" timon.db absent
assert_err "timon.db is not a regular file"
if [ ! -d "$HOME_DIR/timon.db" ]; then
  printf 'FAIL directory was removed\n' >&2
  exit 1
fi

expect_fail fork_maybe_restore_db "$BACKUP" other.db absent
assert_err "refusing database name other.db"

# The manifest loop: a missing saved database is restored, a database that
# was absent at backup time is removed. A failure on the first stops before
# the second.
reset_dirs
make_original "$HOME_DIR/timon.db"
fp=$(fork_sqlite_backup "$HOME_DIR/timon.db" "$BACKUP/db/timon.db")
assert_eq "$(fork_schema_fingerprint "$BACKUP/db/timon.db")" "$fp" "backup fingerprint"
rm -f -- "$HOME_DIR/timon.db"
mark_journal "$HOME_DIR/timon.db"
make_fork "$HOME_DIR/integrations.db"
mark_journal "$HOME_DIR/integrations.db"
write_manifest "$fp" "absent"
run_ok fork_restore_databases "$BACKUP"
assert_out "timon.db restored"
assert_out "integrations.db removed (absent at backup)"
assert_eq "$(sqlite3 "$HOME_DIR/timon.db" "SELECT note FROM t;")" "original" "loop restored row"
assert_eq "$(stat -c %a -- "$HOME_DIR/timon.db")" "600" "loop restored mode"
assert_eq "$(sqlite3 "$HOME_DIR/timon.db" "PRAGMA integrity_check;")" "ok" "loop integrity"
assert_gone "$HOME_DIR/timon.db-wal"
assert_gone "$HOME_DIR/timon.db-shm"
assert_gone "$HOME_DIR/integrations.db"
assert_gone "$HOME_DIR/integrations.db-wal"
assert_gone "$HOME_DIR/integrations.db-shm"
no_restore_leftovers

reset_dirs
printf 'not a database\n' > "$BACKUP/db/timon.db"
make_fork "$HOME_DIR/integrations.db"
printf 'keep-integrations\n' > "$HOME_DIR/integrations.db-shm"
write_manifest "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "absent"
expect_fail fork_restore_databases "$BACKUP"
assert_err "restored timon.db failed integrity_check"
assert_gone "$HOME_DIR/timon.db"
assert_file "$HOME_DIR/integrations.db"
assert_eq "$(cat "$HOME_DIR/integrations.db-shm")" "keep-integrations" "second database left in place"
assert_eq "$(sqlite3 "$HOME_DIR/integrations.db" "SELECT note FROM other;")" "fork-row" "second row kept"
no_restore_leftovers

if [ -s "$FORK_TEST_SYSTEMCTL_LOG" ]; then
  printf 'FAIL systemctl was called\n' >&2
  cat "$FORK_TEST_SYSTEMCTL_LOG" >&2
  exit 1
fi

case "$TIMON_FORK_DATA_HOME" in
  "$HOME/.timon"|"$HOME/.timon"/*)
    printf 'FAIL home escaped the temp dir\n' >&2
    exit 1
    ;;
esac

printf 'restore-db tests ok\n'
