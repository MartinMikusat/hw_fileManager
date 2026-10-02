#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$ROOT/scripts/native-dev-watcher.sh" \
  file_manager \
  "$ROOT" \
  "$ROOT/build.sh" \
  "hw_fileManager" \
  "${1:-debug}"
