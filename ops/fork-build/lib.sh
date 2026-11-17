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
  sqlite3 "$src" ".backup '$dest'"
  check=$(sqlite3 "$dest" "PRAGMA integrity_check;")
  [ "$check" = "ok" ] || fork_die "backup of $(basename "$src") failed integrity_check"
  fork_schema_fingerprint "$dest"
}

fork_health() {
  port=$1
  tries=${2:-60}
  i=0
  while [ "$i" -lt "$tries" ]; do
    if body=$(curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/health" 2>/dev/null); then
      # A daemon waiting on data-update approval also answers ok:true. That is
      # not a booted service: the switch must roll back instead of staying there.
      if printf '%s' "$body" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' \
        && printf '%s' "$body" | grep -Eq '"service"[[:space:]]*:[[:space:]]*"timon"' \
        && ! printf '%s' "$body" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"update_pending"'; then
        printf '%s\n' "$body"
        return 0
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
# Returns 1 on failure and does not exit the shell. install.sh calls this from
# `if`, where dash ignores set -e, so each step checks its own status. The
# caller can then start the unit that this function has already put back.
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
  if ! fork_health "$port" 60 >/dev/null; then
    printf 'fork-build: restored service did not answer on port %s; backup left at %s\n' "$port" "$dest" >&2
    return 1
  fi
  printf 'restored %s\n' "$dest"
}
