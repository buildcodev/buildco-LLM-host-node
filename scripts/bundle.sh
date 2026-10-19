#!/usr/bin/env bash
# Builds dist/Espalier.app (and dist/Espalier.zip).
#   scripts/bundle.sh              build for this Mac's architecture
#   scripts/bundle.sh --universal  build for Apple silicon and Intel
# Signs ad hoc (keeping Accessibility across rebuilds) unless CODESIGN_IDENTITY names an identity.
set -euo pipefail
cd "$(dirname "$0")/.."

binary=$(mktemp -d)/Espalier
if [[ "${1:-}" == "--universal" ]]; then
  # Building several architectures at once needs Xcode's build system, so build each
  # one (which the Command Line Tools can) and merge them.
  for arch in arm64 x86_64; do swift build -c release --triple "$arch-apple-macosx14.0"; done
  lipo -create .build/arm64-apple-macosx/release/Espalier .build/x86_64-apple-macosx/release/Espalier -output "$binary"
else
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/Espalier" "$binary"
fi

app=dist/Espalier.app
rm -rf "$app" dist/Espalier.zip
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Espalier"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$app"
else
  # Ad hoc. macOS remembers Accessibility permission against the app's designated
  # requirement, which for ad hoc code is normally its hash and changes with every build.
  # Requiring only the bundle id lets rebuilds keep the permission.
  codesign --force --sign - --requirements '=designated => identifier "dev.buildco.espalier"' "$app"
fi
ditto -c -k --keepParent "$app" dist/Espalier.zip
echo "Built $app"
