#!/usr/bin/env bash
# Renders the raster logo files from the SVG sources in this directory.
# Needs google-chrome (or chromium) and ImageMagick 7; ImageMagick's own SVG
# renderer drops stroked paths, so Chrome draws each SVG large and ImageMagick
# scales it down.
#   logo-256.png          logo.svg
#   logo-light-1024.png   logo-light.svg (print)
#   logo-1024.png         logo.svg (print)
#   icon-{16,32,48}.png   icon.svg, the window icon
#   icon-{16,32,48}.rgba  the same pixels as raw RGBA rows, read by the dashboard
set -euo pipefail
cd "$(dirname "$0")"
chrome=$(command -v google-chrome || command -v chromium)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

draw() {  # draw <svg> <out.png>: the SVG at 1024 px on a transparent ground
    printf '<html><body style="margin:0"><img src="%s" width="1024" height="1024"></body></html>' \
        "file://$PWD/$1" > "$work/page.html"
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
        --window-size=1024,1024 --screenshot="$2" "file://$work/page.html" 2>/dev/null
}

draw logo.svg "$work/logo.png"
draw logo-light.svg "$work/light.png"
draw icon.svg "$work/icon.png"

magick "$work/logo.png" -strip logo-1024.png
magick "$work/light.png" -strip logo-light-1024.png
magick "$work/logo.png" -filter Box -resize 256x256 -strip logo-256.png
for n in 16 32 48; do
    magick "$work/icon.png" -filter Box -resize "${n}x${n}" -strip "icon-$n.png"
    magick "icon-$n.png" -depth 8 "RGBA:icon-$n.rgba"
done
