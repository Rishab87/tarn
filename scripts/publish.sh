#!/bin/bash
#
# Publishes what scripts/release.sh made: signs the notarized DMG for Sparkle, writes the update
# feed (appcast.xml), attaches both to a GitHub release, puts the DMG on the website and deploys it.
# Installed copies of Tarn check the feed every time they open (Tarn/Services/System.swift) and
# install the update when Tarn quits.
#
#   scripts/publish.sh "What's new, one line"
#
# Needs: a finished build/release (notarized, stapled), the update-signing key in this Mac's login
# keychain (Sparkle's generate_keys made it; its public half is TARN_ED_PUBLIC_KEY in project.yml),
# gh logged in to GitHub, and the Vercel CLI (npx vercel) linked in website/.

set -euo pipefail

NOTES=${1:?usage: scripts/publish.sh "What's new, one line"}
REPO="Rishab87/tarn"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${RELEASE_OUT:-$ROOT/build/release}"
APP="$OUT/Tarn.app"
DMG="$OUT/Tarn.dmg"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

SPARKLE_BIN=""
for d in "${RELEASE_DERIVED:-$ROOT/build/DerivedData-release}" "$ROOT/build/DerivedData-release" "$ROOT/build/DerivedData"; do
  [[ -x $d/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update ]] && { SPARKLE_BIN=$d/SourcePackages/artifacts/sparkle/Sparkle/bin; break; }
done
[[ -n $SPARKLE_BIN ]] || die "Sparkle's tools not found; build the app once (scripts/release.sh)"

# Only a notarized, stapled release goes out.
xcrun stapler validate "$DMG" >/dev/null || die "$DMG is not notarized and stapled; run scripts/release.sh"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
FEED=$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist" 2>/dev/null || true)
KEY=$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ -n $FEED && -n $KEY ]] || die "this build has no SUFeedURL or SUPublicEDKey, so it could never update itself; set TARN_ED_PUBLIC_KEY in project.yml and rebuild"
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
TAG="v$VERSION-$BUILD"
echo "Tarn $VERSION ($BUILD) -> $TAG"

# The EdDSA signature Sparkle checks before installing (with Apple's code signature).
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG")
[[ $SIGNATURE == *edSignature=* ]] || die "sign_update gave no signature: $SIGNATURE"

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tarn</title>
    <item>
      <title>Tarn $VERSION ($BUILD)</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Tarn.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT/appcast.xml" || die "appcast.xml is not valid XML"

# The newest release is "latest", which is where installed apps look for appcast.xml.
gh release create "$TAG" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --title "Tarn $VERSION ($BUILD)" --notes "$NOTES" --latest
cp "$DMG" "$ROOT/website/download/Tarn.dmg"
(cd "$ROOT/website" && npx --yes vercel@65.9.0 deploy --prod --yes >/dev/null)

# Check what people get.
curl -fsSL "$FEED" | grep -q "<sparkle:version>$BUILD</sparkle:version>" || die "the live feed doesn't list build $BUILD yet"
LIVE=$(curl -fsSL https://tarn-ai.vercel.app/download/Tarn.dmg | shasum -a 256 | cut -d' ' -f1)
[[ $LIVE == $(shasum -a 256 "$DMG" | cut -d' ' -f1) ]] || die "the website serves a different DMG"
echo "published $TAG: feed $FEED, website DMG matches"
