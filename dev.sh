#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=debug
case "${1:-}" in debug|trace|asan|release) MODE=$1; shift ;; esac
DELTA_DEVLOG_DIR=${DELTA_DEVLOG_DIR:-"$ROOT/.dev-logs/app"}
DELTA_DEVLOG_PROFILE=${DELTA_DEVLOG_PROFILE:-dev}
export DELTA_DEVLOG_DIR DELTA_DEVLOG_PROFILE
exec "$ROOT/scripts/native-dev-watcher.sh" \
  file_manager \
  "$ROOT" \
  "$ROOT/build.sh" \
  "hw_fileManager" \
  "$MODE" "$@"
