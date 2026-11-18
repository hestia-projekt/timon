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
  realpath -m -- "$1" || fork_die "cannot resolve $1" # portability: VPS-only fork tooling (Linux, systemd user unit)
}

fork_live_home_path() {
  fork_canonical_path "$(fork_home)"
}

# Physical path of $1. It must stay under the preparation root $2 and outside
# the live Timon home. A symlink ancestor that resolves outside $2 is refused.
# Nothing is created. Prints the physical path.
fork_confine() {
  fc_path=$1
  fc_root=$2
  fc_label=$3
  [ -n "$fc_path" ] || fork_die "missing $fc_label"
  [ -n "$fc_root" ] || fork_die "missing preparation root"
  fc_canon=$(fork_canonical_path "$fc_path")
  fc_root_canon=$(fork_canonical_path "$fc_root")
  case "$fc_canon" in
    "$fc_root_canon"/*) ;;
    *) fork_die "$fc_label leaves the preparation root ($fc_canon)" ;;
  esac
  fork_assert_outside_home "$fc_canon" "$fc_label"
  printf '%s\n' "$fc_canon"
}

# A file to open for writing under a directory the caller already confined.
# $2 is that directory: it must exist and must not be a symlink. The leaf is
# not resolved. A symlink there is refused, including a dangling one, and so
# is anything that exists and is not a regular file. Nothing is created.
# Prints the path to open. Mirrors confined() in assemble-release.mjs.
# Shell redirection, openssl -out, sqlite .backup and cp follow a symlink,
# and [ ! -f ] is true for a dangling one, so that test is not a guard.
fork_confine_file() {
  fcf_path=$1
  fcf_parent=$2
  fcf_label=${3:-file}
  [ -n "$fcf_path" ] || fork_die "missing $fcf_label"
  [ -n "$fcf_parent" ] || fork_die "missing confined parent for $fcf_label"
  if [ -L "$fcf_parent" ]; then
    fork_die "$fcf_label parent is a symlink: $fcf_parent"
  fi
  if [ ! -d "$fcf_parent" ]; then
    fork_die "$fcf_label parent is not a directory: $fcf_parent"
  fi
  fcf_parent_canon=$(fork_canonical_path "$fcf_parent")
  fcf_base=$(basename -- "$fcf_path")
  case "$fcf_base" in
    ''|.|..) fork_die "refusing to write $fcf_label" ;;
  esac
  fcf_dir=$(dirname -- "$fcf_path")
  if [ -L "$fcf_dir" ]; then
    fork_die "refusing to follow symlink $fcf_dir"
  fi
  if [ ! -d "$fcf_dir" ]; then
    fork_die "$fcf_label parent is not a directory: $fcf_dir"
  fi
  fcf_dir_canon=$(fork_canonical_path "$fcf_dir")
  case "$fcf_dir_canon" in
    "$fcf_parent_canon"|"$fcf_parent_canon"/*) ;;
    *) fork_die "$fcf_label leaves its confined parent ($fcf_dir_canon)" ;;
  esac
  # Refuse a symlink in any directory between the confined parent and the leaf.
  fcf_walk=$fcf_parent_canon
  fcf_rest=${fcf_dir_canon#"$fcf_parent_canon"}
  fcf_rest=${fcf_rest#/}
  while [ -n "$fcf_rest" ]; do
    fcf_part=${fcf_rest%%/*}
    case "$fcf_part" in
      ''|.|..) fork_die "refusing to write $fcf_label" ;;
    esac
    fcf_walk="$fcf_walk/$fcf_part"
    if [ -L "$fcf_walk" ]; then
      fork_die "refusing to follow symlink $fcf_walk"
    fi
    if [ ! -d "$fcf_walk" ]; then
      fork_die "$fcf_label parent is not a directory: $fcf_walk"
    fi
    case "$fcf_rest" in
      */*) fcf_rest=${fcf_rest#*/} ;;
      *) fcf_rest= ;;
    esac
  done
  fcf_full="$fcf_walk/$fcf_base"
  case "$fcf_full" in
    "$fcf_parent_canon"/*) ;;
    *) fork_die "$fcf_label leaves its confined parent ($fcf_full)" ;;
  esac
  if [ -L "$fcf_full" ]; then
    fork_die "refusing to follow symlink $fcf_full"
  fi
  if [ -e "$fcf_full" ] && [ ! -f "$fcf_full" ]; then
    fork_die "$fcf_label is not a regular file: $fcf_full"
  fi
  printf '%s\n' "$fcf_full"
}

# The Ed25519 pair for this build, in a directory this run confined.
# An existing regular private key is kept. A symlink, or any other
# non-file, is refused: openssl -out would follow it. A new pair is written
# under umask 077 to temporary files in the same directory, checked, then
# renamed into place. rename does not follow a symlink at the destination.
fork_ensure_release_keys() {
  fek_dir=$1
  if [ -L "$fek_dir" ] || [ ! -d "$fek_dir" ]; then
    fork_die "release key directory is not a directory: $fek_dir"
  fi
  fek_priv=$(fork_confine_file "$fek_dir/fork-release.key.pem" "$fek_dir" "release key") || exit 1
  fek_pub=$(fork_confine_file "$fek_dir/fork-release.pub.pem" "$fek_dir" "release public key") || exit 1
  if [ -e "$fek_priv" ]; then
    return 0
  fi
  fek_umask=$(umask)
  umask 077
  fek_priv_tmp=$(mktemp "$fek_dir/fork-release.key.XXXXXX") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    umask "$fek_umask"
    fork_die "could not create the release key"
  }
  fek_pub_tmp=$(mktemp "$fek_dir/fork-release.pub.XXXXXX") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    rm -f -- "$fek_priv_tmp"
    umask "$fek_umask"
    fork_die "could not create the release public key"
  }
  if ! openssl genpkey -algorithm ED25519 -out "$fek_priv_tmp"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "could not create the release key"
  fi
  if ! openssl pkey -in "$fek_priv_tmp" -pubout -out "$fek_pub_tmp"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "could not create the release public key"
  fi
  for fek_tmp in "$fek_priv_tmp" "$fek_pub_tmp"; do
    if [ -L "$fek_tmp" ] || [ ! -f "$fek_tmp" ]; then
      rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
      umask "$fek_umask"
      fork_die "release key temporary is not a regular file"
    fi
    chmod 0600 -- "$fek_tmp" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
      rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
      umask "$fek_umask"
      fork_die "could not restrict the release key"
    }
    fek_mode=$(stat -c %a -- "$fek_tmp") || fek_mode= # portability: VPS-only fork tooling (Linux, systemd user unit)
    if [ "$fek_mode" != "600" ]; then
      rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
      umask "$fek_umask"
      fork_die "release key temporary is mode ${fek_mode:-unknown}, expected 600"
    fi
  done
  # Re-check after openssl. A symlink planted while it ran is not a destination.
  if ! ( fork_confine_file "$fek_dir/fork-release.key.pem" "$fek_dir" "release key" >/dev/null ); then
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    exit 1
  fi
  if ! ( fork_confine_file "$fek_dir/fork-release.pub.pem" "$fek_dir" "release public key" >/dev/null ); then
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    exit 1
  fi
  if [ -L "$fek_priv" ]; then
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "refusing to follow symlink $fek_priv"
  fi
  if [ -e "$fek_priv" ]; then
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "release key path appeared during creation"
  fi
  # mv -n does not replace an existing name and does not follow a symlink.
  if ! mv -T -n -- "$fek_priv_tmp" "$fek_priv"; then
    rm -f -- "$fek_priv_tmp" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "could not install the release key"
  fi
  if [ -L "$fek_pub" ]; then
    rm -f -- "$fek_priv" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "refusing to follow symlink $fek_pub"
  fi
  if [ -e "$fek_pub" ] && [ ! -f "$fek_pub" ]; then
    rm -f -- "$fek_priv" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "release public key is not a regular file: $fek_pub"
  fi
  if [ -e "$fek_pub" ]; then
    if ! mv -T -f -- "$fek_pub_tmp" "$fek_pub"; then
      rm -f -- "$fek_priv" "$fek_pub_tmp"
      umask "$fek_umask"
      fork_die "could not install the release public key"
    fi
  elif ! mv -T -n -- "$fek_pub_tmp" "$fek_pub"; then
    rm -f -- "$fek_priv" "$fek_pub_tmp"
    umask "$fek_umask"
    fork_die "could not install the release public key"
  fi
  for fek_done in "$fek_priv" "$fek_pub"; do
    fek_mode=$(stat -c %a -- "$fek_done") || fek_mode= # portability: VPS-only fork tooling (Linux, systemd user unit)
    if [ -L "$fek_done" ] || [ ! -f "$fek_done" ] || [ "$fek_mode" != "600" ]; then
      rm -f -- "$fek_priv" "$fek_pub"
      umask "$fek_umask"
      fork_die "release key is not a private regular file"
    fi
  done
  umask "$fek_umask"
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
  frp_owner=$(stat -c %u -- "$frp_target") || fork_die "cannot read ownership of $frp_target" # portability: VPS-only fork tooling (Linux, systemd user unit)
  frp_mode=$(stat -c %a -- "$frp_target") || fork_die "cannot read mode of $frp_target" # portability: VPS-only fork tooling (Linux, systemd user unit)
  frp_me=$(id -u) # portability: VPS-only fork tooling (Linux, systemd user unit)
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
# The preparation root is the parent of $2, resolved on its own, so a symlink
# at $2 cannot make the stage and its parent agree after both are resolved.
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
  frs_anchor=$(dirname -- "$frs_parent")
  frs_canon=$(fork_confine "$frs_stage" "$frs_anchor" "stage")
  frs_anchor_canon=$(fork_canonical_path "$frs_anchor")
  case "$frs_canon" in
    "$frs_anchor_canon"/stage/"$frs_name") ;;
    *) fork_die "refusing to remove $frs_canon" ;;
  esac
  if [ -L "$frs_canon" ]; then
    fork_die "refusing to remove symlink $frs_canon"
  fi
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
  frc_canon=$(realpath -m -- "$frc_dir") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: cannot resolve %s\n' "$frc_dir" >&2
    return 1
  }
  frc_parent_canon=$(realpath -m -- "$frc_parent") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: cannot resolve %s\n' "$frc_parent" >&2
    return 1
  }
  frc_home=$(realpath -m -- "$(fork_home)") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  frc_now=$(stat -c '%d:%i' -- "$frc_canon") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  fmi_home_phys=$(realpath -m -- "$fmi_home") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  fmi_phys=$(realpath -m -- "$fmi_release") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  port=$(sed -n 's/^Environment="PORT=\([0-9][0-9]*\)".*/\1/p' "$unit" | head -n 1) # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  sqlite3 "$1" "SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY 1;" | sha256sum | awk '{print $1}' # portability: VPS-only fork tooling (Linux, systemd user unit)
}

fork_sqlite_backup() {
  src=$1
  dest=$2
  if [ ! -f "$src" ]; then
    printf 'absent\n'
    return 0
  fi
  # sqlite3 .backup follows a symlink. Refuse one before it opens the copy.
  dest=$(fork_confine_file "$dest" "$(dirname -- "$dest")" "$(basename -- "$src") backup") || return 1
  # sqlite3 creates the copy with the process umask. 022 would leave a 0644
  # database that other accounts on the machine can read.
  umask 077
  sqlite3 "$src" ".backup '$dest'" # portability: VPS-only fork tooling (Linux, systemd user unit)
  chmod 0600 "$dest" || fork_die "cannot restrict backup of $(basename "$src")" # portability: VPS-only fork tooling (Linux, systemd user unit)
  mode=$(stat -c %a -- "$dest") # portability: VPS-only fork tooling (Linux, systemd user unit)
  [ "$mode" = "600" ] || fork_die "backup of $(basename "$src") is mode $mode, expected 600"
  check=$(sqlite3 "$dest" "PRAGMA integrity_check;") # portability: VPS-only fork tooling (Linux, systemd user unit)
  [ "$check" = "ok" ] || fork_die "backup of $(basename "$src") failed integrity_check"
  fork_schema_fingerprint "$dest"
}

# Drop group and other access on a timestamped backup this run created.
# The root itself is not chmodded: it was created mode 0700, and a directory
# the caller named must never be restricted here. A root that is not already
# a private directory (owner, mode 0700), a symlink, or the live home is refused
# before any chmod. A path that resolves inside the live home is refused too,
# not only a path that is the home itself. New files are already 0600 under umask 077, but cp -a and
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
  fork_assert_outside_home "$fpt_root" "backup"
  fpt_owner=$(stat -c %u -- "$fpt_root") || fork_die "cannot read ownership of $root" # portability: VPS-only fork tooling (Linux, systemd user unit)
  fpt_mode=$(stat -c %a -- "$fpt_root") || fork_die "cannot read mode of $root" # portability: VPS-only fork tooling (Linux, systemd user unit)
  if [ "$fpt_owner" != "$(id -u)" ] || [ "$fpt_mode" != "700" ]; then # portability: VPS-only fork tooling (Linux, systemd user unit)
    fork_die "refusing to restrict $fpt_root (owned by uid $fpt_owner, mode $fpt_mode); not changing it"
  fi
  find "$fpt_root" -mindepth 1 -type d -exec chmod 0700 {} + || fork_die "cannot restrict directories under $root" # portability: VPS-only fork tooling (Linux, systemd user unit)
  find "$fpt_root" -type f -perm /111 -exec chmod 0700 {} + || fork_die "cannot restrict executables under $root" # portability: VPS-only fork tooling (Linux, systemd user unit)
  find "$fpt_root" -type f ! -perm /111 -exec chmod 0600 {} + || fork_die "cannot restrict files under $root" # portability: VPS-only fork tooling (Linux, systemd user unit)
  bad=$(find "$fpt_root" \( \( -type d ! -perm 0700 \) -o \( -type f -perm /077 \) \) -print | head -n 5) # portability: VPS-only fork tooling (Linux, systemd user unit)
  [ -z "$bad" ] || fork_die "backup is readable by group or other: $bad"
}

# TIMON_HOME as the unit file records it. The daemon hashes that string.
fork_unit_home() {
  found=$(sed -n 's/^Environment="TIMON_HOME=\([^"]*\)".*/\1/p' "$1" | head -n 1) # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  cgroup=$(systemctl --user show -p ControlGroup --value -- "$unit" 2>/dev/null || true) # portability: VPS-only fork tooling (Linux, systemd user unit)
  [ -n "$cgroup" ] || return 1
  node --input-type=module -e 'import { readdirSync, readFileSync, readlinkSync } from "node:fs"; import { join } from "node:path"; const port = Number(process.argv[1]); const cgroup = process.argv[2]; if (!Number.isInteger(port) || port <= 0 || !cgroup) process.exit(1); const inodes = new Set(); for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) { let text; try { text = readFileSync(file, "utf8"); } catch { continue; } for (const line of text.trim().split("\n").slice(1)) { const parts = line.trim().split(/\s+/); if (parts[3] !== "0A") continue; const localPort = Number.parseInt(parts[1].split(":").pop(), 16); if (localPort === port) inodes.add(parts[9]); } } if (inodes.size === 0) process.exit(1); for (const pid of readdirSync("/proc")) { if (!/^[0-9]+$/.test(pid)) continue; let fds; try { fds = readdirSync(join("/proc", pid, "fd")); } catch { continue; } for (const fd of fds) { let target; try { target = readlinkSync(join("/proc", pid, "fd", fd)); } catch { continue; } const match = /^socket:\[([0-9]+)\]$/.exec(target); if (!match || !inodes.has(match[1])) continue; let group = ""; try { group = readFileSync(join("/proc", pid, "cgroup"), "utf8"); } catch { continue; } if (group.includes(cgroup)) process.exit(0); } } process.exit(1);' "$port" "$cgroup" # portability: VPS-only fork tooling (Linux, systemd user unit)
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
    if body=$(curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/health" 2>/dev/null); then # portability: VPS-only fork tooling (Linux, systemd user unit)
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

# A missing path is fine. A symlink is fine (it is moved, not followed).
# Anything else is refused: mv would nest a file inside a directory.
fork_sqlite_entry_ok() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    return 0
  fi
  if [ -L "$1" ] || [ -f "$1" ]; then
    return 0
  fi
  printf 'fork-build: %s is not a regular file\n' "$2" >&2
  return 1
}

# <backup>/post-fork, mode 0700, physically inside the backup and outside
# the live home. Prints the directory. This subdirectory is created by the
# restore; the backup root the caller named is not chmodded.
fork_set_aside_dir() {
  fsd_dest=$1
  fsd_dir="$fsd_dest/post-fork"
  if [ -L "$fsd_dest" ] || [ ! -d "$fsd_dest" ]; then
    printf 'fork-build: backup is not a directory: %s\n' "$fsd_dest" >&2
    return 1
  fi
  if [ -L "$fsd_dir" ]; then
    printf 'fork-build: refusing to follow symlink %s\n' "$fsd_dir" >&2
    return 1
  fi
  if [ -e "$fsd_dir" ] && [ ! -d "$fsd_dir" ]; then
    printf 'fork-build: %s is not a directory\n' "$fsd_dir" >&2
    return 1
  fi
  fsd_dest_canon=$(fork_canonical_path "$fsd_dest") || return 1
  if [ ! -d "$fsd_dir" ]; then
    mkdir -m 0700 -- "$fsd_dir" || {
      printf 'fork-build: could not create %s\n' "$fsd_dir" >&2
      return 1
    }
  fi
  chmod 0700 -- "$fsd_dir" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: could not restrict %s\n' "$fsd_dir" >&2
    return 1
  }
  fsd_mode=$(stat -c %a -- "$fsd_dir") || fsd_mode= # portability: VPS-only fork tooling (Linux, systemd user unit)
  if [ "$fsd_mode" != "700" ]; then
    printf 'fork-build: %s is mode %s, expected 700\n' "$fsd_dir" "$fsd_mode" >&2
    return 1
  fi
  fsd_dir_canon=$(fork_canonical_path "$fsd_dir") || return 1
  case "$fsd_dir_canon" in
    "$fsd_dest_canon"/post-fork) ;;
    *)
      printf 'fork-build: refusing to set aside outside %s\n' "$fsd_dest" >&2
      return 1
      ;;
  esac
  fsd_home=$(fork_live_home_path) || return 1
  case "$fsd_dir_canon" in
    "$fsd_home"|"$fsd_home"/*)
      printf 'fork-build: refusing to set aside inside the live Timon home\n' >&2
      return 1
      ;;
  esac
  printf '%s\n' "$fsd_dir"
}

# Move one sqlite file into the set-aside directory. A symlink is moved as
# a symlink and not chmodded, so its target is unchanged. A regular file
# becomes mode 0600. An existing destination is left untouched.
fork_set_aside_one() {
  fso_dir=$1
  fso_src=$2
  fso_leaf=$3
  case "$fso_leaf" in
    timon.db|integrations.db|timon.db-wal|integrations.db-wal|timon.db-shm|integrations.db-shm) ;;
    *)
      printf 'fork-build: refusing to set aside %s\n' "$fso_leaf" >&2
      return 1
      ;;
  esac
  fso_to="$fso_dir/$fso_leaf"
  if [ -e "$fso_to" ] || [ -L "$fso_to" ]; then
    printf 'fork-build: %s already has a set-aside copy\n' "$fso_leaf" >&2
    return 1
  fi
  if [ -L "$fso_src" ]; then
    mv -- "$fso_src" "$fso_to" || {
      printf 'fork-build: could not set aside %s\n' "$fso_leaf" >&2
      return 1
    }
    return 0
  fi
  if [ ! -f "$fso_src" ]; then
    printf 'fork-build: %s is not a regular file\n' "$fso_leaf" >&2
    return 1
  fi
  mv -- "$fso_src" "$fso_to" || {
    printf 'fork-build: could not set aside %s\n' "$fso_leaf" >&2
    return 1
  }
  if ! chmod 0600 -- "$fso_to"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
    mv -- "$fso_to" "$fso_src" || printf 'fork-build: could not put %s back\n' "$fso_leaf" >&2
    printf 'fork-build: could not restrict set-aside %s\n' "$fso_leaf" >&2
    return 1
  fi
  fso_mode=$(stat -c %a -- "$fso_to") || fso_mode= # portability: VPS-only fork tooling (Linux, systemd user unit)
  if [ "$fso_mode" != "600" ]; then
    mv -- "$fso_to" "$fso_src" || printf 'fork-build: could not put %s back\n' "$fso_leaf" >&2
    printf 'fork-build: set-aside %s is mode %s, expected 600\n' "$fso_leaf" "$fso_mode" >&2
    return 1
  fi
}

# Put back files this run already moved. A missing piece is skipped.
fork_set_aside_undo() {
  fsu_dir=$1
  fsu_name=$2
  fsu_live=$3
  if [ "$4" -eq 1 ] && { [ -e "$fsu_dir/$fsu_name" ] || [ -L "$fsu_dir/$fsu_name" ]; }; then
    mv -- "$fsu_dir/$fsu_name" "$fsu_live" || printf 'fork-build: could not put %s back\n' "$fsu_name" >&2
  fi
  if [ "$5" -eq 1 ] && { [ -e "$fsu_dir/${fsu_name}-wal" ] || [ -L "$fsu_dir/${fsu_name}-wal" ]; }; then
    mv -- "$fsu_dir/${fsu_name}-wal" "${fsu_live}-wal" || printf 'fork-build: could not put %s-wal back\n' "$fsu_name" >&2
  fi
  if [ "$6" -eq 1 ] && { [ -e "$fsu_dir/${fsu_name}-shm" ] || [ -L "$fsu_dir/${fsu_name}-shm" ]; }; then
    mv -- "$fsu_dir/${fsu_name}-shm" "${fsu_live}-shm" || printf 'fork-build: could not put %s-shm back\n' "$fsu_name" >&2
  fi
}

# Move the live database and its journal into <backup>/post-fork/.
# On a partial failure, pieces already moved are put back.
# Sets fsf_dir, fsf_did_live, fsf_did_wal, fsf_did_shm for the caller.
fork_set_aside_family() {
  fsf_dest=$1
  fsf_name=$2
  fsf_live=$3
  fsf_did_live=0
  fsf_did_wal=0
  fsf_did_shm=0
  fsf_dir=$(fork_set_aside_dir "$fsf_dest") || return 1
  if [ -e "$fsf_live" ] || [ -L "$fsf_live" ]; then
    fork_set_aside_one "$fsf_dir" "$fsf_live" "$fsf_name" || return 1
    fsf_did_live=1
  fi
  if [ -e "${fsf_live}-wal" ] || [ -L "${fsf_live}-wal" ]; then
    if ! fork_set_aside_one "$fsf_dir" "${fsf_live}-wal" "${fsf_name}-wal"; then
      fork_set_aside_undo "$fsf_dir" "$fsf_name" "$fsf_live" "$fsf_did_live" 0 0
      return 1
    fi
    fsf_did_wal=1
  fi
  if [ -e "${fsf_live}-shm" ] || [ -L "${fsf_live}-shm" ]; then
    if ! fork_set_aside_one "$fsf_dir" "${fsf_live}-shm" "${fsf_name}-shm"; then
      fork_set_aside_undo "$fsf_dir" "$fsf_name" "$fsf_live" "$fsf_did_live" "$fsf_did_wal" 0
      return 1
    fi
    fsf_did_shm=1
  fi
}

# Put one database back to the copy saved before the switch.
#
# saved is the schema fingerprint from backup time, or the word absent when
# that file did not exist. A fingerprint is not a reason to keep the live
# file: a data migration can leave sqlite_master unchanged and still write
# rows the older daemon cannot dispatch. When the file existed at backup
# time, the saved copy is always installed.
#
# The live file and its -wal and -shm are moved to <backup>/post-fork/
# (mode 0600) and are not deleted. Writes made while the fork was running
# stay there for a manual recovery. They are not merged back.
#
# absent means the file did not exist at backup time. A file the fork
# created is moved aside the same way, not deleted, and no copy is installed.
#
# The saved copy is checked before anything is moved (mode 0600,
# PRAGMA integrity_check, same fingerprint). A failed check leaves the live
# file where it is. The journal is moved only after that check, so SQLite
# cannot replay it onto the restored database.
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

  fork_sqlite_entry_ok "$live" "$name" || return 1
  fork_sqlite_entry_ok "$wal" "${name}-wal" || return 1
  fork_sqlite_entry_ok "$shm" "${name}-shm" || return 1

  fmr_present=0
  if [ -e "$live" ] || [ -L "$live" ] || [ -e "$wal" ] || [ -L "$wal" ] || [ -e "$shm" ] || [ -L "$shm" ]; then
    fmr_present=1
  fi

  if [ "$saved" = "absent" ]; then
    if [ "$fmr_present" -eq 0 ]; then
      printf '%s absent\n' "$name"
      return 0
    fi
    fork_set_aside_family "$dest" "$name" "$live" || return 1
    printf '%s set aside (absent at backup)\n' "$name"
    return 0
  fi

  backup="$dest/db/$name"
  if [ -L "$backup" ]; then
    printf 'fork-build: refusing to follow symlink %s\n' "$backup" >&2
    return 1
  fi
  if [ ! -f "$backup" ]; then
    printf 'fork-build: backup of %s is missing\n' "$name" >&2
    return 1
  fi

  # Check the copy before it replaces the live path. A failed check leaves
  # the previous file where it is, including when that file is already gone.
  fmr_home=$(fork_canonical_path "$(fork_home)") || {
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  }
  # The template is the physical home, so mktemp does not open a symlink path.
  tmp_new=$(mktemp "$fmr_home/.restore-${name}.XXXXXX") || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  }
  if ! tmp=$(fork_confine_file "$tmp_new" "$fmr_home" "restored $name"); then
    rm -f -- "$tmp_new"
    return 1
  fi
  if ! cp -a -- "$backup" "$tmp"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
    rm -f -- "$tmp"
    printf 'fork-build: could not restore %s\n' "$name" >&2
    return 1
  fi
  if ! chmod 0600 "$tmp"; then # portability: VPS-only fork tooling (Linux, systemd user unit)
    rm -f -- "$tmp"
    printf 'fork-build: could not restrict restored %s\n' "$name" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$tmp") || mode= # portability: VPS-only fork tooling (Linux, systemd user unit)
  if [ "$mode" != "600" ]; then
    rm -f -- "$tmp"
    printf 'fork-build: restored %s is mode %s, expected 600\n' "$name" "$mode" >&2
    return 1
  fi
  check=$(sqlite3 "$tmp" "PRAGMA integrity_check;") || check= # portability: VPS-only fork tooling (Linux, systemd user unit)
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
  # The journal has to leave the live directory before the new bytes take
  # the live name, or SQLite replays it onto the restored database.
  # The live file moves with it: those bytes are the fork's writes.
  if [ "$fmr_present" -eq 1 ]; then
    if ! fork_set_aside_family "$dest" "$name" "$live"; then
      rm -f -- "$tmp"
      return 1
    fi
    printf '%s set aside\n' "$name"
  fi
  if ! mv -f -- "$tmp" "$live"; then
    rm -f -- "$tmp"
    if [ "$fmr_present" -eq 1 ]; then
      fork_set_aside_undo "$fsf_dir" "$name" "$live" "$fsf_did_live" "$fsf_did_wal" "$fsf_did_shm"
    fi
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
#
# rollback.sh reads the fork_restore_* flags from its EXIT trap. They stay
# 0 until the matching step has finished. fork_restore_stopped is 1 only
# after this function has stopped the unit. fork_restore_healthy is 1 only
# after the restarted unit has answered. fork_restore_release is 1 when the
# official tree was copied back, 2 when its runner was already there.
# fork_restore_dbs is 1 after both database files have been handled.
fork_restore_backup() {
  dest=$1
  fork_restore_stopped=0
  fork_restore_healthy=0
  fork_restore_unit_file=0
  fork_restore_pointer=0
  fork_restore_release=0
  fork_restore_dbs=0
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
    body=$(curl -fsS --max-time 2 "http://127.0.0.1:${port}/api/health" 2>/dev/null) || body= # portability: VPS-only fork tooling (Linux, systemd user unit)
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

  systemctl --user stop "$unit" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: could not stop %s\n' "$unit" >&2
    return 1
  }
  # rollback.sh reads this after the function returns.
  # shellcheck disable=SC2034
  fork_restore_stopped=1
  unit_file=$(fork_confine_file "$unit_file" "$(dirname -- "$unit_file")" "unit file") || return 1
  cp -a -- "$dest/unit.service" "$unit_file" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: could not restore the unit file\n' >&2
    return 1
  }
  # shellcheck disable=SC2034
  fork_restore_unit_file=1
  frb_active="$(fork_home)/desktop-runtime/active-release"
  frb_active=$(fork_confine_file "$frb_active" "$(fork_home)/desktop-runtime" "active release") || return 1
  cp -a -- "$dest/active-release" "$frb_active" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: could not restore active-release\n' >&2
    return 1
  }
  # shellcheck disable=SC2034
  fork_restore_pointer=1
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
    release_dir=$(fork_confine_file "$release_dir" "$(dirname -- "$release_dir")" "official release") || return 1
    cp -a -- "$dest/official-release" "$release_dir" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
      printf 'fork-build: could not restore official release %s\n' "$active" >&2
      return 1
    }
    src_manifest="$dest/official-release/resources/orchestrator/release-manifest.json"
    dst_manifest="$release_dir/resources/orchestrator/release-manifest.json"
    if [ ! -f "$src_manifest" ] || [ ! -f "$dst_manifest" ]; then
      printf 'fork-build: release-manifest.json missing after restoring %s\n' "$active" >&2
      return 1
    fi
    src_sum=$(sha256sum "$src_manifest" | awk '{print $1}') # portability: VPS-only fork tooling (Linux, systemd user unit)
    dst_sum=$(sha256sum "$dst_manifest" | awk '{print $1}') # portability: VPS-only fork tooling (Linux, systemd user unit)
    if [ -z "$src_sum" ] || [ "$src_sum" != "$dst_sum" ]; then
      printf 'fork-build: restored release-manifest.json for %s does not match the backup\n' "$active" >&2
      return 1
    fi
    # shellcheck disable=SC2034
    fork_restore_release=1
  else
    # shellcheck disable=SC2034
    fork_restore_release=2
  fi
  systemctl --user daemon-reload || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: daemon-reload failed\n' >&2
    return 1
  }
  fork_restore_databases "$dest" || return 1
  # shellcheck disable=SC2034
  fork_restore_dbs=1
  systemctl --user start "$unit" || { # portability: VPS-only fork tooling (Linux, systemd user unit)
    printf 'fork-build: could not start %s\n' "$unit" >&2
    return 1
  }
  restored_home=$(fork_unit_home "$unit_file")
  if ! fork_health "$port" 60 "$restored_home" "$unit" >/dev/null; then
    printf 'fork-build: restored service did not answer on port %s; backup left at %s\n' "$port" "$dest" >&2
    return 1
  fi
  # shellcheck disable=SC2034
  fork_restore_healthy=1
  printf 'restored %s\n' "$dest"
}
