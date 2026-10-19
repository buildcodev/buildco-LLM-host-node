#!/usr/bin/env bash
# Builds dist/Espalier-<version>.pkg, an installer for other Macs (Apple silicon):
#   - Espalier.app into /Applications, quitting and replacing an older copy
#   - if Grid is installed there, the same Grid shortcuts as this Mac
#   - a warning during installation when Grid isn't installed
# The Grid shortcuts are refreshed from this Mac's Grid settings when Grid is set up here,
# and otherwise come from Resources/Installer/grid-shortcuts.txt. Only shortcut settings
# are copied; never Grid's license or update settings.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

shortcuts=Resources/Installer/grid-shortcuts.txt
if defaults read app.macgrid.Grid shortcutLeft >/dev/null 2>&1; then
  /usr/bin/python3 -I - > "$shortcuts" <<'EOF'
import plistlib, subprocess
prefs = plistlib.loads(subprocess.run(["defaults", "export", "app.macgrid.Grid", "-"], capture_output=True, check=True).stdout)
print("# Grid's window shortcuts, one per line: type, setting, value (written by scripts/package.sh)")
for key in sorted(prefs):
    if key.startswith("shortcut") and isinstance(prefs[key], bytes):
        print("data", key, prefs[key].hex())
# Grid writes its own defaults on first launch unless it has been set up already.
print("bool preferencesInitialized true")
EOF
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/Applications" "$work/scripts"
ditto dist/Espalier.app "$work/root/Applications/Espalier.app"
cp Resources/Installer/scripts/preinstall Resources/Installer/scripts/postinstall "$shortcuts" "$work/scripts/"
chmod 755 "$work/scripts/preinstall" "$work/scripts/postinstall"

# Always install to /Applications, even when another copy of the app exists elsewhere.
pkgbuild --analyze --root "$work/root" "$work/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"
pkgbuild --quiet --root "$work/root" --component-plist "$work/components.plist" --scripts "$work/scripts" \
  --identifier dev.buildco.espalier.pkg --version "$version" --install-location / "$work/Espalier-component.pkg"

sed "s/@VERSION@/$version/g" Resources/Installer/Distribution.xml > "$work/Distribution.xml"
mkdir -p dist
productbuild --quiet --distribution "$work/Distribution.xml" --resources Resources/Installer/resources \
  --package-path "$work" "dist/Espalier-$version.pkg"
echo "Built dist/Espalier-$version.pkg"
