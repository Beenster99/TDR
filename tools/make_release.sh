#!/usr/bin/env bash
# Builds a release zip: TopDownRacer.exe + README.txt (the release notes).
#   GODOT=/path/to/godot-4.6.2 tools/make_release.sh 0.1.0
# Needs release_notes/<version>.txt and the 4.6.2 Windows export template.
# Output: build/TopDownRacer-<version>.zip
set -euo pipefail
VERSION="${1:?version, e.g. 0.1.0}"
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTES="$DIR/release_notes/$VERSION.txt"
[ -f "$NOTES" ] || { echo "missing $NOTES"; exit 1; }
cd "$DIR"
sed -i "s/^application\/file_version=.*/application\/file_version=\"$VERSION.0\"/; s/^application\/product_version=.*/application\/product_version=\"$VERSION.0\"/" export_presets.cfg
sed -i "s/^config\/version=.*/config\/version=\"$VERSION\"/" project.godot
grep -q '^config/version=' project.godot || sed -i "s/^config\/name=\"Top Down Racer\"/&\nconfig\/version=\"$VERSION\"/" project.godot
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
STAGE="build/release/TopDownRacer-$VERSION"
rm -rf "$STAGE" && mkdir -p "$STAGE"
"$GODOT" --headless --path . --export-release "Windows Desktop" "$STAGE/TopDownRacer.exe"
# Windows line endings so Notepad shows it properly.
sed 's/$/\r/' "$NOTES" > "$STAGE/README.txt"
rm -f "build/TopDownRacer-$VERSION.zip"
(cd build/release && python3 -c "
import sys, zipfile, os
v = sys.argv[1]
with zipfile.ZipFile(f'../TopDownRacer-{v}.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in ('TopDownRacer.exe', 'README.txt'):
        z.write(os.path.join(f'TopDownRacer-{v}', f), f'TopDownRacer-{v}/{f}')
" "$VERSION")
ls -la "build/TopDownRacer-$VERSION.zip"
