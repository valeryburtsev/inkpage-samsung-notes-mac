#!/bin/bash
# Build "Inkpage.app" with Xcode (Xcode/SNotes.xcodeproj) into build/Inkpage.app.
#   ./xcode-build.sh                      build for CloudKit when the signing team allows it, else without
#   SNOTES_TEAM=ABCDE12345 ./xcode-build.sh   sign with this development team (else the one in Xcode/team.local)
#   SNOTES_LOCAL=1 ./xcode-build.sh       build without the iCloud entitlements, whatever the team
#
# CloudKit and iCloud Keychain need the iCloud capability, which Apple gives only to teams of the
# paid Apple Developer Program. A "Personal Team" cannot have it: the app is then built without
# those entitlements and syncs through a folder in iCloud Drive instead (see README).
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p build
log=build/xcode-build.log
args=(-project Xcode/SNotes.xcodeproj -scheme "SNotes App" -configuration Release -derivedDataPath build/xcode)
# The signing team is not kept in the project: it comes from SNOTES_TEAM, or from Xcode/team.local
# (one line, the team's ID; not committed).
team="${SNOTES_TEAM:-}"
[ -z "$team" ] && [ -f Xcode/team.local ] && team="$(tr -d '[:space:]' < Xcode/team.local)"
[ -n "$team" ] && args+=("DEVELOPMENT_TEAM=$team")
kind=""
if [ -z "${SNOTES_LOCAL:-}" ] && xcodebuild "${args[@]}" -allowProvisioningUpdates build > "$log" 2>&1; then
  kind="with CloudKit and iCloud Keychain"
else
  why="$(grep -m1 -o 'error: .*' "$log" 2>/dev/null | cut -c8-260)"
  if ! xcodebuild "${args[@]}" SNOTES_ENTITLEMENTS=SNotes-Local.entitlements build >> "$log" 2>&1; then
    grep -E "error:" "$log" | sort -u | head -10
    echo "the build failed; the whole log is in $log"
    exit 1
  fi
  kind="without CloudKit"
  [ -n "$why" ] && [ -z "${SNOTES_LOCAL:-}" ] && echo "not signed for iCloud: $why"
fi
# The app was called SNotes until 2026-10-14: a build of that name is not left beside it.
rm -rf build/SNotes.app build/Inkpage.app
cp -R build/xcode/Build/Products/Release/Inkpage.app build/Inkpage.app
echo "built build/Inkpage.app $kind"
