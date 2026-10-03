#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"
python3 "$ROOT/scripts/check_dependencies.py" "${1:-debug}"
# The app embeds this precompiled shader library (shaders.odin).
sh "$ODIN_LIBS/hw_odin_ui_framework/scripts/build-metallib.sh" "$BUILD/ui.metallib"
cd "$BUILD"

MODE=${1:-debug}
ASAN_LINKER_FLAGS=""
case "$MODE" in
  debug)
    ODIN_FLAGS="-debug -o:none -keep-temp-files"
    ;;
  trace)
    ODIN_FLAGS="-debug -o:speed -keep-temp-files"
    ;;
  asan)
    ODIN_FLAGS="-debug -o:none -sanitize:address -keep-temp-files"
    ASAN_RUNTIME=$("$ROOT/scripts/asan-runtime.sh")
    ASAN_RUNTIME_DIR=${ASAN_RUNTIME%/*}
    ASAN_LINKER_FLAGS="-fno-sanitize-link-runtime -L$ASAN_RUNTIME_DIR -lclang_rt.asan_osx_dynamic -rpath $ASAN_RUNTIME_DIR"
    ;;
  release)
    ODIN_FLAGS="-o:speed"
    ;;
  *)
    echo "usage: ./build.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac

# shellcheck disable=SC2086
hw-odin build "$ROOT" -vet \
  -collection:devlog="$ODIN_LIBS/hw_odin_devlog" \
  -collection:ui_framework="$ODIN_LIBS/hw_odin_ui_framework" \
  -collection:components="$ODIN_LIBS/hw_odin_ui_components" \
  -extra-linker-flags:"$ASAN_LINKER_FLAGS -framework AppKit -framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics" \
  $ODIN_FLAGS -out:"$BUILD/file_manager"

if [ "$MODE" != "release" ]; then
  rm -rf "$BUILD/file_manager-$MODE.dSYM"
  dsymutil "$BUILD/file_manager" -o "$BUILD/file_manager-$MODE.dSYM"
fi

"$ROOT/scripts/package-native-app.sh" \
  file_manager "hw_fileManager" com.halwayland.filemanager "$MODE" "$BUILD/file_manager" false
