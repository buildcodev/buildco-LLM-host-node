#!/usr/bin/env bash
# Builds dist/Espalier.app (and dist/Espalier.zip).
#   scripts/bundle.sh              build for this Mac's architecture
#   scripts/bundle.sh --universal  build for Apple silicon and Intel
# Signs ad hoc unless CODESIGN_IDENTITY names a Developer ID identity.
set -euo pipefail
cd "$(dirname "$0")/.."

arch_flags=()
if [[ "${1:-}" == "--universal" ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi

swift build -c release ${arch_flags[@]+"${arch_flags[@]}"}
bin_dir=$(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)

app=dist/Espalier.app
rm -rf "$app" dist/Espalier.zip
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Espalier" "$app/Contents/MacOS/Espalier"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
ditto -c -k --keepParent "$app" dist/Espalier.zip
echo "Built $app"
