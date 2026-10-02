#!/bin/sh
set -u

if [ "$#" -ne 5 ]; then
  echo "usage: native-dev-watcher.sh <name> <project-dir> <build-script> <display-name> <mode>" >&2
  exit 2
fi

NAME=$1
PROJECT_DIR=$2
BUILD_SCRIPT=$3
DISPLAY_NAME=$4
MODE=$5
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
BUILD="$ROOT/build"

case "$MODE" in
  debug|trace|asan) ;;
  release)
    "$BUILD_SCRIPT" release
    exec "$BUILD/$NAME-release.app/Contents/MacOS/$NAME"
    ;;
  *)
    echo "usage: ./dev.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac

APP="$BUILD/$NAME-$MODE.app"
EXECUTABLE="$APP/Contents/MacOS/$NAME"
DSYM="$BUILD/$NAME-$MODE.dSYM"
LOCK="$BUILD/$NAME-dev-watcher.lock"
WATCHER_PID_FILE="$LOCK/watcher.pid"
APP_PID_FILE="$LOCK/app.pid"
LOG_DIR="$BUILD/logs/$NAME-$MODE"
APP_PID=""
APP_LOG=""
RSS_LIMIT_MB=${HW_NATIVE_RSS_LIMIT_MB:-2048}
RSS_OVER_LIMIT_COUNT=0

assert_configuration() {
  [ -d "$PROJECT_DIR" ] || {
    echo "$DISPLAY_NAME project directory is missing: $PROJECT_DIR" >&2
    exit 1
  }
  [ -x "$BUILD_SCRIPT" ] || {
    echo "$DISPLAY_NAME build script is not executable: $BUILD_SCRIPT" >&2
    exit 1
  }
}

case "$RSS_LIMIT_MB" in
  ''|*[!0-9]*)
    echo "HW_NATIVE_RSS_LIMIT_MB must be a positive integer" >&2
    exit 2
    ;;
  0)
    echo "HW_NATIVE_RSS_LIMIT_MB must be greater than zero" >&2
    exit 2
    ;;
esac

fingerprint() {
  find \
    "$PROJECT_DIR" \
    "$ODIN_LIBS/native" \
    "$ODIN_LIBS/hw_odin_devlog" \
    "$ODIN_LIBS/hw_odin_ui_framework" \
    "$ODIN_LIBS/hw_odin_ui_components" \
    "$ODIN_LIBS/hw_odin_ui_flash" \
    "$ODIN_LIBS/hw_odin_ui_commandPalette" \
    "$ODIN_LIBS/hw_odin_matchSorter" \
    "$ODIN_LIBS/hw_odin_ipc_localCommand" \
    "$ODIN_LIBS/hw_odin_concurrency_taskQueue" \
    -type f \( -name '*.odin' -o -name '*.m' -o -name '*.h' -o -name '*.metal' -o -name '*.plist' \) \
    -print0 2>/dev/null |
    xargs -0 stat -f '%m:%z:%N' 2>/dev/null
  stat -f '%m:%z:%N' \
    "$BUILD_SCRIPT" \
    "$ROOT/scripts/native-dev-watcher.sh" \
    "$ROOT/scripts/package-native-app.sh" \
    2>/dev/null
}

process_ids_for_executable() {
  ps -axo pid=,comm= | awk -v executable="$EXECUTABLE" '$2 == executable {print $1}'
}

stop_pid() {
  target_pid=$1
  if ! kill -0 "$target_pid" 2>/dev/null; then
    return
  fi
  kill "$target_pid" 2>/dev/null || true
  attempts=0
  while kill -0 "$target_pid" 2>/dev/null && [ "$attempts" -lt 40 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if kill -0 "$target_pid" 2>/dev/null; then
    kill -KILL "$target_pid" 2>/dev/null || true
  fi
}

stop_owned_processes() {
  for target_pid in $(process_ids_for_executable); do
    stop_pid "$target_pid"
  done
}

app_is_frontmost() {
  front_asn=$(lsappinfo front 2>/dev/null || true)
  [ -n "$front_asn" ] || return 1
  front_info=$(lsappinfo info -only pid "$front_asn" 2>/dev/null || true)
  front_pid=$(printf '%s\n' "$front_info" | sed -n 's/.*"pid"=\([0-9][0-9]*\).*/\1/p')
  [ -n "$front_pid" ] && [ "$front_pid" = "$APP_PID" ]
}

activate_app_pid() {
  case "$APP_PID" in ''|*[!0-9]*) return 1 ;; esac
  osascript \
    -e 'on run arguments' \
    -e 'set application_pid to item 1 of arguments as integer' \
    -e 'tell application "System Events" to set frontmost of first application process whose unix id is application_pid to true' \
    -e 'end run' \
    "$APP_PID" >/dev/null 2>&1 || true
}

launch_app() {
  mkdir -p "$LOG_DIR"
  timestamp=$(date '+%Y%m%d-%H%M%S')
  APP_LOG="$LOG_DIR/$timestamp.log"

  if [ "$MODE" = "asan" ]; then
    asan_runtime=$("$ROOT/scripts/asan-runtime.sh")
    env \
      DYLD_INSERT_LIBRARIES="$asan_runtime" \
      MTL_DEBUG_LAYER=1 \
      HW_NATIVE_BACKGROUND_LAUNCH=1 \
      "$EXECUTABLE" >>"$APP_LOG" 2>&1 &
  else
    env \
      MTL_DEBUG_LAYER=1 \
      HW_NATIVE_BACKGROUND_LAUNCH=1 \
      "$EXECUTABLE" >>"$APP_LOG" 2>&1 &
  fi
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$APP_PID_FILE"
  RSS_OVER_LIMIT_COUNT=0
  printf '[%s] launched pid %s (%s)\n' "$NAME" "$APP_PID" "$MODE"
}

archive_crash() {
  exit_status=$1
  # The dev log library contract: a wrapper records why the app died, because the
  # app itself could not. One fatal line, same shape as the assertion hook writes.
  python3 - "${HW_DEVLOG_DIR:-$ROOT/.dev-logs/app}" "$exit_status" <<'PY'
import json, pathlib, sys, time
directory = pathlib.Path(sys.argv[1]); directory.mkdir(parents=True, exist_ok=True)
with (directory/'fatal.jsonl').open('a') as output:
    output.write(json.dumps(dict(timestampMs=int(time.time()*1000), kind='wrapper_exit',
        severity='critical', outcome='failed', feature='app', operation='wrapper_exit',
        reason='process exited non-zero', detail='exit_status='+sys.argv[2]))+'\n')
PY
  timestamp=$(date '+%Y%m%d-%H%M%S')
  archive="$BUILD/crashes/$NAME-$MODE/$timestamp"
  mkdir -p "$archive"
  cp "$EXECUTABLE" "$archive/$NAME"
  if [ -d "$DSYM" ]; then
    cp -R "$DSYM" "$archive/"
  fi
  if [ -f "$APP_LOG" ]; then
    cp "$APP_LOG" "$archive/"
  fi
  latest_report=$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -name "$NAME*.ips" -print 2>/dev/null | while IFS= read -r report; do stat -f '%m:%N' "$report"; done | sort -rn | sed -n '1s/^[0-9]*://p')
  if [ -n "$latest_report" ] && [ -f "$latest_report" ]; then
    cp "$latest_report" "$archive/"
  fi
  printf '[%s] process exited with status %s; archived diagnostics at %s\n' "$NAME" "$exit_status" "$archive" >&2
}

capture_memory_diagnostics() {
  timestamp=$(date '+%Y%m%d-%H%M%S')
  diagnostics="$BUILD/diagnostics/$NAME-$MODE/$timestamp"
  mkdir -p "$diagnostics"
  vmmap -summary "$APP_PID" > "$diagnostics/vmmap.txt" 2>&1 || true
  leaks "$APP_PID" > "$diagnostics/leaks.txt" 2>&1 || true
  printf '[%s] captured memory diagnostics at %s\n' "$NAME" "$diagnostics" >&2
}

check_memory_limit() {
  rss_kb=$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ')
  case "$rss_kb" in ''|*[!0-9]*) return ;; esac
  rss_limit_kb=$((RSS_LIMIT_MB * 1024))
  if [ "$rss_kb" -gt "$rss_limit_kb" ]; then
    RSS_OVER_LIMIT_COUNT=$((RSS_OVER_LIMIT_COUNT + 1))
    if [ "$RSS_OVER_LIMIT_COUNT" -eq 2 ]; then
      capture_memory_diagnostics
    fi
  else
    RSS_OVER_LIMIT_COUNT=0
  fi
}

rebuild_and_launch() {
  restore_frontmost=false
  if [ -n "$APP_PID" ] && app_is_frontmost; then
    restore_frontmost=true
  fi

  printf '\n[%s] rebuilding %s...\n' "$NAME" "$MODE"
  if ! "$BUILD_SCRIPT" "$MODE"; then
    printf '[%s] build failed; keeping pid %s running\n' "$NAME" "${APP_PID:-none}" >&2
    return 1
  fi

  if [ -n "$APP_PID" ]; then
    stop_pid "$APP_PID"
    wait "$APP_PID" 2>/dev/null || true
  fi
  stop_owned_processes
  launch_app
  if [ "$restore_frontmost" = true ]; then
    activate_app_pid
  fi
}

cleanup() {
  status=$?
  trap - INT TERM EXIT
  if [ -n "$APP_PID" ]; then
    stop_pid "$APP_PID"
    wait "$APP_PID" 2>/dev/null || true
  fi
  stop_owned_processes
  rm -f "$APP_PID_FILE" "$WATCHER_PID_FILE"
  rmdir "$LOCK" 2>/dev/null || true
  exit "$status"
}

mkdir -p "$BUILD"
assert_configuration
if ! mkdir "$LOCK" 2>/dev/null; then
  existing=$(sed -n '1p' "$WATCHER_PID_FILE" 2>/dev/null || true)
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    printf '[%s] dev watcher already running as pid %s\n' "$NAME" "$existing"
    exit 0
  fi
  rm -f "$APP_PID_FILE" "$WATCHER_PID_FILE"
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK"
fi

printf '%s\n' "$$" > "$WATCHER_PID_FILE"
trap cleanup INT TERM EXIT
stop_owned_processes
rebuild_and_launch || exit 1
LAST_FINGERPRINT=$(fingerprint | shasum | cut -d' ' -f1)

while :; do
  sleep 0.5
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID"
    app_status=$?
    rm -f "$APP_PID_FILE"
    if [ "$app_status" -ne 0 ]; then
      archive_crash "$app_status"
    else
      printf '[%s] process exited normally\n' "$NAME"
    fi
    exit "$app_status"
  fi

  check_memory_limit
  CURRENT_FINGERPRINT=$(fingerprint | shasum | cut -d' ' -f1)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch || true
  fi
done
