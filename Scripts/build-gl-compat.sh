#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR=${1:?Usage: build-gl-compat.sh output-directory sdk architectures}
SDK_NAME=${2:-iphoneos}
ARCHITECTURES=${3:-arm64}
ARCHITECTURES=${ARCHITECTURES// /;}

command -v cmake >/dev/null || {
    echo 'CMake is required to build the OpenGL compatibility library.' >&2
    exit 1
}
SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
CC_PATH=$(xcrun --sdk "$SDK_NAME" --find clang)

cmake -S "$ROOT_DIR/ThirdParty" -B "$OUTPUT_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURES" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}" \
    -DCMAKE_C_COMPILER="$CC_PATH" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
cmake --build "$OUTPUT_DIR" --parallel "${CHESS_GL_BUILD_JOBS:-2}" \
    --target GL ChessGLU
