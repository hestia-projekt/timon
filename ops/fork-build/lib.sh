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

# Refuse a path that lives in the live Timon home.
fork_assert_outside_home() {
  home=$(cd -- "$(fork_home)" && pwd -P)
  target=$(cd -- "$1" && pwd -P) || fork_die "cannot read $1"
  case "$target" in
    "$home"|"$home"/*) fork_die "$2 is inside the live Timon home ($home)" ;;
  esac
}

fork_version_id_ok() {
  printf '%s' "$1" | grep -Eq '^[0-9A-Za-z._-]{1,80}$' || fork_die "refusing version id $1"
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

# Drop group and other access on a backup tree. New files are already 0600
# under umask 077, but cp -a and rsync -a keep the source mode, so a copied
# database or a copied release would stay 0644/0755. Directories become 0700.
# A file that was executable stays owner-executable (0700): rollback runs the
# saved node binary. Every other file becomes 0600. Then the modes are read
# back and a group or other bit is a failure.
fork_privatize_tree() {
  root=$1
  [ -d "$root" ] || fork_die "cannot restrict $root"
  chmod 0700 "$root" || fork_die "cannot restrict $root"
  find "$root" -type d -exec chmod 0700 {} + || fork_die "cannot restrict directories under $root"
  find "$root" -type f -perm /111 -exec chmod 0700 {} + || fork_die "cannot restrict executables under $root"
  find "$root" -type f ! -perm /111 -exec chmod 0600 {} + || fork_die "cannot restrict files under $root"
  bad=$(find "$root" \( \( -type d ! -perm 0700 \) -o \( -type f -perm /077 \) \) -print | head -n 5)
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

# Same bytes as the fingerprint stored at backup time (sqlite3, then sha256).
fork_maybe_restore_db() {
  dest=$1
  name=$2
  saved=$3
  [ "$saved" = "absent" ] && return 0
  live="$(fork_home)/$name"
  [ -f "$live" ] || return 0
  current=$(fork_schema_fingerprint "$live")
  if [ "$current" = "$saved" ]; then
    printf '%s schema unchanged\n' "$name"
    return 0
  fi
  rm -f -- "${live}-wal" "${live}-shm"
  cp -a -- "$dest/db/$name" "$live" || {
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  }
  check=$(sqlite3 "$live" "PRAGMA integrity_check;") || {
    printf 'fork-build: restored %s failed integrity_check\n' "$name" >&2
    return 1
  }
  if [ "$check" != "ok" ]; then
    printf 'fork-build: restored %s failed integrity_check\n' "$name" >&2
    return 1
  fi
  printf '%s restored\n' "$name"
}

# Stop the service, put the saved unit and pointer back, put the official
# release tree back when its runner is gone, restore a database whose schema
# changed, then start again and wait for health.
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
  # "." and ".." pass the version pattern and would walk out of releases/ on rm.
  if ! printf '%s' "$active" | grep -Eq '^[0-9A-Za-z._-]{1,80}$' \
    || [ "$active" = "." ] || [ "$active" = ".." ]; then
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
    # backup. Drop a partial tree so the copy becomes the release directory.
    if [ -e "$release_dir" ]; then
      rm -rf -- "$release_dir" || {
        printf 'fork-build: could not remove incomplete release %s\n' "$active" >&2
        return 1
      }
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
