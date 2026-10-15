#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-"$PROJECT_ROOT/outputs"}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
APP_DEST="$OUTPUT_DIR/墨夜阅读器.app"
BUILD_ROOT="$(mktemp -d "$OUTPUT_DIR/.moye-build.XXXXXX")"
APP_STAGE="$BUILD_ROOT/墨夜阅读器.app"
PREVIOUS_APP="$BUILD_ROOT/previous.app"

cleanup() {
    if [[ -e "$PREVIOUS_APP" || -L "$PREVIOUS_APP" ]] && [[ ! -e "$APP_DEST" && ! -L "$APP_DEST" ]]; then
        if ! mv "$PREVIOUS_APP" "$APP_DEST"; then
            printf '原 APP 已保存在：%s\n' "$PREVIOUS_APP" >&2
            return
        fi
    fi
    rm -rf -- "$BUILD_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
xcrun swiftc -swift-version 5 \
    -module-cache-path "$BUILD_ROOT/module-cache" \
    -target arm64-apple-macos26.0 \
    -framework AppKit -framework WebKit -framework CryptoKit -O \
    "$PROJECT_ROOT/source/Sources/"*.swift \
    -o "$APP_STAGE/Contents/MacOS/MoyeShelf"
cp "$PROJECT_ROOT/source/Info.plist" "$APP_STAGE/Contents/Info.plist"
for asset in AppIconAnime.icns MoyeMascot.png ThirdPartyNotices.txt; do
    cp "$PROJECT_ROOT/source/Assets/$asset" "$APP_STAGE/Contents/Resources/$asset"
done
chmod 755 "$APP_STAGE/Contents/MacOS/MoyeShelf"
codesign --force --deep --sign - "$APP_STAGE"
codesign --verify --deep --strict "$APP_STAGE"

if [[ -e "$APP_DEST" || -L "$APP_DEST" ]]; then
    mv "$APP_DEST" "$PREVIOUS_APP"
fi
mv "$APP_STAGE" "$APP_DEST"
printf '构建完成：%s\n' "$APP_DEST"
