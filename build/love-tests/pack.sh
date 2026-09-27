#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Package the LOVE test programs for Madeira.
#
#   build/love-tests/pack.sh                      -> out/hello.love, out/suite.love
#   build/love-tests/pack.sh <love-11.5-win64>    -> also out/madeira-love-tests/, a
#                                                    drop-in folder with hello.exe and
#                                                    suite.exe fused onto love.exe
#   build/love-tests/pack.sh <love-11.5-win64> --install
#                                                 -> also copies that folder to
#                                                    C:\madeira-love-tests on the device
#   build/love-tests/pack.sh --results            -> pulls results.txt / hello.txt
#                                                    from the device into out/
#
# <love-11.5-win64> is the unzipped official 64-bit Windows build
# (https://github.com/love2d/love/releases, love-11.5-win64.zip).
# Device: $MADEIRA_DEVICE (UDID or name), default: the first connected iPhone.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out"
BUNDLE_ID="${MADEIRA_BUNDLE_ID:-com.willfaust.madeora}"
# Fused LOVE games save to %APPDATA%\<identity> (no LOVE\ level). The Windows
# user name depends on how the prefix was made, so it is looked up.
IDENTITY="madeira-love-tests"

device() {
    if [ -n "${MADEIRA_DEVICE:-}" ]; then echo "$MADEIRA_DEVICE"; return; fi
    xcrun devicectl list devices 2>/dev/null | grep physical | grep -E "available|connected" \
        | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}" | head -1
}

if [ "${1:-}" = "--results" ]; then
    D="$(device)"; mkdir -p "$OUT"
    SAVE_DIR="$(xcrun devicectl device info files --device "$D" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" --subdirectory Documents/wine/drive_c/users 2>/dev/null \
        | awk '{print $1}' | grep -E "^[^/]+/AppData/Roaming/$IDENTITY$" | head -1)"
    if [ -z "$SAVE_DIR" ]; then echo "(no $IDENTITY save folder on the device yet)"; exit 0; fi
    echo "save folder: C:\\users\\${SAVE_DIR%%/*}\\AppData\\Roaming\\$IDENTITY"
    for f in results.txt hello.txt; do
        if xcrun devicectl device copy from --device "$D" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" --source "Documents/wine/drive_c/users/$SAVE_DIR/$f" \
            --destination "$OUT/$f" >/dev/null 2>&1
        then echo "== $f"; cat "$OUT/$f"; else echo "(no $f yet)"; fi
    done
    exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"
for t in hello suite; do
    (cd "$HERE/$t" && zip -q -r -X "$OUT/$t.love" .)
done
echo "built $OUT/hello.love $OUT/suite.love"

[ $# -ge 1 ] || exit 0
LOVE_DIR="$1"
if [ ! -f "$LOVE_DIR/love.exe" ] || [ ! -f "$LOVE_DIR/love.dll" ]; then
    echo "$LOVE_DIR does not look like love-11.5-win64 (no love.exe / love.dll)" >&2
    exit 1
fi

DROP="$OUT/madeira-love-tests"
mkdir -p "$DROP"
cp "$LOVE_DIR"/*.dll "$DROP/"
cp "$LOVE_DIR"/license.txt "$DROP/" 2>/dev/null || true
for t in hello suite; do
    # A fused LOVE game is love.exe with the .love zip appended (how Balatro ships).
    cat "$LOVE_DIR/love.exe" "$OUT/$t.love" > "$DROP/$t.exe"
done
echo "built $DROP ($(ls "$DROP" | tr '\n' ' '))"

if [ "${2:-}" = "--install" ]; then
    D="$(device)"
    for f in "$DROP"/*; do
        xcrun devicectl device copy to --device "$D" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" --source "$f" \
            --destination "Documents/wine/drive_c/madeira-love-tests/$(basename "$f")" >/dev/null
    done
    echo "installed to C:\\madeira-love-tests on $D"
fi
