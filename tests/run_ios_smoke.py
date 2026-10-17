#!/usr/bin/env python3
"""Exercise real iOS services and views in an isolated iPad simulator."""
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
import time
import urllib.parse
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
XCODE = Path('/Applications/Xcode.app/Contents/Developer')
ENV = {**os.environ, 'DEVELOPER_DIR': str(XCODE)}
REQUESTS = []
LONG_LIST = False


def png(width=32, height=48, colors=((80, 140, 220),), circle=False):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    if circle:
        pixels = b''.join(b'\0' + b''.join(bytes((255, 255, 255) if (x - width / 2) ** 2 + (y - height / 2) ** 2 <= 24 ** 2 else colors[0]) for x in range(width)) for y in range(height))
    else:
        pixels = b''.join(b'\0' + bytes(colors[min(len(colors) - 1, y * len(colors) // height)]) * width for y in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def page_image(chapter, number):
    if chapter == '100101':
        colors = ((220, 30, 30), (30, 220, 30), (30, 30, 220)) if number == '1' else ((30, 220, 220), (220, 30, 220), (220, 220, 30))
        return png(200, 12000, colors)
    return png(colors=((80, 140, 220),) if number == '1' else ((220, 140, 80),))


class FixtureSite(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global LONG_LIST
        components = urllib.parse.urlsplit(self.path)
        path = components.path
        query = urllib.parse.parse_qs(components.query)
        cookie = self.headers.get('Cookie', '')
        REQUESTS.append({'path': path, 'query': query, 'cookie': cookie, 'ua': self.headers.get('User-Agent', '')})
        status, content_type = 200, 'text/html; charset=utf-8'
        if path == '/fixture/long-list-on':
            LONG_LIST, body = True, b'ok'
        elif path == '/fixture/long-list-off':
            LONG_LIST, body = False, b'ok'
        elif path == '/fixture/queue-count':
            prefix = query.get('prefix', [''])[0]
            content_type, body = 'application/json', json.dumps(sum(item['path'].startswith(prefix) for item in REQUESTS)).encode()
        elif path.startswith(('/photo/', '/media/')) and 'moye-anonymous=fixture' not in cookie:
            status, body = 403, b'Anonymous cookie missing'
        elif path in ('/albums', '/search/photos'):
            def card(album, likes='120'):
                return f'<div class="list-col"><a href="/album/{album}"><img src="/media/albums/{album}.png" alt="匿名测试作品"></a><div class="video-title">匿名测试作品</div><span id="love_likes_{album}">{likes}</span><div class="tags"><a>韓漫</a><a>读者评论</a><a>剧情</a></div></div>'
            delayed = False
            page = int(query.get('page', ['1'])[0])
            if LONG_LIST and path == '/albums':
                cards = ''.join(card(str(700000 + (page - 1) * 80 + index)) for index in range(80)) if page <= 2 else ''
            elif path == '/search/photos':
                cards = card('100002') if page == 1 else card('100004') if page == 2 else ''
            elif query.get('t') == ['m'] and query.get('o') == ['tf']:
                cards, delayed = card('100003'), True
            else:
                cards = (card('100001') + card('100002') + card('100005')) if page == 1 else (card('100002') + card('100003')) if page == 2 else ''
            insertion = f'<script>setTimeout(()=>document.querySelector("main").innerHTML={json.dumps(cards)},140)</script>' if delayed else cards
            body = ('<html><body><nav><a href="/album/999999"><img src="/media/albums/nav.png"></a></nav><main>' + ('' if delayed else insertion) + '</main>' + (insertion if delayed else '') + '<img src="/slow-decoration"></body></html>').encode()
        elif path.startswith('/album/'):
            album = path.rsplit('/', 1)[1]
            if album.startswith('91'):
                chapters = ''.join(f'<a href="/photo/{int(album) * 10 + index}">Chapter {index}</a>' for index in (1, 2))
                date = '2026-10-01'
            elif album == '100002':
                chapters = '<a href="/photo/100101">第一章</a><div id="later"></div><script>setTimeout(()=>document.querySelector("#later").innerHTML=\'<a href="/photo/100102">第二章 [最新]</a><a href="/photo/100102">第二章</a>\',140)</script>'
                date = '2026-09-08'
            else:
                chapter = {'100001': '100201', '100003': '100301', '100004': '100401'}[album]
                chapters = f'<a href="/photo/{chapter}">唯一一话</a>'
                date = '2026-10-05' if album == '100003' else '2026-08-08'
            body = f'<html><body><h1 id="book-name">匿名测试作品</h1><span>上架日期：{date}</span>{chapters}<div class="album-thumb"><img src="/media/photos/100101/1.png"></div><img src="/slow-decoration"></body></html>'.encode()
        elif path.startswith('/photo/'):
            chapter = path.rsplit('/', 1)[1]
            page_array = 'window.page_arr=\'["2.png","1.png"]\';' if chapter == '100102' else ''
            count = 12 if chapter.startswith('85000') else 2
            images = ''.join(f'<img data-original="/media/photos/{chapter}/{index}.png">' for index in range(1, count + 1))
            body = f'<html><body><script>window.aid={chapter};window.scramble_id=0;{page_array}</script><div class="scramble-page">{images}</div><img src="/slow-decoration"></body></html>'.encode()
        elif path.startswith('/media/queue-blockers/'):
            time.sleep(5)
            content_type, body = 'image/png', png()
        elif path.startswith('/media/reader-queue/'):
            if 'fast' not in query and 5 <= int(path.rsplit('/', 1)[1].split('.')[0]) <= 8:
                time.sleep(5)
            content_type, body = 'image/png', png()
        elif path.startswith('/media/photos/'):
            _, _, _, chapter, filename = path.split('/')
            content_type, body = 'image/png', page_image(chapter, filename.split('.')[0])
        elif path == '/media/cover-ratio-test.png':
            width, height = (320, 200) if 'wide' in query else (120, 300)
            content_type, body = 'image/png', png(width, height, colors=((80, 140, 220),), circle=True)
        elif path.startswith('/media/albums/'):
            if 'performance-' in path:
                time.sleep(0.18)
                content_type, body = 'image/png', png(1200, 1800)
            else:
                content_type, body = 'image/png', png(160, 240, ((220, 30, 30), (30, 220, 30), (30, 30, 220)))
        elif path.startswith(('/media/', '/geometry/')):
            content_type, body = 'image/png', png()
        elif path == '/slow-decoration':
            time.sleep(6)
            content_type, body = 'image/png', png()
        else:
            status, body = 404, b'Unknown path'
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        if path in ('/albums', '/search/photos'):
            self.send_header('Set-Cookie', 'moye-anonymous=fixture; Path=/; HttpOnly')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def tool_command(args):
    if list(args[:2]) == ['xcrun', 'simctl'] and os.environ.get('MOYE_SIMCTL'):
        return [os.environ['MOYE_SIMCTL'], *args[2:]]
    return args


def command(*args, **kwargs):
    return subprocess.run(tool_command(args), env=ENV, check=True, capture_output=True, text=True, **kwargs)


def main():
    # Keep the parser/metadata copies aligned with the desktop source.
    import re
    desktop = (ROOT / 'source/Sources/NativeComicUI.swift').read_text()
    mobile = (ROOT / 'ios/MoyeReaderIOS/MoyeSiteScripts.swift').read_text()
    for name in ('searchScript', 'detailScript', 'photoScript'):
        left = re.search(r'(?:private )?static let ' + name + r' = """\n(.*?)\n    """', desktop, re.S).group(1).replace('\\\\', '\\')
        right = re.search(r'static let ' + name + r' = #"""\n(.*?)\n    """#', mobile, re.S).group(1)
        assert left == right, name
    assert (ROOT / 'source/Sources/MoyeComicMetadata.swift').read_bytes() == (ROOT / 'ios/MoyeReaderIOS/MoyeComicMetadata.swift').read_bytes()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureSite)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    devices = []
    performance = os.environ.get('MOYE_PERFORMANCE') == '1'
    output = ROOT / 'outputs' / os.environ.get('MOYE_TEST_OUTPUT', 'ios-verification')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'result.json').unlink(missing_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='moye-ios-smoke-', dir='/private/tmp') as directory:
            work = Path(directory)
            app = work / 'IOSSmoke.app'
            app.mkdir()
            binary = app / 'IOSSmoke'
            source_root = Path(os.environ.get('MOYE_IOS_SOURCE_ROOT', str(ROOT / 'ios/MoyeReaderIOS')))
            sources = sorted(path for path in source_root.glob('*.swift') if path.name != 'MoyeReaderIOSApp.swift')
            sdk = command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path').stdout.strip()
            compile_command = ['xcrun', 'swiftc', '-swift-version', '5', '-D', 'MOYE_IOS_DIAGNOSTICS', '-sdk', sdk,
                               '-target', 'arm64-apple-ios17.0-simulator', '-module-cache-path', str(work / 'cache'), '-framework', 'UIKit', '-framework', 'SwiftUI', '-framework', 'WebKit', '-framework', 'CryptoKit',
                               *map(str, sources), str(ROOT / ('tests/IOSPerformance.swift' if performance else 'tests/IOSSmoke.swift')), '-o', str(binary)]
            print('Compiling isolated iOS smoke app…', flush=True)
            compiled = subprocess.run(compile_command, env=ENV, capture_output=True, text=True)
            if compiled.returncode:
                print(compiled.stdout + compiled.stderr, flush=True)
            assert compiled.returncode == 0, 'iOS smoke compilation failed'
            bundle_id = 'com.moye.ios.smoke.' + work.name
            with (app / 'Info.plist').open('wb') as handle:
                plistlib.dump({'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'IOSSmoke', 'CFBundleName': 'Moye iOS smoke', 'CFBundlePackageType': 'APPL',
                              'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0', 'UIDeviceFamily': [1, 2],
                              'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}, 'UILaunchScreen': {},
                              'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']}, handle)
            shutil.copy2(ROOT / 'ios/MoyeReaderIOS/Assets.xcassets/MoyeMascot.imageset/MoyeMascot.png', app / 'MoyeMascot.png')
            command('codesign', '--force', '--sign', '-', str(app))
            reports = []
            targets = [('ipad', 'iPad-Pro-13-inch-M5-12GB')]
            if not performance and os.environ.get('MOYE_TEST_IPHONE') == '1':
                targets.insert(0, ('iphone', 'iPhone-17'))
            runtimes = json.loads(command('xcrun', 'simctl', 'list', 'runtimes', '-j').stdout)['runtimes']
            runtime = max((item for item in runtimes if item.get('isAvailable') and item['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')),
                          key=lambda item: tuple(map(int, item['version'].split('.'))))['identifier']
            for label, device_type in targets:
                device = command('xcrun', 'simctl', 'create', 'Moye smoke ' + label, 'com.apple.CoreSimulator.SimDeviceType.' + device_type, runtime).stdout.strip()
                devices.append(device)
                print('Booting isolated ' + label + ' simulator…', flush=True)
                command('xcrun', 'simctl', 'boot', device)
                command('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=180)
                command('xcrun', 'simctl', 'install', device, str(app), timeout=60)
                container = Path(command('xcrun', 'simctl', 'get_app_container', device, bundle_id, 'data').stdout.strip())
                launch_env = {**ENV, 'SIMCTL_CHILD_MOYE_SMOKE_ROOT': f'http://127.0.0.1:{server.server_port}'}
                subprocess.run(tool_command(['xcrun', 'simctl', 'launch', '--stdout=' + str(output / f'{label}.stdout.log'), '--stderr=' + str(output / f'{label}.stderr.log'), device, bundle_id]), env=launch_env, check=True, capture_output=True, text=True)
                print('Running ' + label + ' native checks…', flush=True)
                report_path = container / 'Documents/result.json'
                deadline = time.monotonic() + 180
                while not report_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.5)
                assert report_path.exists(), 'Simulator test did not produce a result: ' + label
                report = json.loads(report_path.read_text())
                destination = output / label
                destination.mkdir(exist_ok=True)
                for path in (container / 'Documents').rglob('*'):
                    if path.is_file():
                        target = destination / path.relative_to(container / 'Documents')
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(path, target)
                print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
                assert report['passed'], report
                if performance:
                    reports.append(report)
                    command('xcrun', 'simctl', 'shutdown', device)
                    continue
                archive_path = next((destination / 'MoyeDownloads').glob('*.zip'))
                with zipfile.ZipFile(archive_path) as archive:
                    assert sorted(archive.namelist()) == ['001_0001.png', '001_0002.png', '002_0001.png', '002_0002.png']
                    assert archive.testzip() is None
                    for name, chapter, number in [('001_0001.png', '100101', '1'), ('001_0002.png', '100101', '2'), ('002_0001.png', '100102', '2'), ('002_0002.png', '100102', '1')]:
                        assert archive.read(name) == page_image(chapter, number), name
                reports.append(report)
                command('xcrun', 'simctl', 'shutdown', device)
            if performance:
                (output / 'result.json').write_text(json.dumps({'passed': True, 'devices': reports}, indent=2) + '\n')
                print('Local iPad performance measurements saved.', flush=True)
                return
            protected = [item for item in REQUESTS if item['path'].startswith(('/photo/', '/media/'))]
            assert protected and all('moye-anonymous=fixture' in item['cookie'] and 'AVS=' not in item['cookie'] for item in protected)
            assert not any(item['path'].startswith(('/login', '/user')) for item in REQUESTS)
            assert all(item['query'].get('t') == ['m'] for item in REQUESTS if item['path'] == '/albums')
            assert all(item['ua'].startswith('Mozilla/5.0 (Macintosh;') for item in protected)
            result = {'passed': True, 'devices': reports, 'requests': len(REQUESTS), 'zip_checks': 'original PNG bytes, chapter order, page_arr order', 'parser_parity': True}
            (output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            print('Device checks passed, ZIP contents and shared parser parity verified.', flush=True)
    finally:
        for device in devices:
            subprocess.run(tool_command(['xcrun', 'simctl', 'shutdown', device]), env=ENV, capture_output=True, timeout=60)
            subprocess.run(tool_command(['xcrun', 'simctl', 'delete', device]), env=ENV, capture_output=True, timeout=60)
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
