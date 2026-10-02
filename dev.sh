#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
