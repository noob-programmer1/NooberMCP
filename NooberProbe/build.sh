#!/bin/bash
# Build NooberProbe dylib for iOS Simulator (arm64 + x86_64)
# Single-step: swiftc compiles ALL Swift + links pre-compiled C .o files
# Then ad-hoc codesign for iOS 26+ compatibility
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/Sources"
BUILD_DIR="$SCRIPT_DIR/.build"
OUTPUT_DIR="$SCRIPT_DIR/../Bundled"
DYLIB_NAME="NooberProbe.dylib"

SWIFT_FILES=$(find "$SRC_DIR" -name "*.swift" | sort)
C_FILES=$(find "$SRC_DIR" -name "*.c" | sort)
M_FILES=$(find "$SRC_DIR" -name "*.m" | sort)

SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
SWIFTC=$(xcrun --find swiftc)

# Build only for the host architecture (universal fat binaries are rejected by iOS 26+ dyld)
HOST_ARCH=$(uname -m)
echo "[NooberProbe] Building for iOS Simulator ($HOST_ARCH)..."
mkdir -p "$BUILD_DIR/$HOST_ARCH" "$OUTPUT_DIR"

for ARCH in $HOST_ARCH; do
    TARGET="${ARCH}-apple-ios17.0-simulator"
    ARCH_DIR="$BUILD_DIR/$ARCH"
    mkdir -p "$ARCH_DIR"

    # Compile C with clang
    echo "[NooberProbe] [$ARCH] Compiling C..."
    C_OBJS=""
    for C_FILE in $C_FILES; do
        OBJ_NAME=$(basename "$C_FILE" .c).o
        xcrun clang -c "$C_FILE" -target "$TARGET" -isysroot "$SDK_PATH" -o "$ARCH_DIR/$OBJ_NAME"
        C_OBJS="$C_OBJS $ARCH_DIR/$OBJ_NAME"
    done

    # Compile Objective-C with clang (-fobjc-arc for ARC, link Foundation)
    echo "[NooberProbe] [$ARCH] Compiling Objective-C..."
    for M_FILE in $M_FILES; do
        OBJ_NAME=$(basename "$M_FILE" .m).o
        xcrun clang -c "$M_FILE" -fobjc-arc -target "$TARGET" -isysroot "$SDK_PATH" -o "$ARCH_DIR/$OBJ_NAME"
        C_OBJS="$C_OBJS $ARCH_DIR/$OBJ_NAME"
    done

    # Single-step: swiftc compiles Swift + links C .o into one dylib
    echo "[NooberProbe] [$ARCH] Compiling + Linking..."
    $SWIFTC \
        -Osize -whole-module-optimization \
        -target "$TARGET" \
        -sdk "$SDK_PATH" \
        -emit-library \
        -module-name NooberProbe \
        $SWIFT_FILES \
        $C_OBJS \
        -Xlinker -install_name -Xlinker @rpath/NooberProbe.dylib \
        -o "$ARCH_DIR/$DYLIB_NAME" \
        2>&1
done

# Copy to output + /tmp (iOS 26 sim restricts DYLD_INSERT paths to non-user directories)
cp "$BUILD_DIR/$HOST_ARCH/$DYLIB_NAME" "$OUTPUT_DIR/$DYLIB_NAME"
RUNTIME_PATH="/tmp/$DYLIB_NAME"
cp "$BUILD_DIR/$HOST_ARCH/$DYLIB_NAME" "$RUNTIME_PATH"

# iOS 26+ requires ad-hoc signing
echo "[NooberProbe] Code signing..."
codesign --force --sign - "$OUTPUT_DIR/$DYLIB_NAME"
codesign --force --sign - "$RUNTIME_PATH"

echo "[NooberProbe] Verifying..."
file "$OUTPUT_DIR/$DYLIB_NAME"
echo "[NooberProbe] Runtime injection path: $RUNTIME_PATH"
echo "[NooberProbe] Built: $OUTPUT_DIR/$DYLIB_NAME ($(du -h "$OUTPUT_DIR/$DYLIB_NAME" | cut -f1))"
