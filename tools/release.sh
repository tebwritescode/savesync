#!/usr/bin/env bash
#
# Package the mod and verify the zip before anything is published.
#
#   tools/release.sh <version>        e.g. tools/release.sh 1.8.0
#
# WHY THIS EXISTS. v1.8.0 shipped a zip whose manifest still said 1.7.1: the
# version was bumped in the source AFTER the mod had been copied into the
# engine checkout, and `modkit pack` faithfully packaged the stale copy. The
# launcher offered the update, installed it, and then reported the old version
# -- a confusing failure with no error anywhere.
#
# So: one script does the copy and the pack in that order, and REFUSES to
# produce a zip whose manifest disagrees with the version asked for.
set -euo pipefail

VERSION="${1:-}"
[ -z "$VERSION" ] && { echo "usage: tools/release.sh <version>"; exit 1; }

MOD="$(cd "$(dirname "$0")/.." && pwd)/mod"
ENGINE="${GEN1RECOMP:-/c/Users/User/Projects/gen1recomp-engine}"
OUT="${OUT:-/tmp/savesync-$VERSION.zip}"

say() { printf '  %s\n' "$1"; }

# 1. The source manifest is the source of truth; it must already say so.
SRC_VERSION=$(python -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$MOD/manifest.json")
if [ "$SRC_VERSION" != "$VERSION" ]; then
  echo "REFUSING: mod/manifest.json says $SRC_VERSION, you asked for $VERSION"
  echo "Bump the manifest first, then run this."
  exit 1
fi
say "source manifest: $SRC_VERSION"

# 2. Copy AFTER the version check, so the engine copy can never be the stale
#    one -- that ordering is the entire bug this script prevents.
rm -rf "$ENGINE/mods/savesync"
cp -r "$MOD" "$ENGINE/mods/savesync"
say "copied into $ENGINE/mods/savesync"

# 3. The engine's own gates. Strict validate is what upstream asks for before
#    a listing, and lint is the no-ROM-content guarantee.
(cd "$ENGINE" && python tools/modkit.py validate mods/savesync --strict >/dev/null)
(cd "$ENGINE" && python tools/modkit.py lint mods/savesync >/dev/null)
say "modkit validate --strict + lint: ok"

(cd "$ENGINE" && python tools/modkit.py pack mods/savesync -o "$OUT" >/dev/null)

# 4. Verify the ARTIFACT, not the intent. Everything above can be right and
#    the zip still wrong; this reads what actually got packaged.
ZIP_VERSION=$(unzip -p "$OUT" manifest.json | python -c "import json,sys;print(json.load(sys.stdin)['version'])")
if [ "$ZIP_VERSION" != "$VERSION" ]; then
  echo "REFUSING: the packaged zip says $ZIP_VERSION, expected $VERSION"
  rm -f "$OUT"
  exit 1
fi

# The loader needs the mod's files at the archive root, not nested in a
# folder; upstream's submission checklist calls this out by name.
if ! unzip -l "$OUT" | grep -qE ' main\.lua$'; then
  echo "REFUSING: main.lua is not at the archive root"
  rm -f "$OUT"
  exit 1
fi

say "packaged zip manifest: $ZIP_VERSION"
say "main.lua at archive root: yes"
echo "$OUT"
