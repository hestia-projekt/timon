#!/bin/sh
# Shared helpers for the fork runtime scripts. English on purpose.
# A script sources this file; it does not run on its own.

fork_die() {
  printf 'fork-build: %s\n' "$1" >&2
  exit 1
}

fork_script_dir() {
  (cd -- "$(dirname -- "$1")" && pwd)
}

fork_repo() {
  git -C "$(fork_script_dir "$1")" rev-parse --show-toplevel
}

# The installation to switch. Independent of TIMON_HOME, which a smoke test sets.
fork_home() {
  printf '%s\n' "${TIMON_FORK_DATA_HOME:-$HOME/.timon}"
}

# Physical path. The last component may be missing; existing symlinks are
# followed. This does not create anything.
fork_canonical_path() {
  [ -n "$1" ] || fork_die "missing path"
  realpath -m -- "$1" || fork_die "cannot resolve $1"
}

fork_live_home_path() {
  fork_canonical_path "$(fork_home)"
}

# Refuse a path that is the live Timon home or lives inside it.
# The home itself is never a write target: a caller path that resolves to it
# is refused before anything is created or removed.
fork_assert_outside_home() {
  fah_home=$(fork_live_home_path)
  fah_target=$(fork_canonical_path "$1")
  if [ "$fah_target" = "$fah_home" ]; then
    fork_die "$2 is the live Timon home ($fah_home); refusing"
  fi
  case "$fah_target" in
    "$fah_home"/*) fork_die "$2 is inside the live Timon home ($fah_home)" ;;
  esac
}

# A directory the caller named. Nothing that already exists is chmodded.
#   create   — missing: create it mode 0700. Existing parents are not changed.
#   existing — it must already exist.
#   check    — existing directory: same rules. Missing: resolve only.
# An existing directory is accepted only when this user owns it and it is
# already mode 0700 (no group, other, sticky, or setgid bit).
fork_prepare_private_dir() {
  fpp_raw=$1
  fpp_label=$2
  fpp_how=$3
  case "$fpp_how" in
    create|existing|check) ;;
    *) fork_die "bad private-dir mode $fpp_how" ;;
  esac
  [ -n "$fpp_raw" ] || fork_die "missing $fpp_label"
  fpp_target=$(fork_canonical_path "$fpp_raw")
  fork_assert_outside_home "$fpp_target" "$fpp_label"
  if [ ! -e "$fpp_target" ] && [ ! -L "$fpp_target" ]; then
    if [ "$fpp_how" = "existing" ]; then
      fork_die "$fpp_label does not exist: $fpp_target"
    fi
    if [ "$fpp_how" = "create" ]; then
      # Parents that already exist are left alone. Only the new leaf is 0700.
      fpp_parent=$(dirname -- "$fpp_target")
      if [ ! -d "$fpp_parent" ]; then
        mkdir -p -- "$fpp_parent" || fork_die "cannot create $fpp_label $fpp_target"
      fi
      if [ ! -e "$fpp_target" ] && [ ! -L "$fpp_target" ]; then
        mkdir -m 0700 -- "$fpp_target" || fork_die "cannot create $fpp_label $fpp_target"
      fi
    fi
  fi
  if [ -e "$fpp_target" ] || [ -L "$fpp_target" ]; then
    fork_require_private_dir "$fpp_target" "$fpp_label"
  fi
  printf '%s\n' "$fpp_target"
}

# Ownership and mode of a directory the caller named. Does not chmod it.
fork_require_private_dir() {
  frp_target=$1
  frp_label=$2
  if [ -L "$frp_target" ] || [ ! -d "$frp_target" ]; then
    fork_die "$frp_label is not a directory: $frp_target"
  fi
  frp_owner=$(stat -c %u -- "$frp_target") || fork_die "cannot read ownership of $frp_target"
  frp_mode=$(stat -c %a -- "$frp_target") || fork_die "cannot read mode of $frp_target"
  frp_me=$(id -u)
  if [ "$frp_owner" != "$frp_me" ]; then
    fork_die "$frp_label $frp_target is owned by uid $frp_owner, not $frp_me (not changing it)"
  fi
  if [ "$frp_mode" != "700" ]; then
    fork_die "$frp_label $frp_target is mode $frp_mode, expected 700 (not changing it)"
  fi
}

# A directory that exists. Symlinks are resolved; the result is not a link.
fork_existing_dir() {
  fed_raw=$1
  fed_label=$2
  [ -n "$fed_raw" ] || fork_die "missing $fed_label"
  if [ ! -e "$fed_raw" ] && [ ! -L "$fed_raw" ]; then
    fork_die "$fed_label not found: $fed_raw"
  fi
  fed_target=$(fork_canonical_path "$fed_raw")
  if [ -L "$fed_target" ] || [ ! -d "$fed_target" ]; then
    fork_die "$fed_label is not a directory: $fed_target"
  fi
  printf '%s\n' "$fed_target"
}

fork_version_id_safe() {
  printf '%s' "$1" | grep -Eq '^[0-9A-Za-z._-]{1,80}$' || return 1
  case "$1" in
    .|..) return 1 ;;
  esac
  return 0
}

fork_version_id_ok() {
  fork_version_id_safe "$1" || fork_die "refusing version id $1"
}

# Remove the stage directory this build owns: exactly <prep>/stage/<version>.
# Never the preparation directory, the live home, or a symlink.
fork_remove_script_stage() {
  frs_stage=$1
  frs_parent=$2
  frs_name=$3
  if [ ! -e "$frs_stage" ] && [ ! -L "$frs_stage" ]; then
    return 0
  fi
  if [ -L "$frs_stage" ]; then
    fork_die "refusing to remove symlink $frs_stage"
  fi
  fork_version_id_ok "$frs_name"
  frs_canon=$(fork_canonical_path "$frs_stage")
  frs_parent_canon=$(fork_canonical_path "$frs_parent")
  frs_home=$(fork_live_home_path)
  if [ "$frs_canon" = "$frs_home" ] || [ "$frs_canon" = "$frs_parent_canon" ]; then
    fork_die "refusing to remove $frs_canon"
  fi
  case "$frs_canon" in
    "$frs_parent_canon"/"$frs_name") ;;
    *) fork_die "refusing to remove $frs_canon" ;;
  esac
  rm -rf -- "$frs_canon"
}

# Remove a directory this run created. $3 is its device:inode at creation.
# A symlink, the live home, a path that is not exactly one child of $2, or a
# different inode is left in place.
fork_remove_created_dir() {
  frc_dir=$1
  frc_parent=$2
  frc_token=$3
  if [ ! -e "$frc_dir" ] && [ ! -L "$frc_dir" ]; then
    return 0
  fi
  if [ -L "$frc_dir" ]; then
    printf 'fork-build: refusing to remove symlink %s\n' "$frc_dir" >&2
    return 1
  fi
  frc_canon=$(realpath -m -- "$frc_dir") || {
    printf 'fork-build: cannot resolve %s\n' "$frc_dir" >&2
    return 1
  }
  frc_parent_canon=$(realpath -m -- "$frc_parent") || {
    printf 'fork-build: cannot resolve %s\n' "$frc_parent" >&2
    return 1
  }
  frc_home=$(realpath -m -- "$(fork_home)") || {
    printf 'fork-build: cannot resolve the live Timon home\n' >&2
    return 1
  }
  if [ "$frc_canon" = "$frc_home" ]; then
    printf 'fork-build: refusing to remove the live Timon home\n' >&2
    return 1
  fi
  case "$frc_canon" in
    "$frc_parent_canon"/*) ;;
    *)
      printf 'fork-build: refusing to remove %s\n' "$frc_canon" >&2
      return 1
      ;;
  esac
  frc_rest=${frc_canon#"$frc_parent_canon"/}
  case "$frc_rest" in
    */*|"")
      printf 'fork-build: refusing to remove %s\n' "$frc_canon" >&2
      return 1
      ;;
  esac
  frc_now=$(stat -c '%d:%i' -- "$frc_canon") || {
    printf 'fork-build: cannot stat %s\n' "$frc_canon" >&2
    return 1
  }
  if [ "$frc_now" != "$frc_token" ]; then
    printf 'fork-build: refusing to remove %s (not the directory this run created)\n' "$frc_canon" >&2
    return 1
  fi
  rm -rf -- "$frc_canon"
}

# Move an incomplete official release aside so the backup can take its name.
# The tree is not deleted: this run did not create it. A symlink, the live
# home, or a path that is not <home>/desktop-runtime/releases/<id> is refused.
# Prints the aside path when a directory was moved. Prints nothing when the
# release directory is already absent.
fork_move_incomplete_release() {
  if ! fork_version_id_safe "$1"; then
    printf 'fork-build: refusing version id %s\n' "$1" >&2
    return 1
  fi
  fmi_home=$(fork_home)
  fmi_home_phys=$(realpath -m -- "$fmi_home") || {
    printf 'fork-build: cannot resolve the live Timon home\n' >&2
    return 1
  }
  fmi_releases="$fmi_home/desktop-runtime/releases"
  fmi_release="$fmi_releases/$1"
  # Refuse a symlink before resolving it. realpath would follow it into a
  # directory this run did not create.
  if [ -L "$fmi_releases" ]; then
    printf 'fork-build: releases directory is a symlink\n' >&2
    return 1
  fi
  if [ -L "$fmi_release" ]; then
    printf 'fork-build: release path is a symlink\n' >&2
    return 1
  fi
  fmi_phys=$(realpath -m -- "$fmi_release") || {
    printf 'fork-build: cannot resolve %s\n' "$fmi_release" >&2
    return 1
  }
  case "$fmi_phys" in
    "$fmi_home_phys"/desktop-runtime/releases/"$1") ;;
    *)
      printf 'fork-build: refusing to touch release path %s\n' "$fmi_phys" >&2
      return 1
      ;;
  esac
  if [ "$fmi_phys" = "$fmi_home_phys" ]; then
    printf 'fork-build: refusing to touch the live Timon home\n' >&2
    return 1
  fi
  if [ ! -e "$fmi_release" ]; then
    return 0
  fi
  if [ ! -d "$fmi_release" ]; then
    printf 'fork-build: release path is not a directory\n' >&2
    return 1
  fi
  fmi_aside="$fmi_releases/$1.incomplete"
  if [ -e "$fmi_aside" ] || [ -L "$fmi_aside" ]; then
    fmi_aside="$fmi_releases/$1.incomplete.$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  if [ -e "$fmi_aside" ] || [ -L "$fmi_aside" ]; then
    printf 'fork-build: aside path already exists: %s\n' "$fmi_aside" >&2
    return 1
  fi
  if ! mv -- "$fmi_release" "$fmi_aside"; then
    printf 'fork-build: could not move incomplete release %s\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$fmi_aside"
}

# Same id the packaged unit uses: sha256 of the absolute home, 24 hex digits.
fork_unit_name() {
  node --input-type=module -e 'import { createHash } from "node:crypto"; import { resolve } from "node:path"; const home = resolve(process.argv[1]); process.stdout.write("timon-desktop-" + createHash("sha256").update(home).digest("hex").slice(0, 24));' "$(fork_home)"
}

fork_unit_file() {
  printf '%s\n' "$HOME/.config/systemd/user/$(fork_unit_name).service"
}

fork_port_from_unit() {
  unit=$1
  port=$(sed -n 's/^Environment="PORT=\([0-9][0-9]*\)".*/\1/p' "$unit" | head -n 1)
  [ -n "$port" ] || fork_die "no PORT in $unit"
  printf '%s\n' "$port"
}

# Exit 0 when no mission is running. The token file is passed by path.
fork_assert_idle() {
  token="$1/daemon-token"
  port=$2
  [ -f "$token" ] || fork_die "no daemon token at $token (not printing it)"
  url="http://127.0.0.1:${port}/api/missions?status=running&limit=1000"
  script="$(fork_script_dir "$3")/missions-running.mjs"
  set +e
  report=$(node "$script" --token-file "$token" --url "$url" 2>&1)
  code=$?
  set -e
  printf '%s\n' "$report"
  [ "$code" -eq 0 ] || fork_die "refusing to switch the service while a mission is running, or while the mission list cannot be read"
}

fork_schema_fingerprint() {
  sqlite3 "$1" "SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY 1;" | sha256sum | awk '{print $1}'
}

fork_sqlite_backup() {
  src=$1
  dest=$2
  if [ ! -f "$src" ]; then
    printf 'absent\n'
    return 0
  fi
  # sqlite3 creates the copy with the process umask. 022 would leave a 0644
  # database that other accounts on the machine can read.
  umask 077
  sqlite3 "$src" ".backup '$dest'"
  chmod 0600 "$dest" || fork_die "cannot restrict backup of $(basename "$src")"
  mode=$(stat -c %a -- "$dest")
  [ "$mode" = "600" ] || fork_die "backup of $(basename "$src") is mode $mode, expected 600"
  check=$(sqlite3 "$dest" "PRAGMA integrity_check;")
  [ "$check" = "ok" ] || fork_die "backup of $(basename "$src") failed integrity_check"
  fork_schema_fingerprint "$dest"
}

# Drop group and other access on a timestamped backup this run created.
# The root itself is not chmodded: it was created mode 0700, and a directory
# the caller named must never be restricted here. A root that is not already
# a private directory (owner, mode 0700), a symlink, or the live home is refused
# before any chmod. New files are already 0600 under umask 077, but cp -a and
# rsync -a keep the source mode, so a copied database or release would stay
# 0644/0755. Directories under the root become 0700. A file that was executable
# stays owner-executable (0700): rollback runs the saved node binary. Every
# other file becomes 0600. Then the modes are read back and a group or other
# bit is a failure.
fork_privatize_tree() {
  root=$1
  [ -d "$root" ] || fork_die "cannot restrict $root"
  [ ! -L "$root" ] || fork_die "refusing to restrict a symlink: $root"
  fpt_root=$(fork_canonical_path "$root")
  fpt_home=$(fork_live_home_path)
  if [ "$fpt_root" = "$fpt_home" ]; then
    fork_die "refusing to restrict the live Timon home"
  fi
  fpt_owner=$(stat -c %u -- "$fpt_root") || fork_die "cannot read ownership of $root"
  fpt_mode=$(stat -c %a -- "$fpt_root") || fork_die "cannot read mode of $root"
  if [ "$fpt_owner" != "$(id -u)" ] || [ "$fpt_mode" != "700" ]; then
    fork_die "refusing to restrict $fpt_root (owned by uid $fpt_owner, mode $fpt_mode); not changing it"
  fi
  find "$fpt_root" -mindepth 1 -type d -exec chmod 0700 {} + || fork_die "cannot restrict directories under $root"
  find "$fpt_root" -type f -perm /111 -exec chmod 0700 {} + || fork_die "cannot restrict executables under $root"
  find "$fpt_root" -type f ! -perm /111 -exec chmod 0600 {} + || fork_die "cannot restrict files under $root"
  bad=$(find "$fpt_root" \( \( -type d ! -perm 0700 \) -o \( -type f -perm /077 \) \) -print | head -n 5)
  [ -z "$bad" ] || fork_die "backup is readable by group or other: $bad"
}

# TIMON_HOME as the unit file records it. The daemon hashes that string.
fork_unit_home() {
  found=$(sed -n 's/^Environment="TIMON_HOME=\([^"]*\)".*/\1/p' "$1" | head -n 1)
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
  else
    fork_home
  fi
}

# Same derivation as instanceId() in orchestrator/src/host/packaged-service.ts:
# sha256(path.resolve(home)) hex, first 24 characters. resolve() does not
# follow symlinks; do not realpath the home here.
fork_instance_id() {
  node --input-type=module -e 'import { createHash } from "node:crypto"; import { resolve } from "node:path"; const home = process.argv[1]; if (!home) process.exit(1); process.stdout.write(createHash("sha256").update(resolve(home)).digest("hex").slice(0, 24));' "$1"
}

# Exit 0 when the body is this home's booted daemon, 2 when it is not ready
# yet, 3 when it is a booted Timon with no instance field, 4 when the instance
# is some other home. stdin is the raw /api/health body.
fork_classify_health() {
  node --input-type=module -e 'let raw = ""; for await (const chunk of process.stdin) raw += chunk; let body; try { body = JSON.parse(raw); } catch { process.exit(2); } if (!body || typeof body !== "object") process.exit(2); const expected = process.argv[1]; if (typeof body.instance === "string" && body.instance !== expected) process.exit(4); if (body.ok !== true || body.service !== "timon" || body.status === "update_pending") process.exit(2); if (typeof body.instance !== "string") process.exit(3); process.exit(0);' "$1"
}

# Exit 0 when a process listening on the port is inside the unit cgroup.
fork_listener_in_unit() {
  port=$1
  unit=$2
  cgroup=$(systemctl --user show -p ControlGroup --value -- "$unit" 2>/dev/null || true)
  [ -n "$cgroup" ] || return 1
  node --input-type=module -e 'import { readdirSync, readFileSync, readlinkSync } from "node:fs"; import { join } from "node:path"; const port = Number(process.argv[1]); const cgroup = process.argv[2]; if (!Number.isInteger(port) || port <= 0 || !cgroup) process.exit(1); const inodes = new Set(); for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) { let text; try { text = readFileSync(file, "utf8"); } catch { continue; } for (const line of text.trim().split("\n").slice(1)) { const parts = line.trim().split(/\s+/); if (parts[3] !== "0A") continue; const localPort = Number.parseInt(parts[1].split(":").pop(), 16); if (localPort === port) inodes.add(parts[9]); } } if (inodes.size === 0) process.exit(1); for (const pid of readdirSync("/proc")) { if (!/^[0-9]+$/.test(pid)) continue; let fds; try { fds = readdirSync(join("/proc", pid, "fd")); } catch { continue; } for (const fd of fds) { let target; try { target = readlinkSync(join("/proc", pid, "fd", fd)); } catch { continue; } const match = /^socket:\[([0-9]+)\]$/.exec(target); if (!match || !inodes.has(match[1])) continue; let group = ""; try { group = readFileSync(join("/proc", pid, "cgroup"), "utf8"); } catch { continue; } if (group.includes(cgroup)) process.exit(0); } } process.exit(1);' "$port" "$cgroup"
}

# fork_health PORT [TRIES] [HOME] [UNIT]
# HOME is the data directory the launched daemon was given (TIMON_HOME). It
# defaults to the installation home. UNIT, when set, is the systemd unit that
# was just started: a health body with no instance field is accepted only when
# the listener belongs to that unit. A different instance fails at once so the
# caller rolls back instead of treating another Timon on this port as success.
fork_health() {
  port=$1
  tries=${2:-60}
  home=${3:-$(fork_home)}
  unit=${4:-}
  expected=$(fork_instance_id "$home")
  i=0
  while [ "$i" -lt "$tries" ]; do
    if body=$(curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/health" 2>/dev/null); then
      code=0
      printf '%s' "$body" | fork_classify_health "$expected" || code=$?
      if [ "$code" -eq 0 ]; then
        printf '%s\n' "$body"
        return 0
      fi
      # Another home already holds the port. Waiting will not make it ours.
      if [ "$code" -eq 4 ]; then
        printf 'fork-build: health on port %s is another Timon instance\n' "$port" >&2
        return 1
      fi
      # A booted Timon that does not name an instance: accept it only when the
      # process listening is the unit this script started.
      if [ "$code" -eq 3 ]; then
        if [ -n "$unit" ] && fork_listener_in_unit "$port" "$unit"; then
          printf '%s\n' "$body"
          return 0
        fi
        printf 'fork-build: health on port %s has no instance and is not unit %s\n' "$port" "$unit" >&2
        return 1
      fi
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

# Put one database back, or remove one the fork created.
#
# saved is the schema fingerprint from backup time, or the word absent when
# that file did not exist. absent is the only fingerprint that skips the
# copy. A file created afterwards is removed, with its -wal and -shm: there
# is no saved schema to compare, and the official daemon would otherwise
# open a database it did not have. Writes in that new file are discarded.
#
# Any other fingerprint puts the saved copy back when the live file is
# missing or its schema differs. The copy is checked first (mode 0600,
# PRAGMA integrity_check, same fingerprint). Leftover -wal and -shm are
# removed after that check and before the copy becomes the live file, so
# SQLite cannot replay them onto the restored database. A matching schema
# leaves the live file and its -wal/-shm in place.
fork_maybe_restore_db() {
  dest=$1
  name=$2
  saved=$3
  case "$name" in
    timon.db|integrations.db) ;;
    *)
      printf 'fork-build: refusing database name %s\n' "$name" >&2
      return 1
      ;;
  esac
  live="$(fork_home)/$name"
  wal="${live}-wal"
  shm="${live}-shm"

  # A directory (or anything else) must not receive the copy: mv into a
  # directory would nest the database instead of replacing the path.
  if [ -e "$live" ] && [ ! -f "$live" ]; then
    printf 'fork-build: %s is not a regular file\n' "$name" >&2
    return 1
  fi

  if [ "$saved" = "absent" ]; then
    if [ -e "$live" ] || [ -L "$live" ] || [ -e "$wal" ] || [ -L "$wal" ] || [ -e "$shm" ] || [ -L "$shm" ]; then
      rm -f -- "$live" "$wal" "$shm" || {
        printf 'fork-build: could not remove %s created after the backup\n' "$name" >&2
        return 1
      }
      printf '%s removed (absent at backup)\n' "$name"
    else
      printf '%s absent\n' "$name"
    fi
    return 0
  fi

  # Opening the live file here lets SQLite checkpoint its own WAL into it.
  # That keeps post-switch writes when the schema matches. It does not
  # replace the file with the backup.
  if [ -f "$live" ]; then
    current=$(fork_schema_fingerprint "$live") || current=
    if [ -n "$current" ] && [ "$current" = "$saved" ]; then
      printf '%s schema unchanged\n' "$name"
      return 0
    fi
  fi

  backup="$dest/db/$name"
  if [ ! -f "$backup" ]; then
    printf 'fork-build: backup of %s is missing\n' "$name" >&2
    return 1
  fi

  # Check the copy before it replaces the live path. A failed check leaves
  # the previous file where it is, including when that file is already gone.
  tmp=$(mktemp "$(fork_home)/.restore-${name}.XXXXXX") || {
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  }
  if ! cp -a -- "$backup" "$tmp"; then
    rm -f -- "$tmp"
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  fi
  if ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    printf 'fork-build: could not restrict restored %s\n' "$name" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$tmp") || mode=
  if [ "$mode" != "600" ]; then
    rm -f -- "$tmp"
    printf 'fork-build: restored %s is mode %s, expected 600\n' "$name" "$mode" >&2
    return 1
  fi
  check=$(sqlite3 "$tmp" "PRAGMA integrity_check;") || check=
  if [ "$check" != "ok" ]; then
    rm -f -- "$tmp"
    printf 'fork-build: restored %s failed integrity_check\n' "$name" >&2
    return 1
  fi
  restored_fp=$(fork_schema_fingerprint "$tmp") || restored_fp=
  if [ "$restored_fp" != "$saved" ]; then
    rm -f -- "$tmp"
    printf 'fork-build: restored %s schema does not match the backup\n' "$name" >&2
    return 1
  fi
  # The journal has to be gone before the new bytes take the live name.
  if ! rm -f -- "$wal" "$shm"; then
    rm -f -- "$tmp"
    printf 'fork-build: could not remove leftover wal or shm for %s\n' "$name" >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$live"; then
    rm -f -- "$tmp"
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  fi
  printf '%s restored\n' "$name"
}

# Read the two fingerprints from the backup manifest and restore each one.
# The second database is left untouched when the first restore fails.
fork_restore_databases() {
  dest=$1
  timon_fp=$(jq -r '.databases["timon.db"].fingerprint' "$dest/manifest.json") || {
    printf 'fork-build: cannot read %s\n' "$dest/manifest.json" >&2
    return 1
  }
  integrations_fp=$(jq -r '.databases["integrations.db"].fingerprint' "$dest/manifest.json") || {
    printf 'fork-build: cannot read %s\n' "$dest/manifest.json" >&2
    return 1
  }
  fork_maybe_restore_db "$dest" timon.db "$timon_fp" || return 1
  fork_maybe_restore_db "$dest" integrations.db "$integrations_fp" || return 1
}

# Stop the service, put the saved unit and pointer back, put the official
# release tree back when its runner is gone, put the databases back, then
# start again and wait for health.
# Returns 1 on failure and does not exit the shell, except the "recheck"
# argument: that path exits before the stop when a mission is running.
# install.sh calls this from `if`, where dash ignores set -e, so each step
# checks its own status. The caller can then start the unit that this
# function has already put back. The failure path does not pass "recheck".
fork_restore_backup() {
  dest=$1
  if [ ! -f "$dest/manifest.json" ]; then
    printf 'fork-build: no manifest in %s\n' "$dest" >&2
    return 1
  fi
  unit=$(jq -r '.unit' "$dest/manifest.json") || {
    printf 'fork-build: cannot read %s\n' "$dest/manifest.json" >&2
    return 1
  }
  port=$(jq -r '.port' "$dest/manifest.json") || {
    printf 'fork-build: cannot read %s\n' "$dest/manifest.json" >&2
    return 1
  }
  active=$(jq -r '.activeRelease' "$dest/manifest.json") || {
    printf 'fork-build: cannot read %s\n' "$dest/manifest.json" >&2
    return 1
  }
  if [ -z "$unit" ] || [ "$unit" = "null" ]; then
    printf 'fork-build: backup manifest has no unit\n' >&2
    return 1
  fi
  if [ -z "$port" ] || [ "$port" = "null" ]; then
    printf 'fork-build: backup manifest has no port\n' >&2
    return 1
  fi
  # "." and ".." pass a loose version pattern and would walk out of releases/.
  if ! fork_version_id_safe "$active"; then
    printf 'fork-build: refusing version id %s\n' "$active" >&2
    return 1
  fi
  unit_file=$(fork_unit_file)
  release_dir="$(fork_home)/desktop-runtime/releases/$active"
  runner="$release_dir/resources/orchestrator/dist/host/packaged-runner.js"

  # rollback.sh passes "recheck". When this home's daemon still answers,
  # the idle check is the last step before stop. update_pending, another
  # instance, or a closed port is the same "not answering" as the first
  # check: the restore continues. install.sh's failure path does not pass
  # this: the unit is already stopped, and a refusal would block the restore.
  if [ "${2:-}" = "recheck" ]; then
    body=$(curl -fsS --max-time 2 "http://127.0.0.1:${port}/api/health" 2>/dev/null) || body=
    live=0
    if [ -n "$body" ]; then
      code=0
      printf '%s' "$body" | fork_classify_health "$(fork_instance_id "$(fork_unit_home "$unit_file")")" || code=$?
      if [ "$code" -eq 0 ]; then
        live=1
      elif [ "$code" -eq 3 ] && fork_listener_in_unit "$port" "$unit"; then
        live=1
      fi
    fi
    if [ "$live" -eq 1 ]; then
      fork_assert_idle "$(fork_home)" "$port" "$0"
    else
      printf 'daemon is not answering; stop continues\n'
    fi
  fi

  systemctl --user stop "$unit" || {
    printf 'fork-build: could not stop %s\n' "$unit" >&2
    return 1
  }
  cp -a -- "$dest/unit.service" "$unit_file" || {
    printf 'fork-build: could not restore the unit file\n' >&2
    return 1
  }
  cp -a -- "$dest/active-release" "$(fork_home)/desktop-runtime/active-release" || {
    printf 'fork-build: could not restore active-release\n' >&2
    return 1
  }
  if [ ! -f "$runner" ]; then
    # cp -a copies into a directory that already exists, which would nest the
    # backup. An incomplete tree is moved aside, not deleted: this run did
    # not create it. A symlink at that path is a refusal.
    if ! fork_move_incomplete_release "$active"; then
      return 1
    fi
    mkdir -p -- "$(fork_home)/desktop-runtime/releases" || {
      printf 'fork-build: could not create the releases directory\n' >&2
      return 1
    }
    cp -a -- "$dest/official-release" "$release_dir" || {
      printf 'fork-build: could not restore official release %s\n' "$active" >&2
      return 1
    }
    src_manifest="$dest/official-release/resources/orchestrator/release-manifest.json"
    dst_manifest="$release_dir/resources/orchestrator/release-manifest.json"
    if [ ! -f "$src_manifest" ] || [ ! -f "$dst_manifest" ]; then
      printf 'fork-build: release-manifest.json missing after restoring %s\n' "$active" >&2
      return 1
    fi
    src_sum=$(sha256sum "$src_manifest" | awk '{print $1}')
    dst_sum=$(sha256sum "$dst_manifest" | awk '{print $1}')
    if [ -z "$src_sum" ] || [ "$src_sum" != "$dst_sum" ]; then
      printf 'fork-build: restored release-manifest.json for %s does not match the backup\n' "$active" >&2
      return 1
    fi
  fi
  systemctl --user daemon-reload || {
    printf 'fork-build: daemon-reload failed\n' >&2
    return 1
  }
  fork_restore_databases "$dest" || return 1
  systemctl --user start "$unit" || {
    printf 'fork-build: could not start %s\n' "$unit" >&2
    return 1
  }
  restored_home=$(fork_unit_home "$unit_file")
  if ! fork_health "$port" 60 "$restored_home" "$unit" >/dev/null; then
    printf 'fork-build: restored service did not answer on port %s; backup left at %s\n' "$port" "$dest" >&2
    return 1
  fi
  printf 'restored %s\n' "$dest"
}
