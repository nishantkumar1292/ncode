#!/bin/zsh
# Build ncode.app (release) into ./build. Usage: ./build.sh [--install] [--open]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ncode.app
swift build -c release --arch arm64 2>&1 | grep -v "^\[" || true
BIN=$(swift build -c release --arch arm64 --show-bin-path)/ncode
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ncode"
cp -R Resources/web "$APP/Contents/Resources/web"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make_icon.swift Resources/AppIcon.icns >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

for arg in "$@"; do
  case $arg in
    --install)
      rm -rf /Applications/ncode.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications/ncode.app"
      # The `ncode` command (`ncode .` opens a folder, like `code .`). Never overwrite someone else's `ncode`.
      for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
        case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac
        [ -w "$d" ] || continue
        if [ -e "$d/ncode" ] && ! grep -q "open -a ncode" "$d/ncode" 2>/dev/null; then echo "Skipped: $d/ncode exists and isn't ours"; break; fi
        cp bin/ncode "$d/ncode" && chmod +x "$d/ncode" && echo "Installed the ncode command to $d/ncode"; break
      done ;;
    --open) open "$APP" ;;
  esac
done
