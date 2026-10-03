#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
python3 "$ODIN_LIBS/hw_odin_devlog/scripts/lint_devlog.py" "$ROOT"
BUILD="$ROOT/build"
mkdir -p "$BUILD"
python3 "$ROOT/scripts/check_dependencies.py" debug
# The app embeds this precompiled shader library (shaders.odin).
sh "$ODIN_LIBS/hw_odin_ui_framework/scripts/build-metallib.sh" "$BUILD/ui.metallib"
cd "$BUILD"
python3 "$ROOT/scripts/test_host_control_lint.py" "$ROOT"
hw-odin test "$ROOT" -vet \
  -collection:devlog="$ODIN_LIBS/hw_odin_devlog" \
  -collection:ui_framework="$ODIN_LIBS/hw_odin_ui_framework" \
  -collection:components="$ODIN_LIBS/hw_odin_ui_components" \
  -collection:native_update="$ODIN_LIBS/hw_odin_native_update" \
  -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics"
echo "[hw_fileManager] tests passed"

# Headless dev log integration: build the app and the journal reader, then run both.
"$ROOT/build.sh" debug >/dev/null
"$ODIN_LIBS/hw_odin_devlog/build.sh" -debug >/dev/null
python3 "$ROOT/tests/devlog.py" "$ROOT/build/file_manager" "$ODIN_LIBS/hw_odin_devlog/build/hw-devlog"
