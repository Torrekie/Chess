#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR=${1:-"$ROOT_DIR/build"}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
DERIVED_DATA=${CHESS_DERIVED_DATA:-"$OUTPUT_DIR/DerivedData"}

command -v ldid >/dev/null || {
    echo 'ldid is required for local ad-hoc signing.' >&2
    exit 1
}

xcodebuild -project "$ROOT_DIR/ChessIOS.xcodeproj" -scheme Chess \
    -configuration Default -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" -jobs "${CHESS_BUILD_JOBS:-4}" \
    -quiet build CODE_SIGNING_ALLOWED=NO

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-ipa.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir "$STAGING_DIR/Payload"
ditto "$DERIVED_DATA/Build/Products/Default-iphoneos/Chess.app" \
    "$STAGING_DIR/Payload/Chess.app"
ldid -S"$ROOT_DIR/Resources/ChessIOS-AdHoc.entitlements" -Icom.apple.Chess \
    "$STAGING_DIR/Payload/Chess.app/Chess"
ditto -c -k --keepParent "$STAGING_DIR/Payload" "$OUTPUT_DIR/Chess.ipa"
printf 'Created %s\n' "$OUTPUT_DIR/Chess.ipa"
