#!/bin/sh
# Start a built fork package on a temporary home and a free port.
# Checks /api/health and that PLUGIN_PERMISSIONS lists the approval
# permissions, then stops the process. Never uses the live Timon home.
#
#   ops/fork-build/verify.sh --package /path/to/<version-id>
#
# See ops/fork-build/README.md.
set -eu

SCRIPT=$0
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$SCRIPT")" && pwd)/lib.sh"

PACKAGE=
while [ $# -gt 0 ]; do
  case $1 in
    --package) PACKAGE=$2; shift 2 ;;
    *) fork_die "unknown argument $1" ;;
  esac
done
[ -n "$PACKAGE" ] || fork_die "pass --package DIR"
[ -d "$PACKAGE" ] || fork_die "package not found: $PACKAGE"

ORCH="$PACKAGE/resources/orchestrator"
NODE="$PACKAGE/resources/node/node"
RUNNER="$ORCH/dist/host/packaged-runner.js"
[ -x "$NODE" ] || fork_die "bundled node is missing: $NODE"
[ -f "$RUNNER" ] || fork_die "service runner is missing: $RUNNER"

LIVE=$(fork_home)
case "$PACKAGE" in
  "$LIVE"|"$LIVE"/*) fork_die "refusing to smoke-test a package inside the live home" ;;
esac

PREP=$(cd -- "$(dirname -- "$PACKAGE")" && pwd)
SMOKE=$(mktemp -d "$PREP/smoke.XXXXXX")
case "$SMOKE" in
  "$LIVE"|"$LIVE"/*) rm -rf -- "$SMOKE"; fork_die "temporary home landed inside the live home" ;;
esac

PORT=$(node -e 'const net = require("node:net"); const s = net.createServer(); s.listen(0, "127.0.0.1", () => { process.stdout.write(String(s.address().port)); s.close(); });')
UNIT="timon-fork-verify-$$"
LOG="$PREP/verify-${UNIT}.log"
: > "$LOG"
VERSION_ID=$(basename -- "$PACKAGE")

cleanup() {
  ec=$?
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
  if [ "${KEEP_SMOKE:-}" != 1 ]; then
    rm -rf -- "$SMOKE"
  fi
  exit "$ec"
}
trap cleanup EXIT

systemd-run --user --collect --unit="$UNIT" \
  -p MemoryMax=4G -p MemorySwapMax=0 -p KillMode=control-group \
  --property=WorkingDirectory="$ORCH" \
  --property=StandardOutput=append:"$LOG" \
  --property=StandardError=append:"$LOG" \
  --setenv=TIMON_HOME="$SMOKE" \
  --setenv=TIMON_INSTALL_DIR="$ORCH" \
  --setenv=TIMON_DESKTOP_SERVICE=1 \
  --setenv=TIMON_DESKTOP_EMBEDDED=0 \
  --setenv=TIMON_RESOURCE_GUARD_ENABLED=0 \
  --setenv=TIMON_APP_ENABLED=0 \
  --setenv=NODE_ENV=production \
  --setenv=PORT="$PORT" \
  --setenv=TIMON_DESKTOP_VERSION="$VERSION_ID" \
  -- "$NODE" --max-old-space-size=3072 "$RUNNER"

printf 'smoke-home %s\n' "$SMOKE"
printf 'port %s\n' "$PORT"

if ! HEALTH=$(fork_health "$PORT" 60); then
  KEEP_SMOKE=1
  printf 'health failed; log follows\n' >&2
  tail -n 40 "$LOG" >&2 || true
  exit 1
fi
printf 'health %s\n' "$HEALTH"
systemctl --user stop "$UNIT"

PERM=$(
  cd -- "$ORCH"
  TIMON_HOME="$SMOKE" "$NODE" --input-type=module -e 'import { PLUGIN_PERMISSIONS } from "./dist/plugins/manifest.js"; const need = ["approvals:read", "approvals:resolve"]; const missing = need.filter((name) => !PLUGIN_PERMISSIONS.includes(name)); if (missing.length) { process.stderr.write("missing " + missing.join(" ") + "\n"); process.exit(1); } process.stdout.write(need.join(" ") + "\n");'
)
printf 'permissions %s\n' "$PERM"
printf 'verify ok\n'
