#!/usr/bin/env bash
# Build Shellmoor, publish it as a GitHub release, and add it to the
# SideStore/AltStore source (source.json).
#
# Usage: scripts/release.sh <version> "<what's new>"
#   e.g. scripts/release.sh 1.0.1 "Fixes signature import."
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/release.sh <version> \"<release notes>\"" >&2
    exit 1
fi
version="$1"
notes="$2"
repo="crazyquark/shellmoor"
tag="v$version"

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean; commit or stash first." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag already exists." >&2
    exit 1
fi

# Version in Info.plist; the build number counts up with every release.
build=$(python3 -I scripts/source.py bump-version Info.plist "$version")
echo "Building $version ($build)..."

xtool dev build --ipa -c release
ipa=xtool/Shellmoor.ipa

git add Info.plist
git commit -q -m "Release $version"
git tag "$tag"
git push -q origin HEAD "$tag"

gh release create "$tag" "$ipa" --repo "$repo" --title "Shellmoor $version" --notes "$notes"

# Point the source at the new release and publish it.
python3 -I scripts/source.py add-version source.json "$version" "$build" "$notes" \
    "https://github.com/$repo/releases/download/$tag/Shellmoor.ipa" "$ipa"
git add source.json
git commit -q -m "Source: add $version"
git push -q origin HEAD

echo "Released $version: https://github.com/$repo/releases/tag/$tag"
