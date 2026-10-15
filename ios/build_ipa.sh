#!/bin/bash
set -euo pipefail

IOS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-"$IOS_ROOT/../outputs"}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$IOS_ROOT/MoyeReaderIOS/Info.plist")"
STAGE="$(mktemp -d "$OUTPUT_DIR/.moye-ios.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LOG="$OUTPUT_DIR/ios-build-$VERSION.log"
if ! xcodebuild -project "$IOS_ROOT/MoyeReaderIOS.xcodeproj" -scheme MoyeReaderIOS \
    -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$STAGE/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$LOG" 2>&1; then
    tail -100 "$LOG"
    exit 1
fi
mkdir -p "$STAGE/Payload"
cp -R "$STAGE/DerivedData/Build/Products/Release-iphoneos/MoyeReaderIOS.app" "$STAGE/Payload/"
# Remove linker debug records that can retain absolute intermediate paths.
xcrun strip -S "$STAGE/Payload/MoyeReaderIOS.app/MoyeReaderIOS"
python3 - "$STAGE" "$OUTPUT_DIR" "$VERSION" <<'PY'
from pathlib import Path
import plistlib
import sys
import zipfile
stage, output, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
app = stage / 'Payload/MoyeReaderIOS.app'
with (app / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert info['CFBundleShortVersionString'] == version
assert info['CFBundleVersion'] == '41'
assert info['UIDeviceFamily'] == [1, 2]
assert info['MinimumOSVersion'] == '17.0'
assert not (app / 'embedded.mobileprovision').exists()
destination = output / f'MoyeReader-iOS-iPadOS-{version}-unsigned.ipa'
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((stage / 'Payload').rglob('*')):
        if path.is_file():
            assert b'/Users/' not in path.read_bytes(), 'Private build path in ' + path.name
            archive.write(path, path.relative_to(stage))
with zipfile.ZipFile(destination) as archive:
    assert archive.testzip() is None
    binary = 'Payload/MoyeReaderIOS.app/' + info['CFBundleExecutable']
    assert archive.getinfo(binary).external_attr >> 16 & 0o111
print(f'IPA 已生成并校验：{destination}')
PY
