#!/usr/bin/env python3
"""Run the native reader with colored normal and extremely tall synthetic pages."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="moye-reader-layout-", dir="/private/tmp") as directory:
    work = Path(directory)
    source = work / "Sources"
    shutil.copytree(ROOT / "source/Sources", source)
    launcher = source / "MoyeApp.swift"
    launcher.write_text(launcher.read_text().replace("@main\nenum MoyeReaderLauncher", "enum MoyeReaderLauncher"))
    app = work / "ReaderLayoutSmoke.app"
    binary = app / "Contents/MacOS/ReaderLayoutSmoke"
    binary.parent.mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "com.moye.moyereader.reader-smoke." + work.name,
                      "CFBundleExecutable": "ReaderLayoutSmoke", "CFBundleName": "阅读器布局检查",
                      "CFBundlePackageType": "APPL"}, file)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-D", "MOYE_READER_DIAGNOSTICS",
                    "-module-cache-path", str(work / "cache"), "-target", "arm64-apple-macos26.0",
                    "-framework", "AppKit", "-framework", "WebKit", "-framework", "CryptoKit",
                    *map(str, sorted(source.glob("*.swift"))), str(ROOT / "tests/ReaderLayoutSmoke.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    output = ROOT / "outputs/reader-verification"
    output.mkdir(parents=True, exist_ok=True)
    run = subprocess.run([str(binary)], env={**os.environ, "MOYE_READER_OUTPUT": str(output)},
                         capture_output=True, text=True, timeout=90)
    result = json.loads((output / "result.json").read_text())
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if run.returncode != 0:
        print(run.stderr)
    assert run.returncode == 0 and result["passed"], result
    (output / "failure.png").unlink(missing_ok=True)
