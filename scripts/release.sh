#!/bin/bash
#
# Developer ID release of Tarn: build, sign with the hardened runtime, notarize and staple the app,
# then wrap it in a DMG that is itself signed, notarized and stapled. Users can open the result
# without the "Open Anyway" detour.
#
#   scripts/release.sh
#
# Output: build/release/Tarn.app and build/release/Tarn.dmg (plus the notary logs), or RELEASE_OUT.
# Then scripts/publish.sh puts it out: GitHub release with the update feed, and the website.
# Needs:  Xcode, xcodegen, Engine/llama (python3 scripts/fetch_llama.py), the Developer ID
#         Application certificate in the login keychain, and notarytool credentials saved as the
#         keychain profile below (xcrun notarytool store-credentials tarn-notary ...).
# Safe to re-run: every run starts from a clean build and an empty build/release.
# It never changes version numbers; bump them in project.yml before running it.

set -euo pipefail

IDENTITY="Developer ID Application: Rishab Kumar Jha (QMYVK5D735)"
TEAM_ID="QMYVK5D735"
NOTARY_PROFILE="tarn-notary"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# RELEASE_OUT and RELEASE_DERIVED let two releases build side by side (one can still be waiting on Apple).
DERIVED="${RELEASE_DERIVED:-$ROOT/build/DerivedData-release}"
OUT="${RELEASE_OUT:-$ROOT/build/release}"
APP="$OUT/Tarn.app"
DMG="$OUT/Tarn.dmg"
ENTITLEMENTS="$ROOT/Tarn/Tarn.entitlements"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Everything we ship is signed this way. Notarization rejects code without our Developer ID,
# the hardened runtime (--options runtime) or a secure timestamp (--timestamp).
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

# Upload a file to Apple's notary service and wait for the verdict; stop on anything but Accepted.
NOTARY_RESULTS=()
notarize() {
  local file=$1 label=$2 id status
  id=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --no-wait --output-format json | jq -r '.id // empty')
  [[ -n $id ]] || die "upload of $file to the notary service failed"
  echo "submission $id: waiting for Apple (usually a few minutes)"
  xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" --timeout 2h --output-format json >/dev/null || true
  status=$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r '.status // empty')
  echo "submission $id: $status"
  NOTARY_RESULTS+=("$label  $id  $status")
  case $status in
    Accepted)
      # Accepted uploads can still carry warnings: keep the log and show them.
      if xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-$label.json" >/dev/null; then
        jq -r '.issues // [] | .[] | "notary \(.severity): \(.path) \(.message)"' "$OUT/notary-$label.json"
      fi
      ;;
    Invalid|Rejected)
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
      die "notarization of $label: $status (log above)"
      ;;
    *)
      # A new team's first submissions can stay "In Progress" for a day or more.
      die "notarization of $label has not finished (status: ${status:-unknown}); check it with: xcrun notarytool info $id --keychain-profile $NOTARY_PROFILE"
      ;;
  esac
}

# Attach the ticket so Gatekeeper can check it offline. Just after acceptance the ticket can take
# a moment to reach Apple's CDN, so retry a few times.
staple() {
  local attempt
  for attempt in 1 2 3; do
    xcrun stapler staple "$1" && return 0
    sleep 15
  done
  die "could not staple $1"
}

cd "$ROOT"

step "Preflight"
[[ -f Engine/llama/llama-server ]] || die "Engine/llama is missing; run: python3 scripts/fetch_llama.py"
command -v xcodegen >/dev/null || die "xcodegen not found; run: brew install xcodegen"
[[ $(security find-identity -v -p codesigning) == *"\"$IDENTITY\""* ]] || die "signing identity not in the keychain: $IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || die "notary keychain profile '$NOTARY_PROFILE' does not work"

step "Building (Release)"
# project.yml is the source of truth (the version numbers live there), so regenerate the project.
xcodegen generate --quiet
echo "commit $(git describe --always --dirty 2>/dev/null || echo unknown)"
rm -rf "$OUT"
mkdir -p "$OUT"
# Clean build, so files deleted from the source tree can't linger in the bundle. Xcode signs ad hoc
# here as configured; every signature is replaced below.
echo "log: build/release/xcodebuild.log"
if ! xcodebuild -project Tarn.xcodeproj -scheme Tarn -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    -onlyUsePackageVersionsFromResolvedFile clean build >"$OUT/xcodebuild.log" 2>&1; then
  tail -n 40 "$OUT/xcodebuild.log" >&2
  die "build failed; full log: $OUT/xcodebuild.log"
fi
# Sign a copy in build/release, which holds everything this script produces.
ditto "$DERIVED/Build/Products/Release/Tarn.app" "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
echo "Tarn $VERSION ($BUILD)"

step "Signing, inside out (nested code first, the app last)"
# The engine. llama-server finds these dylibs through @rpath = @loader_path (Contents/MacOS), and
# the hardened runtime's library validation only loads libraries signed by the same team, so each
# one gets our signature. llama-server gets a reverse-DNS identifier instead of its file name.
for lib in "$APP"/Contents/MacOS/*.dylib; do sign "$lib"; done
sign --identifier app.tarn.mac.llama-server "$APP/Contents/MacOS/llama-server"

# Sparkle ships its helpers ad hoc signed. Re-sign each one as Sparkle's docs say
# (sparkle-project.org/documentation/sandboxing): keep the Downloader's entitlements and drop the
# rest. That includes Autoupdate's com.apple.application-identifier, a restricted entitlement
# that would need a provisioning profile next to a Developer ID signature.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"

# The app, with our entitlements. This also drops the get-task-allow entitlement that Xcode adds
# to non-archive builds, which notarization rejects.
sign --entitlements "$ENTITLEMENTS" "$APP"

step "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarization fails if any Mach-O lacks the hardened runtime, a secure timestamp or our team ID,
# or is debuggable (get-task-allow). Check every one before uploading.
runtime_re='flags=0x[0-9a-f]+\([^)]*runtime'
debug_re='get-task-allow</key>[[:space:]]*<true/>'
count=0
bad=0
while IFS= read -r -d '' f; do
  [[ $(file -b "$f") == Mach-O* ]] || continue
  count=$((count + 1))
  info=$(codesign -dvv "$f" 2>&1 || true)
  ents=$(codesign -d --entitlements - --xml "$f" 2>/dev/null || true)
  runtime=no
  stamp=no
  debug=no
  [[ $info =~ $runtime_re ]] && runtime=yes
  [[ $info == *$'\n'Timestamp=* ]] && stamp=yes
  team=$(sed -n 's/^TeamIdentifier=//p' <<<"$info")
  [[ $ents =~ $debug_re ]] && debug=yes
  verdict=ok
  if [[ $runtime != yes || $stamp != yes || $team != "$TEAM_ID" || $debug != no ]]; then
    verdict=FAIL
    bad=$((bad + 1))
  fi
  printf '%-4s  runtime=%-3s  timestamp=%-3s  team=%-10s  get-task-allow=%-3s  %s\n' \
    "$verdict" "$runtime" "$stamp" "${team:-none}" "$debug" "${f#"$APP"/}"
done < <(find "$APP" -type f -print0 | sort -z)
[[ $count -gt 0 ]] || die "no Mach-O files found in $APP"
[[ $bad -eq 0 ]] || die "$bad of $count Mach-O files are not ready for notarization (FAIL above)"
echo "all $count Mach-O files: hardened runtime, secure timestamp, team $TEAM_ID, not debuggable"

step "Notarizing the app"
# notarytool takes a zip, not a bare .app. The zip is deleted afterwards: it holds the unstapled
# app, so it must not be mistaken for something to ship.
ditto -c -k --keepParent "$APP" "$OUT/Tarn-notarize.zip"
notarize "$OUT/Tarn-notarize.zip" app
rm "$OUT/Tarn-notarize.zip"
staple "$APP"

step "Building the DMG"
# Same layout as before: the stapled app and a link to /Applications, no background.
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Tarn.app"
ln -s /Applications "$OUT/dmg/Applications"
diskutil image create from --format UDZO --volumeName Tarn "$OUT/dmg" "$DMG"
rm -rf "$OUT/dmg"
# A disk image takes a plain signature; the hardened runtime only applies to code.
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

step "Notarizing the DMG"
notarize "$DMG" dmg
staple "$DMG"

step "Final checks"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -v "$DMG"

# The same checks on the copy users get: the app inside the DMG.
MNT="$(mktemp -d)/Tarn"
diskutil image attach --readOnly --nobrowse --mountPoint "$MNT" "$DMG" >/dev/null
trap 'diskutil eject "$MNT" >/dev/null 2>&1 || true' EXIT
echo "DMG contents:"
ls -l "$MNT"
codesign --verify --deep --strict "$MNT/Tarn.app"
xcrun stapler validate "$MNT/Tarn.app"
spctl -a -vv "$MNT/Tarn.app"
diskutil eject "$MNT" >/dev/null
trap - EXIT
rmdir "$(dirname "$MNT")" 2>/dev/null || true

step "Done: Tarn $VERSION ($BUILD)"
for r in "${NOTARY_RESULTS[@]}"; do echo "notary  $r"; done
echo "app     build/release/Tarn.app"
echo "dmg     build/release/Tarn.dmg ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "sha256  $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
