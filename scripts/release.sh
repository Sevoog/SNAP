#!/bin/bash
# release.sh
# SNAP: Builds, checks, signs, and (optionally) publishes a release
# Created by Sevag Bardakjian
# Copyright © 2026 Sevag Bardakjian
# SPDX-License-Identifier: GPL-3.0-only
# Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
#
#   scripts/release.sh               build, check, zip, and sign into release/
#   scripts/release.sh --publish     then tag and create the GitHub release
#   --skip-tests                     skip the test run (not recommended)
#
# Before running: bump MARKETING_VERSION (CURRENT_PROJECT_VERSION follows it,
# 1.5.8 -> 10508), date the CHANGELOG entry, update WhatsNew in Updates.swift,
# and write release/RELEASE_NOTES-<version>.md with a {{SHA256}} placeholder
# where the zip's checksum goes. Builds aren't byte-for-byte reproducible, so
# the script fills it in (or replaces an older checksum) each run, and
# --publish uploads that same zip in the same run.
#
# Needs: Xcode, the signing key in the Keychain (scripts/sign-release.swift),
# and an authenticated `gh` for --publish.

set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
TESTS=1
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --skip-tests) TESTS=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# ---- Version checks -------------------------------------------------------

PBX=SNAP.xcodeproj/project.pbxproj
VERSION=$(grep -o 'MARKETING_VERSION = [0-9.]*;' "$PBX" | grep -v '= 1.0;' | sort -u | sed 's/.*= \(.*\);/\1/')
[ "$(echo "$VERSION" | wc -l | tr -d ' ')" = 1 ] || fail "the app's Debug and Release versions differ: $VERSION"
IFS=. read -r MAJ MIN PAT <<< "$VERSION"
BUILD=$(( MAJ * 10000 + MIN * 100 + ${PAT:-0} ))
grep -q "CURRENT_PROJECT_VERSION = $BUILD;" "$PBX" || fail "set CURRENT_PROJECT_VERSION to $BUILD for $VERSION"
grep -qE "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md || fail "CHANGELOG.md needs a dated '## [$VERSION] - YYYY-MM-DD' entry"
grep -q "static let version = \"$VERSION\"" SNAP/Updates.swift || fail "update WhatsNew (version and items) in SNAP/Updates.swift"
NOTES="release/RELEASE_NOTES-$VERSION.md"
[ -f "$NOTES" ] || fail "write $NOTES first"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "release from main"
echo "SNAP $VERSION (build $BUILD) from $(git rev-parse --short HEAD)"

# ---- Tests and build ------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ $TESTS = 1 ]; then
  step "Running tests"
  xcodebuild test -project SNAP.xcodeproj -scheme SNAP -derivedDataPath "$WORK/test" > "$WORK/test.log" 2>&1 \
    || { tail -30 "$WORK/test.log"; fail "tests failed (log above)"; }
  grep -E 'Executed [0-9]+ tests' "$WORK/test.log" | tail -1
fi

step "Building the universal Release app"
xcodebuild -project SNAP.xcodeproj -scheme SNAP -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$WORK/build" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build > "$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log"; fail "build failed (log above)"; }
APP="$WORK/build/Build/Products/Release/SNAP.app"

step "Checking the app"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/SNAP")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "not universal: $ARCHS"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || fail "version mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] || fail "build number mismatch"
codesign --verify --deep --strict "$APP" || fail "code signature doesn't verify"
if strings "$APP/Contents/MacOS/SNAP" | grep -q "$HOME"; then fail "the binary contains paths from this Mac"; fi
echo "universal ($ARCHS), version $VERSION, build $BUILD, signature OK, no local paths"

# ---- Zip, checksum, signature ---------------------------------------------

step "Zipping and signing"
mkdir -p release
ZIP="release/SNAP-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256" "$ZIP.sig"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd release && shasum -a 256 "SNAP-$VERSION.zip" > "SNAP-$VERSION.zip.sha256")
SHA=$(cut -d' ' -f1 "$ZIP.sha256")
swift scripts/sign-release.swift sign "$ZIP"
swift scripts/sign-release.swift verify "$ZIP" "$ZIP.sig" scripts/release-signing-key.pub
mkdir "$WORK/unzip" && ditto -x -k "$ZIP" "$WORK/unzip"
codesign --verify --deep --strict "$WORK/unzip/SNAP.app" || fail "the unzipped app's signature doesn't verify"
echo "$ZIP  $(stat -f %z "$ZIP") bytes"
echo "SHA-256 $SHA"

if grep -q '{{SHA256}}' "$NOTES"; then
  sed -i '' "s/{{SHA256}}/$SHA/g" "$NOTES"
elif grep -qE '[0-9a-f]{64}' "$NOTES"; then
  sed -i '' -E "s/[0-9a-f]{64}/$SHA/g" "$NOTES"      # a checksum from an earlier run
else
  fail "add {{SHA256}} to $NOTES where the zip's checksum goes"
fi
echo "Checksum written into $NOTES"

[ $PUBLISH = 1 ] || { echo; echo "Ready. Run again with --publish to tag and create the GitHub release."; exit 0; }

# ---- Publish --------------------------------------------------------------

step "Publishing"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "push main first (HEAD isn't on GitHub)"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "tag v$VERSION already exists"
TITLE=$(head -1 "$NOTES" | sed -E 's/^\*\*(.*)\*\*.*/\1/; s/\.$//')
read -r -p "Publish SNAP $VERSION to GitHub as the latest release? [y/N] " answer
[ "$answer" = y ] || [ "$answer" = Y ] || fail "not published"
git tag -a "v$VERSION" -m "SNAP $VERSION: $TITLE"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --repo Sevoog/SNAP --title "SNAP $VERSION" \
  --notes-file "$NOTES" --verify-tag --latest
DIGEST=$(gh api "repos/Sevoog/SNAP/releases/tags/v$VERSION" --jq ".assets[] | select(.name == \"SNAP-$VERSION.zip\") | .digest")
[ "$DIGEST" = "sha256:$SHA" ] || fail "GitHub's copy has a different checksum ($DIGEST)"
echo "Published: https://github.com/Sevoog/SNAP/releases/tag/v$VERSION (checksum matches)"
