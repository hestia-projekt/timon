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

# A caller-selected directory that already exists is never chmodded.
# A shared directory (sticky and world-writable) is refused and left as it was.
# A missing directory is created 0700. The live home is not a write target.
shared=$ROOT_TMP/shared
mkdir -m 1777 -- "$shared"
printf 'keep\n' > "$shared/marker"
shared_before=$(stat -c '%a %u %i' -- "$shared")

expect_die() {
  set +e
  ( "$@" ) > "$ROOT_TMP/out" 2> "$ROOT_TMP/err"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf 'FAIL expected failure\n' >&2
    cat "$ROOT_TMP/out" >&2
    cat "$ROOT_TMP/err" >&2
    exit 1
  fi
}

expect_die fork_prepare_private_dir "$shared" "backup directory" create
assert_err "mode 1777"
assert_err "not changing it"
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "shared dir unchanged"
assert_eq "$(cat "$shared/marker")" "keep" "shared marker"

ln -s "$shared" "$ROOT_TMP/shared-link"
expect_die fork_prepare_private_dir "$ROOT_TMP/shared-link" "backup directory" create
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "symlink target unchanged"
assert_eq "$(cat "$shared/marker")" "keep" "marker after symlink"

created=$shared/fork-backups
run_ok fork_prepare_private_dir "$created" "backup directory" create
assert_eq "$(stat -c %a -- "$created")" "700" "created backup root"
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "parent unchanged"
assert_eq "$(cat "$ROOT_TMP/out")" "$(realpath -m -- "$created")" "created path"

open=$ROOT_TMP/open-root
mkdir -m 0755 -- "$open"
expect_die fork_prepare_private_dir "$open" "backup directory" create
assert_err "mode 755"
assert_eq "$(stat -c %a -- "$open")" "755" "open mode unchanged"

sticky=$ROOT_TMP/sticky-root
mkdir -m 1700 -- "$sticky"
expect_die fork_prepare_private_dir "$sticky" "backup directory" create
assert_err "mode 1700"
assert_eq "$(stat -c %a -- "$sticky")" "1700" "sticky mode unchanged"

mine=$ROOT_TMP/private-root
mkdir -m 0700 -- "$mine"
mine_before=$(stat -c '%a %i' -- "$mine")
run_ok fork_prepare_private_dir "$mine" "backup directory" create
assert_eq "$(stat -c '%a %i' -- "$mine")" "$mine_before" "private root untouched"
assert_eq "$(cat "$ROOT_TMP/out")" "$(realpath -m -- "$mine")" "private path"

missing=$ROOT_TMP/not-created
run_ok fork_prepare_private_dir "$missing" "backup directory" check
if [ -e "$missing" ]; then
  printf 'FAIL check created %s\n' "$missing" >&2
  exit 1
fi

expect_die fork_prepare_private_dir "$ROOT_TMP/still-missing" "backup" existing
if [ -e "$ROOT_TMP/still-missing" ]; then
  printf 'FAIL existing created a directory\n' >&2
  exit 1
fi

chmod 0700 "$HOME_DIR"
home_before=$(stat -c '%a %i' -- "$HOME_DIR")
expect_die fork_prepare_private_dir "$HOME_DIR" "backup directory" create
assert_err "live Timon home"
assert_eq "$(stat -c '%a %i' -- "$HOME_DIR")" "$home_before" "home unchanged"
expect_die fork_prepare_private_dir "$HOME_DIR/nested-backup" "backup directory" create
if [ -e "$HOME_DIR/nested-backup" ]; then
  printf 'FAIL created a directory inside the live home\n' >&2
  exit 1
fi

# Restricting a tree refuses a shared root and does not chmod it.
# A private tree this run created still has its contents tightened.
expect_die fork_privatize_tree "$shared"
assert_err "not changing it"
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "privatize left shared dir"
assert_eq "$(cat "$shared/marker")" "keep" "privatize left marker"

priv=$ROOT_TMP/priv-tree
mkdir -m 0700 -- "$priv"
mkdir -m 0755 -- "$priv/sub"
printf 'data\n' > "$priv/sub/file"
chmod 0644 "$priv/sub/file"
printf '#!/bin/sh\n' > "$priv/sub/run"
chmod 0755 "$priv/sub/run"
priv_before=$(stat -c '%a %i' -- "$priv")
run_ok fork_privatize_tree "$priv"
assert_eq "$(stat -c '%a %i' -- "$priv")" "$priv_before" "privatize left the root"
assert_eq "$(stat -c %a -- "$priv/sub")" "700" "privatize directory"
assert_eq "$(stat -c %a -- "$priv/sub/file")" "600" "privatize file"
assert_eq "$(stat -c %a -- "$priv/sub/run")" "700" "privatize executable"

# Recursive removal only for a directory this run created.
made=$ROOT_TMP/made
mkdir -m 0700 -- "$made"
mkdir -m 0700 -- "$made/leaf"
printf 'gone\n' > "$made/leaf/f"
leaf_token=$(stat -c '%d:%i' -- "$made/leaf")
run_ok fork_remove_created_dir "$made/leaf" "$made" "$leaf_token"
if [ -e "$made/leaf" ]; then
  printf 'FAIL created directory was not removed\n' >&2
  exit 1
fi
if [ ! -d "$made" ]; then
  printf 'FAIL parent was removed\n' >&2
  exit 1
fi

expect_fail fork_remove_created_dir "$shared" "$ROOT_TMP" "0:0"
assert_err "not the directory this run created"
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "shared dir after refused remove"
assert_eq "$(cat "$shared/marker")" "keep" "marker after refused remove"

ln -s "$shared" "$made/link"
expect_fail fork_remove_created_dir "$made/link" "$made" "0:0"
assert_err "refusing to remove symlink"
assert_eq "$(cat "$shared/marker")" "keep" "symlink target kept"
if [ ! -L "$made/link" ]; then
  printf 'FAIL symlink was removed\n' >&2
  exit 1
fi

home_token=$(stat -c '%d:%i' -- "$HOME_DIR")
expect_fail fork_remove_created_dir "$HOME_DIR" "$ROOT_TMP" "$home_token"
assert_err "live Timon home"
if [ ! -d "$HOME_DIR" ]; then
  printf 'FAIL live home was removed\n' >&2
  exit 1
fi

# An incomplete release is moved aside, not deleted. A symlink is refused.
rel=$HOME_DIR/desktop-runtime/releases/0.1.8-test
mkdir -p -- "$rel"
printf 'official\n' > "$rel/keep"
run_ok fork_move_incomplete_release "0.1.8-test"
aside=$(cat "$ROOT_TMP/out")
assert_eq "$(cat "$aside/keep")" "official" "moved bytes"
if [ -e "$rel" ]; then
  printf 'FAIL release path still present\n' >&2
  exit 1
fi
if [ ! -d "$aside" ]; then
  printf 'FAIL incomplete release was deleted\n' >&2
  exit 1
fi

ln -s "$shared" "$HOME_DIR/desktop-runtime/releases/0.1.9-test"
expect_fail fork_move_incomplete_release "0.1.9-test"
assert_err "symlink"
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "shared kept when release is a symlink"
assert_eq "$(cat "$shared/marker")" "keep" "marker kept when release is a symlink"
if [ ! -L "$HOME_DIR/desktop-runtime/releases/0.1.9-test" ]; then
  printf 'FAIL symlink release was removed\n' >&2
  exit 1
fi

expect_fail fork_move_incomplete_release ".."
assert_err "refusing version id"

link_home=$ROOT_TMP/link-home
mkdir -m 0700 -- "$link_home"
mkdir -m 0700 -- "$link_home/desktop-runtime"
ln -s "$shared" "$link_home/desktop-runtime/releases"
old_home=$TIMON_FORK_DATA_HOME
TIMON_FORK_DATA_HOME=$link_home
expect_fail fork_move_incomplete_release "0.1.8-test"
TIMON_FORK_DATA_HOME=$old_home
assert_err "symlink"
assert_eq "$(stat -c '%a %u %i' -- "$shared")" "$shared_before" "shared kept when releases is a symlink"
assert_eq "$(cat "$shared/marker")" "keep" "marker kept when releases is a symlink"

# A symlink in the preparation directory that points at a disposable home
# is refused. Nothing there is written or removed. This home is not ~/.timon.
FAKE_USER=$ROOT_TMP/fake-user
FAKE_HOME=$FAKE_USER/.timon
case "$FAKE_HOME" in
  "$ROOT_TMP"/*) ;;
  *)
    printf 'FAIL fake home is not under the temp dir\n' >&2
    exit 1
    ;;
esac
case "$FAKE_HOME" in
  "$HOME/.timon"|"$HOME/.timon"/*)
    printf 'FAIL fake home is the live Timon home\n' >&2
    exit 1
    ;;
esac
mkdir -p "$FAKE_HOME/stage/0.1.8-fork.abc" "$FAKE_HOME/0.1.8-fork.abc"
printf 'keep-stage\n' > "$FAKE_HOME/stage/0.1.8-fork.abc/victim"
printf 'keep-out\n' > "$FAKE_HOME/0.1.8-fork.abc/victim"
printf 'keep-marker\n' > "$FAKE_HOME/marker"
chmod 0700 "$FAKE_HOME"

home_snapshot() {
  find "$FAKE_HOME" -printf '%P %y\n' | sort
}
before_home=$(home_snapshot)

run_assemble() {
  HOME=$FAKE_USER node "$ROOT/assemble-release.mjs" \
    --checkout "$1" \
    --stage "$2" \
    --output "$3" \
    --shell "$4" \
    --key-dir "$5" \
    --version-id 0.1.8-fork.abc \
    --commit abcdefabcdef \
    --modules "$6"
}

# The lexical path ends in /stage/<version>. The old guard looked only at
# that last component, so a link higher up walked into the fake home.
prep_anc=$ROOT_TMP/prep-ancestor
mkdir -p "$prep_anc"
ln -s "$FAKE_HOME" "$prep_anc/escape"
expect_fail run_assemble \
  "$prep_anc/checkout" \
  "$prep_anc/escape/stage/0.1.8-fork.abc" \
  "$prep_anc/out/0.1.8-fork.abc" \
  "$prep_anc/shell" \
  "$prep_anc/keys" \
  "$prep_anc/modules"
assert_err "through symlink"
assert_eq "$(home_snapshot)" "$before_home" "fake home after ancestor link"
assert_eq "$(cat "$FAKE_HOME/stage/0.1.8-fork.abc/victim")" "keep-stage" "ancestor victim"
if [ -e "$prep_anc/stage" ] || [ -e "$prep_anc/out" ]; then
  printf 'FAIL preparation directory was written through an ancestor link\n' >&2
  exit 1
fi
if [ ! -L "$prep_anc/escape" ]; then
  printf 'FAIL ancestor symlink was replaced\n' >&2
  exit 1
fi

# $PREP/stage and $PREP/out are themselves the links into the fake home.
prep_stage=$ROOT_TMP/prep-stage-link
mkdir -p "$prep_stage"
ln -s "$FAKE_HOME" "$prep_stage/stage"
ln -s "$FAKE_HOME" "$prep_stage/out"
expect_fail run_assemble \
  "$prep_stage/checkout" \
  "$prep_stage/stage/0.1.8-fork.abc" \
  "$prep_stage/out/0.1.8-fork.abc" \
  "$prep_stage/shell" \
  "$prep_stage/keys" \
  "$prep_stage/modules"
assert_err "through symlink"
assert_eq "$(home_snapshot)" "$before_home" "fake home after stage link"
assert_eq "$(cat "$FAKE_HOME/0.1.8-fork.abc/victim")" "keep-out" "stage-link victim"
if [ ! -L "$prep_stage/stage" ] || [ ! -L "$prep_stage/out" ]; then
  printf 'FAIL preparation symlink was replaced\n' >&2
  exit 1
fi

# Output alone goes through the link. The stage path is real and must not be created.
prep_out=$ROOT_TMP/prep-out-link
mkdir -p "$prep_out"
ln -s "$FAKE_HOME" "$prep_out/out"
expect_fail run_assemble \
  "$prep_out/checkout" \
  "$prep_out/stage/0.1.8-fork.abc" \
  "$prep_out/out/0.1.8-fork.abc" \
  "$prep_out/shell" \
  "$prep_out/keys" \
  "$prep_out/modules"
assert_err "through symlink"
assert_eq "$(home_snapshot)" "$before_home" "fake home after output link"
if [ -e "$prep_out/stage" ]; then
  printf 'FAIL stage was created while output was refused\n' >&2
  exit 1
fi

# No symlink: the path check passes and the build stops on the missing shell,
# before creating the stage.
prep_safe=$ROOT_TMP/prep-safe
mkdir -p "$prep_safe"
expect_fail run_assemble \
  "$prep_safe/checkout" \
  "$prep_safe/stage/0.1.8-fork.abc" \
  "$prep_safe/out/0.1.8-fork.abc" \
  "$prep_safe/shell" \
  "$prep_safe/keys" \
  "$prep_safe/modules"
assert_err "not a desktop-runtime release"
if [ -e "$prep_safe/stage" ] || [ -e "$prep_safe/out" ]; then
  printf 'FAIL safe path created a directory\n' >&2
  exit 1
fi
assert_eq "$(home_snapshot)" "$before_home" "fake home after safe path"

old_data_home=$TIMON_FORK_DATA_HOME
TIMON_FORK_DATA_HOME=$FAKE_HOME
expect_die fork_confine "$prep_stage/stage/0.1.8-fork.abc" "$prep_stage" "stage"
assert_err "leaves the preparation root"
assert_eq "$(cat "$FAKE_HOME/0.1.8-fork.abc/victim")" "keep-out" "confine left victim"

expect_die fork_remove_script_stage "$prep_stage/stage/0.1.8-fork.abc" "$prep_stage/stage" "0.1.8-fork.abc"
assert_err "leaves the preparation root"
assert_eq "$(cat "$FAKE_HOME/0.1.8-fork.abc/victim")" "keep-out" "remove left victim"
if [ ! -L "$prep_stage/stage" ]; then
  printf 'FAIL stage symlink was removed\n' >&2
  exit 1
fi

expect_die fork_confine "$prep_stage/stage/0.1.8-fork.missing" "$prep_stage" "stage"
assert_err "leaves the preparation root"
if [ -e "$FAKE_HOME/0.1.8-fork.missing" ]; then
  printf 'FAIL missing stage was created in the fake home\n' >&2
  exit 1
fi

ok_prep=$ROOT_TMP/prep-confine-ok
mkdir -p "$ok_prep"
run_ok fork_confine "$ok_prep/stage/0.1.8-fork.abc" "$ok_prep" "stage"
assert_eq "$(cat "$ROOT_TMP/out")" "$(realpath -m -- "$ok_prep/stage/0.1.8-fork.abc")" "confined path"
if [ -e "$ok_prep/stage" ]; then
  printf 'FAIL confine created the stage\n' >&2
  exit 1
fi

real_prep=$ROOT_TMP/prep-real-stage
mkdir -p "$real_prep/stage/0.1.8-fork.abc"
printf 'gone\n' > "$real_prep/stage/0.1.8-fork.abc/f"
run_ok fork_remove_script_stage "$real_prep/stage/0.1.8-fork.abc" "$real_prep/stage" "0.1.8-fork.abc"
if [ -e "$real_prep/stage/0.1.8-fork.abc" ]; then
  printf 'FAIL real stage was not removed\n' >&2
  exit 1
fi
if [ ! -d "$real_prep/stage" ]; then
  printf 'FAIL stage parent was removed\n' >&2
  exit 1
fi

mkdir -p "$FAKE_HOME/sub"
printf 'data\n' > "$FAKE_HOME/sub/file"
chmod 0644 "$FAKE_HOME/sub/file"
chmod 0755 "$FAKE_HOME/sub"
priv_link=$ROOT_TMP/priv-link
mkdir -p "$priv_link"
ln -s "$FAKE_HOME" "$priv_link/alias"
expect_die fork_privatize_tree "$priv_link/alias/sub"
assert_err "inside the live Timon home"
assert_eq "$(stat -c %a -- "$FAKE_HOME/sub/file")" "644" "privatize left file"
assert_eq "$(stat -c %a -- "$FAKE_HOME/sub")" "755" "privatize left directory"

# A planted file symlink is not a write target. Redirection and openssl -out
# would follow it, and [ ! -f ] is true when the link is dangling.
file_dir=$ROOT_TMP/file-confine
mkdir -p "$file_dir"
printf 'keep-file\n' > "$ROOT_TMP/file-victim"
ln -s "$ROOT_TMP/file-victim" "$file_dir/list"
file_inode=$(stat -c %i -- "$ROOT_TMP/file-victim")
expect_die fork_confine_file "$file_dir/list" "$file_dir" "file list"
assert_err "refusing to follow symlink"
assert_eq "$(cat "$ROOT_TMP/file-victim")" "keep-file" "file symlink victim"
assert_eq "$(stat -c %i -- "$ROOT_TMP/file-victim")" "$file_inode" "file symlink inode"
if [ ! -L "$file_dir/list" ]; then
  printf 'FAIL planted file symlink was replaced\n' >&2
  exit 1
fi

dangling_target=$ROOT_TMP/dangling-target
ln -s "$dangling_target" "$file_dir/dangling"
expect_die fork_confine_file "$file_dir/dangling" "$file_dir" "file list"
assert_err "refusing to follow symlink"
if [ -e "$dangling_target" ] || [ -L "$dangling_target" ]; then
  printf 'FAIL dangling symlink target was created\n' >&2
  exit 1
fi

mkdir -p "$file_dir/not-a-file"
expect_die fork_confine_file "$file_dir/not-a-file" "$file_dir" "file list"
assert_err "not a regular file"
if [ ! -d "$file_dir/not-a-file" ]; then
  printf 'FAIL directory leaf was removed\n' >&2
  exit 1
fi

ln -s "$file_dir" "$ROOT_TMP/parent-link"
expect_die fork_confine_file "$ROOT_TMP/parent-link/new" "$ROOT_TMP/parent-link" "file list"
assert_err "parent is a symlink"
if [ -e "$file_dir/new" ]; then
  printf 'FAIL symlink parent was written\n' >&2
  exit 1
fi

expect_die fork_confine_file "$file_dir/../outside-file" "$file_dir" "file list"
assert_err "leaves its confined parent"
if [ -e "$ROOT_TMP/outside-file" ]; then
  printf 'FAIL escaped path was created\n' >&2
  exit 1
fi

run_ok fork_confine_file "$file_dir/missing" "$file_dir" "file list"
assert_eq "$(cat "$ROOT_TMP/out")" "$(realpath -m -- "$file_dir/missing")" "missing file path"
if [ -e "$file_dir/missing" ]; then
  printf 'FAIL confine created the file\n' >&2
  exit 1
fi
printf 'regular\n' > "$file_dir/regular"
run_ok fork_confine_file "$file_dir/regular" "$file_dir" "file list"
assert_eq "$(cat "$ROOT_TMP/out")" "$(realpath -m -- "$file_dir/regular")" "regular file path"
assert_eq "$(cat "$file_dir/regular")" "regular" "regular file untouched"

key_dir=$ROOT_TMP/keys-dangling
mkdir -m 0700 "$key_dir"
key_target=$ROOT_TMP/key-target
ln -s "$key_target" "$key_dir/fork-release.key.pem"
expect_die fork_ensure_release_keys "$key_dir"
assert_err "refusing to follow symlink"
if [ -e "$key_target" ] || [ -L "$key_target" ]; then
  printf 'FAIL private key was written through a dangling symlink\n' >&2
  exit 1
fi
if [ ! -L "$key_dir/fork-release.key.pem" ]; then
  printf 'FAIL key symlink was replaced\n' >&2
  exit 1
fi

key_dir=$ROOT_TMP/keys-victim
mkdir -m 0700 "$key_dir"
printf 'not-a-key\n' > "$ROOT_TMP/key-victim"
key_inode=$(stat -c %i -- "$ROOT_TMP/key-victim")
ln -s "$ROOT_TMP/key-victim" "$key_dir/fork-release.key.pem"
expect_die fork_ensure_release_keys "$key_dir"
assert_err "refusing to follow symlink"
assert_eq "$(cat "$ROOT_TMP/key-victim")" "not-a-key" "key victim"
assert_eq "$(stat -c %i -- "$ROOT_TMP/key-victim")" "$key_inode" "key victim inode"
if [ ! -L "$key_dir/fork-release.key.pem" ]; then
  printf 'FAIL key symlink to a file was replaced\n' >&2
  exit 1
fi

key_ok=$ROOT_TMP/keys-ok
mkdir -m 0700 "$key_ok"
key_umask=$(umask)
run_ok fork_ensure_release_keys "$key_ok"
assert_eq "$(umask)" "$key_umask" "umask restored"
assert_eq "$(stat -c %a -- "$key_ok/fork-release.key.pem")" "600" "private key mode"
assert_eq "$(stat -c %a -- "$key_ok/fork-release.pub.pem")" "600" "public key mode"
if [ -L "$key_ok/fork-release.key.pem" ] || [ -L "$key_ok/fork-release.pub.pem" ]; then
  printf 'FAIL release key is a symlink\n' >&2
  exit 1
fi
priv_inode=$(stat -c %i -- "$key_ok/fork-release.key.pem")
pub_inode=$(stat -c %i -- "$key_ok/fork-release.pub.pem")
run_ok fork_ensure_release_keys "$key_ok"
assert_eq "$(stat -c %i -- "$key_ok/fork-release.key.pem")" "$priv_inode" "private key reused"
assert_eq "$(stat -c %i -- "$key_ok/fork-release.pub.pem")" "$pub_inode" "public key reused"
mv -- "$key_ok/fork-release.pub.pem" "$key_ok/pub.real"
ln -s "$ROOT_TMP/key-victim" "$key_ok/fork-release.pub.pem"
expect_die fork_ensure_release_keys "$key_ok"
assert_err "refusing to follow symlink"
assert_eq "$(cat "$ROOT_TMP/key-victim")" "not-a-key" "public key victim"
assert_eq "$(stat -c %i -- "$key_ok/fork-release.key.pem")" "$priv_inode" "private key kept when public key is a symlink"

reset_dirs
make_original "$HOME_DIR/timon.db"
printf 'keep-backup\n' > "$ROOT_TMP/backup-victim"
ln -s "$ROOT_TMP/backup-victim" "$BACKUP/db/timon.db"
expect_die fork_sqlite_backup "$HOME_DIR/timon.db" "$BACKUP/db/timon.db"
assert_err "refusing to follow symlink"
assert_eq "$(cat "$ROOT_TMP/backup-victim")" "keep-backup" "backup victim"
if [ ! -L "$BACKUP/db/timon.db" ]; then
  printf 'FAIL backup symlink was replaced\n' >&2
  exit 1
fi

# build.sh stops before a worktree when a file in the preparation directory
# is a symlink. The victim is left untouched. Stubs satisfy the cheap checks.
REPO=$(fork_repo "$ROOT/build.sh")
COMMIT=$(git -C "$REPO" rev-parse HEAD)
SHORT=$(git -C "$REPO" rev-parse --short=12 "$COMMIT")
UPSTREAM=$(git -C "$REPO" show "$COMMIT:orchestrator/package.json" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1)
if [ -z "$UPSTREAM" ]; then
  printf 'FAIL no version in orchestrator/package.json\n' >&2
  exit 1
fi
VERSION_ID="${UPSTREAM}-fork.${SHORT}"
stub_shell=$ROOT_TMP/stub-shell
stub_modules=$ROOT_TMP/stub-modules
mkdir -p "$stub_shell/resources/orchestrator" "$stub_modules/typescript/bin"
: > "$stub_modules/typescript/bin/tsc"
home_before=$(home_snapshot)

prep_list=$ROOT_TMP/prep-file-link
mkdir -p "$prep_list/out"
printf 'keep-list\n' > "$ROOT_TMP/list-victim"
list_inode=$(stat -c %i -- "$ROOT_TMP/list-victim")
ln -s "$ROOT_TMP/list-victim" "$prep_list/out/${VERSION_ID}.files.sha256"
expect_fail "$ROOT/build.sh" --prep "$prep_list" --commit HEAD --shell "$stub_shell" --modules "$stub_modules"
assert_err "refusing to follow symlink"
assert_eq "$(cat "$ROOT_TMP/list-victim")" "keep-list" "build list victim"
assert_eq "$(stat -c %i -- "$ROOT_TMP/list-victim")" "$list_inode" "build list inode"
if [ ! -L "$prep_list/out/${VERSION_ID}.files.sha256" ]; then
  printf 'FAIL list symlink was replaced\n' >&2
  exit 1
fi
if [ -e "$prep_list/src" ] || [ -e "$prep_list/stage" ] || [ -e "$prep_list/keys" ]; then
  printf 'FAIL build continued after a planted file symlink\n' >&2
  exit 1
fi

prep_key=$ROOT_TMP/prep-key-link
mkdir -p "$prep_key/keys/$VERSION_ID"
chmod 0700 "$prep_key" "$prep_key/keys" "$prep_key/keys/$VERSION_ID"
key_missing=$ROOT_TMP/key-missing
ln -s "$key_missing" "$prep_key/keys/$VERSION_ID/fork-release.key.pem"
expect_fail "$ROOT/build.sh" --prep "$prep_key" --commit HEAD --shell "$stub_shell" --modules "$stub_modules"
assert_err "refusing to follow symlink"
if [ -e "$key_missing" ] || [ -L "$key_missing" ]; then
  printf 'FAIL build wrote the private key through a dangling symlink\n' >&2
  exit 1
fi
if [ ! -L "$prep_key/keys/$VERSION_ID/fork-release.key.pem" ]; then
  printf 'FAIL build replaced the key symlink\n' >&2
  exit 1
fi
if [ -e "$prep_key/src" ] || [ -e "$prep_key/stage" ]; then
  printf 'FAIL build continued after a planted key symlink\n' >&2
  exit 1
fi
assert_eq "$(home_snapshot)" "$home_before" "fake home after planted file symlinks"
TIMON_FORK_DATA_HOME=$old_data_home

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
