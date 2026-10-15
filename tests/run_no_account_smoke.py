#!/usr/bin/env python3
"""Build an isolated test app and exercise the real native reading/download code."""
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import threading
import urllib.parse
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
REQUESTS = []


def png(red, green, blue):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = (b"\0" + bytes([red, green, blue]) * 32) * 48
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 48, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


class FixtureSite(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        cookie = self.headers.get("Cookie", "")
        REQUESTS.append({"path": path, "cookie": cookie})
        status = 200
        content_type = "text/html; charset=utf-8"
        if path.startswith(("/photo/", "/media/")) and "moye-anonymous=fixture" not in cookie:
            status, body = 403, b"Anonymous cookie missing"
        elif path in ("/albums", "/search/photos"):
            album = "100001" if path == "/albums" else "100002"
            body = f'<html><body><div class="list-col"><a href="/album/{album}"><img src="/media/albums/{album}.png" alt="匿名测试作品"></a><div class="video-title">匿名测试作品</div></div></body></html>'.encode()
        elif path.startswith("/album/"):
            if path == "/album/100001":
                body = '<html><body><h1 id="book-name">单话测试作品</h1><a href="/photo/100201">唯一一话</a></body></html>'.encode()
            else:
                body = '<html><body><h1 id="book-name">匿名测试作品</h1><a href="/photo/100101">第一章</a><a href="/photo/100102">第二章</a></body></html>'.encode()
        elif path.startswith("/photo/"):
            chapter = path.rsplit("/", 1)[1]
            body = f'<html><body><script>window.aid={chapter};window.scramble_id=0;</script><div class="scramble-page"><img src="/media/photos/{chapter}/1.png"><img src="/media/photos/{chapter}/2.png"></div></body></html>'.encode()
        elif path.startswith("/media/"):
            content_type, body = "image/png", png(80, 140, 220)
        else:
            status, body = 404, b"Unknown path"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if path in ("/albums", "/search/photos"):
            self.send_header("Set-Cookie", "moye-anonymous=fixture; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(body)


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureSite)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="moye-no-account-", dir="/private/tmp") as directory:
            work = Path(directory)
            source = work / "Sources"
            shutil.copytree(ROOT / "source/Sources", source)
            launcher = source / "MoyeApp.swift"
            launcher.write_text(launcher.read_text().replace("@main\nenum MoyeReaderLauncher", "enum MoyeReaderLauncher"))
            native = source / "NativeComicUI.swift"
            original = 'var rootURL: URL { URL(string: "https://\\(rawValue)")! }'
            assert original in native.read_text()
            native.write_text(native.read_text().replace(original, f'var rootURL: URL {{ URL(string: "http://127.0.0.1:{server.server_port}")! }}'))
            if os.environ.get("MOYE_SMOKE_TRACE"):
                text = native.read_text().replace(
                    'func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {',
                    'func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {\n        print("didFinish", webView.url?.path ?? "", String(reflecting: pending))')
                text = text.replace('private func acceptPhotoPages(_ value: Any?) -> Bool {',
                                    'private func acceptPhotoPages(_ value: Any?) -> Bool {\n        print("photoPages", String(describing: value))')
                native.write_text(text)
            app = work / "NoAccountSmoke.app"
            binary = app / "Contents/MacOS/NoAccountSmoke"
            binary.parent.mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "com.moye.moyereader.smoke." + work.name,
                              "CFBundleExecutable": "NoAccountSmoke", "CFBundleName": "匿名使用回归检查",
                              "CFBundlePackageType": "APPL", "NSAllowsLocalNetworking": True,
                              "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}, handle)
            command = ["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(work / "cache"),
                       "-target", "arm64-apple-macos26.0", "-framework", "AppKit", "-framework", "WebKit",
                       "-framework", "CryptoKit", *map(str, sorted(source.glob("*.swift"))),
                       str(ROOT / "tests/NoAccountSmoke.swift"), "-o", str(binary)]
            subprocess.run(command, check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            downloads = work / "Downloads"
            downloads.mkdir()
            run = subprocess.run([str(binary)], env={**os.environ, "MOYE_SMOKE_OUTPUT": str(downloads)},
                                 capture_output=True, text=True, timeout=90)
            report = json.loads((downloads / "result.json").read_text())
            if run.returncode != 0 or not report["passed"]:
                print(json.dumps({"report": report, "requests": REQUESTS,
                                  "stdout": run.stdout, "stderr": run.stderr}, ensure_ascii=False, indent=2), flush=True)
            assert run.returncode == 0 and report["passed"], report
            with zipfile.ZipFile(downloads / "匿名测试作品.zip") as archive:
                names = sorted(archive.namelist())
                assert names == ["001_0001.png", "001_0002.png", "002_0001.png", "002_0002.png"], names
                assert archive.testzip() is None
                assert all(archive.read(name) == png(80, 140, 220) for name in names)
            assert all("AVS=" not in request["cookie"] for request in REQUESTS)
            assert any(request["path"] == "/search/photos" for request in REQUESTS)
            assert any(request["path"] == "/photo/100201" for request in REQUESTS)
            multi_chapter_requests = [request["path"] for request in REQUESTS
                                      if request["path"] in ("/photo/100101", "/photo/100102")]
            assert multi_chapter_requests and multi_chapter_requests[0] == "/photo/100102", multi_chapter_requests
            assert not any(request["path"].startswith(("/login", "/user")) for request in REQUESTS)
            protected = [request for request in REQUESTS if request["path"].startswith(("/photo/", "/media/"))]
            assert protected and all("moye-anonymous=fixture" in request["cookie"] for request in protected)
            report.update({"zip_pages": len(names), "anonymous_requests": len(REQUESTS),
                           "checks": ["no account UI", "shared nonpersistent cookies", "search",
                                      "single-chapter auto-open", "multi-chapter selection",
                                      "explicit second-chapter reading",
                                      "two-chapter download", "ZIP contents", "no account requests"]})
            output = ROOT / "outputs/no-account-smoke.json"
            output.parent.mkdir(exist_ok=True)
            output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
