#!/bin/sh
set -eu

if [ "$#" -ne 6 ]; then
  echo "usage: package-native-app.sh <name> <display-name> <bundle-id> <mode> <binary> <ls-ui-element>" >&2
  exit 2
fi

NAME=$1
DISPLAY_NAME=$2
BUNDLE_ID=$3
MODE=$4
BINARY=$5
LS_UI_ELEMENT=$6
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$ROOT/build"
APP="$BUILD/$NAME-$MODE.app"
CONTENTS="$APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/$NAME"
PLIST="$CONTENTS/Info.plist"

case "$MODE" in
  debug|trace|asan|release) ;;
  *)
    echo "unsupported native build mode: $MODE" >&2
    exit 2
    ;;
esac

EFFECTIVE_BUNDLE_ID="$BUNDLE_ID.$MODE"
if [ "$MODE" = "release" ]; then
  EFFECTIVE_BUNDLE_ID=$BUNDLE_ID
fi

case "$LS_UI_ELEMENT" in
  true) LS_UI_ELEMENT_VALUE='<true/>' ;;
  false) LS_UI_ELEMENT_VALUE='<false/>' ;;
  *)
    echo "ls-ui-element must be true or false" >&2
    exit 2
    ;;
esac

if [ ! -x "$BINARY" ]; then
  echo "native application binary is missing: $BINARY" >&2
  exit 1
fi

mkdir -p "$CONTENTS/MacOS"
EXECUTABLE_NEW="$EXECUTABLE.new"
PLIST_NEW="$PLIST.new"
trap 'rm -f "$EXECUTABLE_NEW" "$PLIST_NEW"' EXIT INT TERM

cp "$BINARY" "$EXECUTABLE_NEW"
chmod 755 "$EXECUTABLE_NEW"
mv -f "$EXECUTABLE_NEW" "$EXECUTABLE"

cat > "$PLIST_NEW" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$EFFECTIVE_BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	$LS_UI_ELEMENT_VALUE
</dict>
</plist>
PLIST

if [ ! -f "$PLIST" ] || ! cmp -s "$PLIST_NEW" "$PLIST"; then
  mv -f "$PLIST_NEW" "$PLIST"
else
  rm -f "$PLIST_NEW"
fi

# A nested diagnostics helper: the same binary, told apart by its bundle id, so a
# user can double-click it when the app itself will not start. codesign --deep in
# the release tool signs it and notarization covers it.
HELPER="$CONTENTS/Helpers/hw_fileManager Diagnostics.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$EXECUTABLE" "$HELPER/Contents/MacOS/$NAME"
chmod 755 "$HELPER/Contents/MacOS/$NAME"
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$EFFECTIVE_BUNDLE_ID.diagnostics</string>
	<key>CFBundleName</key>
	<string>hw_fileManager Diagnostics</string>
	<key>CFBundleDisplayName</key>
	<string>hw_fileManager Diagnostics</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

if [ "$MODE" = "release" ]; then
  codesign --force --sign - "$APP"
fi

trap - EXIT INT TERM
printf '%s\n' "$APP"
