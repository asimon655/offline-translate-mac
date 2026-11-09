#!/bin/bash
# Builds "Offline Translate.app" with the Command Line Tools only (no Xcode).
#
#   scripts/build-app.sh --dev              # fast: the app uses the library's dev venv instead of a bundled Python
#   scripts/build-app.sh                    # release: bundles Python + offline-translate, ad-hoc signed
#   scripts/build-app.sh --dmg              # ... and makes dist/OfflineTranslate-<version>.dmg + a Homebrew cask
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<notarytool profile> scripts/build-app.sh --dmg
#   SIGN_ID="OfflineTranslate Dev" scripts/build-app.sh --dev   # a self-signed cert from Keychain Access
#
# Env: LIB_DIR (offline-translate checkout, default ../offline-translate), PY_VERSION (default 3.14),
#      VERSION (default from packaging/version), SIGN_ID (default "-" = ad-hoc), NOTARY_PROFILE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEV=0
DMG=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

LIB_DIR="${LIB_DIR:-$ROOT/../offline-translate}"
PY_VERSION="${PY_VERSION:-3.14}"
VERSION="${VERSION:-$(cat packaging/version)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Default: the local "OfflineTranslate Dev" certificate if there is one (keeps the Accessibility permission across
# rebuilds), otherwise ad-hoc.
if [[ -z "${SIGN_ID:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"OfflineTranslate Dev"'; then
  SIGN_ID="OfflineTranslate Dev"
fi
SIGN_ID="${SIGN_ID:--}"
APP="$ROOT/build/Offline Translate.app"
CONTENTS="$APP/Contents"
step() { printf '\n==> %s\n' "$*"; }

step "Compiling (release)"
scripts/swift build -c release --arch arm64 2>&1 | grep -v "search path .* not found" || true
BIN="$(scripts/swift build -c release --arch arm64 --show-bin-path 2>/dev/null | tail -1)/OfflineTranslate"
[[ -x "$BIN" ]] || { echo "build failed" >&2; exit 1; }

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/OfflineTranslate"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" packaging/Info.plist > "$CONTENTS/Info.plist"
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

if [[ $DEV == 1 ]]; then
  PY="$LIB_DIR/.venv/bin/python"
  [[ -x "$PY" ]] || { echo "no venv at $LIB_DIR/.venv (run: cd $LIB_DIR && uv venv && uv pip install -e .)" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :OTDevPython string $PY" "$CONTENTS/Info.plist"
  echo "dev build: helper runs from $PY"
else
  HELPER="$CONTENTS/Resources/helper"
  step "Bundling Python $PY_VERSION (python-build-standalone via uv)"
  uv python install "$PY_VERSION" --no-bin --install-dir "$ROOT/build/python" >/dev/null
  SRC_PY="$(ls -d "$ROOT"/build/python/cpython-"$PY_VERSION".*-macos-aarch64-none | sort -V | tail -1)"
  cp -R "$SRC_PY" "$HELPER"
  rm -f "$HELPER/lib/python$PY_VERSION/EXTERNALLY-MANAGED"

  step "Installing offline-translate from $LIB_DIR"
  uv pip install --quiet --python "$HELPER/bin/python3" "$LIB_DIR"

  step "Trimming"
  STD="$HELPER/lib/python$PY_VERSION"
  rm -rf "$HELPER/include" "$HELPER/share" "$HELPER"/lib/{tcl*,tk*,itcl*,thread*,pkgconfig} \
         "$STD"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data,venv} \
         "$STD"/config-*/*.a "$STD"/lib-dynload/_tkinter*.so \
         "$STD"/site-packages/pip "$STD"/site-packages/pip-*
  find "$HELPER" \( -name __pycache__ -o -name tests -o -name test \) -type d -prune -exec rm -rf {} +
  find "$HELPER/bin" -mindepth 1 ! -name "python3" ! -name "python$PY_VERSION" -exec rm -rf {} +
  # numpy ships its own test data and headers we never use
  rm -rf "$STD"/site-packages/numpy/{_core/include,f2py,_pyinstaller,testing/_private,doc} 2>/dev/null || true

  step "Checking the bundled helper"
  "$HELPER/bin/python3" -s -X pycache_prefix="$ROOT/build/pycache" -c \
    "import offline_translate, offline_translate.engine, ai_edge_litert, numpy, sentencepiece; print('offline_translate', offline_translate.__version__)"
  du -sh "$HELPER" | awk '{print "helper size: " $1}'
fi

step "Signing ($([[ $SIGN_ID == - ]] && echo ad-hoc || echo "$SIGN_ID"))"
SIGN_OPTS=(--force --sign "$SIGN_ID")
# Hardened runtime + secure timestamp are what notarization needs; a local self-signed certificate (handy to keep
# the Accessibility permission across rebuilds) signs without them.
[[ $SIGN_ID == "Developer ID"* ]] && SIGN_OPTS+=(--options runtime --timestamp)
# Inside-out: every nested Mach-O first, then the app. Notarization rejects unsigned nested code.
if [[ -d "$CONTENTS/Resources/helper" ]]; then
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      codesign "${SIGN_OPTS[@]}" "$f" 2>&1 | grep -v "replacing existing signature" || true
    fi
  done < <(find "$CONTENTS/Resources/helper" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0)
fi
codesign "${SIGN_OPTS[@]}" --entitlements packaging/app.entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$APP" && echo "signature ok"
du -sh "$APP" | awk '{print "app size: " $1}'

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ $SIGN_ID == "Developer ID"* ]] || { echo "notarizing needs SIGN_ID=\"Developer ID Application: …\"" >&2; exit 1; }
  step "Notarizing"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

if [[ $DMG == 1 ]]; then
  [[ $DEV == 1 ]] && { echo "--dmg needs a release build (without --dev)" >&2; exit 1; }
  step "Making DMG"
  mkdir -p dist
  STAGE="$ROOT/build/dmg"
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG_PATH="dist/OfflineTranslate-$VERSION.dmg"
  hdiutil create -quiet -volname "Offline Translate" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
  [[ $SIGN_ID == "Developer ID"* ]] && codesign --sign "$SIGN_ID" --timestamp "$DMG_PATH"
  [[ -n "${NOTARY_PROFILE:-}" ]] && xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait && xcrun stapler staple "$DMG_PATH"
  SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/" packaging/offline-translate.rb.template > dist/offline-translate.rb
  ls -lh "$DMG_PATH" | awk '{print "dmg: " $9 " (" $5 ")"}'
  echo "cask: dist/offline-translate.rb"
fi
echo
echo "built: $APP"
