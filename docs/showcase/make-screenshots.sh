#!/bin/sh
# Regenerate every screenshot in docs/showcase/*.png from examples/*.bend.
# Needs: emacs (batch), Google Chrome (headless), optionally pngquant/magick.
# Real bend-mode font-lock does the fontification; Chrome only rasterises.
set -eu
cd "$(dirname "$0")/../.."
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
OUT=docs/showcase
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for ex in 03-shapes 02-parallel-pow2 06-law-and-proof 04-arrays; do
  emacs -Q --batch -L src -l "$OUT/render.el" \
    --eval "(bend-showcase-render \"examples/$ex.bend\" \"$TMP/$ex.html\" \"$ex.bend\")"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --window-size=1500,1000 \
    --screenshot="$TMP/$ex.png" "file://$TMP/$ex.html" >/dev/null 2>&1
  # trim the empty page area around the window
  magick "$TMP/$ex.png" -trim +repage -colors 128 "$OUT/$ex.png"
done
