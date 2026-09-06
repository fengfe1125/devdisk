#!/bin/bash
# Builds DevDisk.app from the SwiftPM executable.
#
# The signature is ad-hoc (`-`), which is enough for personal use but not notarized,
# so the first launch needs Finder → right-click → Open. The bundle identifier and
# the signature must both stay stable: macOS keys Automation permission to them, and
# changing either makes every rebuild look like a brand new app that has to be
# re-authorized before it can ask Android Studio to quit.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DevDisk"
BUILD_DIR=".build/apple/Products/Release"
APP="build/${APP_NAME}.app"
DEST="${1:-/Applications}"

echo "==> 构建"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "构建产物不存在：$BIN" >&2; exit 1; }

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# SwiftPM emits target resources as a separate .bundle next to the binary.
# Bundle.module traps at launch if it is not inside the app, so this copy is
# load-bearing, not housekeeping.
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] || continue
    case "$(basename "$b")" in *Tests.bundle) continue ;; esac
    cp -R "$b" "${APP}/Contents/Resources/"
done
if ! ls "${APP}/Contents/Resources/"*DevDiskKit.bundle >/dev/null 2>&1; then
    echo "错误：资源 bundle 未打包，菜单栏图标会在启动时崩溃" >&2
    exit 1
fi

echo "==> 签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> 完成：$APP  ($SIZE)"

if [ "${DEST}" != "-" ]; then
    echo "==> 安装到 ${DEST}"
    # Replacing a running agent would leave the old process live; stop it first.
    pkill -x "${APP_NAME}" 2>/dev/null || true
    rm -rf "${DEST}/${APP_NAME}.app"
    cp -R "$APP" "${DEST}/"
    echo "    ${DEST}/${APP_NAME}.app"
    echo
    echo "首次打开：在 Finder 里右键 → 打开（未经公证，双击会被 Gatekeeper 拦下）"
fi
