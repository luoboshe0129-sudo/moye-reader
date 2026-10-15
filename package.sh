#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-"$PROJECT_ROOT/outputs"}"
"$PROJECT_ROOT/build.sh" "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/source/Info.plist")"
STAGE="$(mktemp -d "$OUTPUT_DIR/.moye-package.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
cp -R "$OUTPUT_DIR/墨夜阅读器.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<EOF
墨夜阅读器 $VERSION — 安装与使用

系统要求：Apple 芯片（M 系列）Mac，macOS 26 或以上。

安装
1. 退出旧版墨夜阅读器。
2. 将“墨夜阅读器.app”拖到旁边的“Applications”（应用程序）并替换旧版。
3. 在“应用程序”中双击打开，安装后可推出此磁盘映像。

使用
打开即可搜索、阅读和下载公开作品，无需账号。
点击作品：只有一话时直接阅读，多话时先选择章节。
首页右上角可选择站点线路，以及切换浅色/深色模式。
阅读：支持无中缝双页、竖向阅读和无缝长条模式。
横向双页遇到长条页时可上下滚动看完整内容；读到底后再翻下一组。
V 循环切换模式，F 全屏；N/P 切换下一章/上一章。
竖向及长条模式可用滚轮、触控板、空格和 Page Down/Up 连续浏览。
下载：选择所需章节，查看实时进度或取消；ZIP 按作品名命名。

此版本已移除登录和账号界面，不保存或恢复账号会话。
站点匿名 Cookie 只在本次运行期间共享，退出后不保存。
本安装包不包含账号、密码、Cookie、个人设置或阅读缓存。

首次打开的系统提示
本版本沿用临时签名，尚未使用 Developer ID 签名和 Apple 公证。
若 macOS 无法验证开发者，先尝试打开 APP，
再到“系统设置 → 隐私与安全性 → 仍要打开”，按系统提示确认。
Apple 官方说明：https://support.apple.com/zh-cn/102445
EOF
hdiutil create -ov -volname "墨夜阅读器 $VERSION" -srcfolder "$STAGE" -format UDZO "$OUTPUT_DIR/MoyeReader-$VERSION-macOS-arm64.dmg"
printf '安装包完成：%s\n' "$OUTPUT_DIR/MoyeReader-$VERSION-macOS-arm64.dmg"
