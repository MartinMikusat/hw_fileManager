#!/bin/sh
set -eu

LLVM_PREFIX=$(brew --prefix llvm 2>/dev/null) || {
  echo "Homebrew LLVM is required for AddressSanitizer builds" >&2
  exit 1
}
RUNTIME_DIR=$("$LLVM_PREFIX/bin/clang" --print-resource-dir)/lib/darwin
RUNTIME="$RUNTIME_DIR/libclang_rt.asan_osx_dynamic.dylib"
if [ ! -f "$RUNTIME" ] ||
   ! nm -gU "$RUNTIME" | grep -q '___asan_version_mismatch_check_v8'; then
  echo "A compatible AddressSanitizer runtime was not found: $RUNTIME" >&2
  exit 1
fi
printf '%s\n' "$RUNTIME"
