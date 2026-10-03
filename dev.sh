#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = rebuild ]; then
  PID=$(sed -n '1p' "$ROOT/build/file_manager-dev-watcher.lock/watcher.pid" 2>/dev/null || true)
  if [ -z "$PID" ] || ! kill -USR1 "$PID" 2>/dev/null; then
    echo "no dev watcher is running; start it with ./dev.sh" >&2
    exit 1
  fi
  exit 0
fi
MODE=debug
case "${1:-}" in debug|trace|asan|release) MODE=$1; shift ;; esac
HW_DEVLOG_DIR=${HW_DEVLOG_DIR:-"$ROOT/.dev-logs/app"}
HW_DEVLOG_PROFILE=${HW_DEVLOG_PROFILE:-dev}
export HW_DEVLOG_DIR HW_DEVLOG_PROFILE
exec "$ROOT/scripts/native-dev-watcher.sh" \
  file_manager \
  "$ROOT" \
  "$ROOT/build.sh" \
  "hw_fileManager" \
  "$MODE" "$@"
