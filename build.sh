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
# Sign with a real certificate when one is available. An ad-hoc signature ("-") ties the app's
# identity to its binary hash, so macOS forgets privacy grants (Documents, Desktop, ...) on every
# rebuild. A certificate gives a stable identity, so a grant survives rebuilds.
# Override with NCODE_SIGN_IDENTITY (a certificate name or SHA-1 hash, or "-" for ad-hoc).
SIGN_ID=${NCODE_SIGN_IDENTITY:-}
SIGN_KIND="identity from NCODE_SIGN_IDENTITY"
if [[ -z "$SIGN_ID" ]]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for kind in "Developer ID Application" "Apple Development"; do
    SIGN_ID=$(print -r -- "$IDS" | grep -m1 "\"$kind: " | awk '{print $2}' || true)
    [[ -n "$SIGN_ID" ]] && { SIGN_KIND=$kind; break; }
  done
fi
[[ -n "$SIGN_ID" ]] || { SIGN_ID=-; SIGN_KIND="ad-hoc"; }
[[ "$SIGN_ID" == "-" ]] && SIGN_KIND="ad-hoc (macOS will re-ask for folder access after each rebuild)"
if ! codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
  [[ "$SIGN_ID" == "-" ]] && { echo "codesign failed"; exit 1; }
  echo "Signing with the $SIGN_KIND certificate failed; falling back to ad-hoc"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  SIGN_KIND="ad-hoc (macOS will re-ask for folder access after each rebuild)"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1)), signed: $SIGN_KIND"

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
