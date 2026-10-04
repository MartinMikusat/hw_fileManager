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
    # The release tool compiles the version and feed in; without them the app never updates.
    if [ -n "${HW_UPDATE_VERSION:-}" ]; then
      ODIN_FLAGS="$ODIN_FLAGS -define:HW_UPDATE_VERSION=$HW_UPDATE_VERSION -define:HW_UPDATE_FEED_URL=$HW_UPDATE_FEED_URL -define:HW_UPDATE_TEAM_ID=$HW_UPDATE_TEAM_ID"
    fi
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
  -collection:native_update="$ODIN_LIBS/hw_odin_native_update" \
  -collection:diagnostics="$ODIN_LIBS/hw_odin_diagnostics" \
  -extra-linker-flags:"$ASAN_LINKER_FLAGS -framework AppKit -framework Foundation -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics" \
  $ODIN_FLAGS -out:"$BUILD/file_manager"

if [ "$MODE" != "release" ]; then
  rm -rf "$BUILD/file_manager-$MODE.dSYM"
  dsymutil "$BUILD/file_manager" -o "$BUILD/file_manager-$MODE.dSYM"
fi

"$ROOT/scripts/package-native-app.sh" \
  file_manager "hw_fileManager" com.halwayland.filemanager "$MODE" "$BUILD/file_manager" false

APP="$BUILD/file_manager-$MODE.app"
mkdir -p "$APP/Contents/Resources/licenses"
cp "$ROOT/fonts/OFL.md" "$APP/Contents/Resources/licenses/Iosevka-OFL.md"
cp "$ROOT/assets/app-icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
PLIST="$APP/Contents/Info.plist"
MINOS=$(vtool -show-build "$BUILD/file_manager" | sed -n 's/^ *minos //p' | head -1)
plist_set() { # key type value
  /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST"
}
plist_set CFBundleIconFile string AppIcon
plist_set CFBundleVersion string "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
plist_set LSMinimumSystemVersion string "${MINOS:-14.0}"
plist_set NSHighResolutionCapable bool true
plist_set LSApplicationCategoryType string public.app-category.utilities
# The resource copy invalidates the signature the packaging step applied in release.
if [ "$MODE" = "release" ]; then codesign --force --sign - "$APP"; fi
