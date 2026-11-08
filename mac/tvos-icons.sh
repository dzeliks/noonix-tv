#!/usr/bin/env bash
# apple tv's icon layers + top shelf images (Resources/tvos/*.png) from the app icon's kitty.
# needs rsvg-convert + magick; run after the kitty changes, the pngs are committed
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/Resources/tvos"
kitty="$here/Resources/AppIcon.icon/Assets/kitty.svg"
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

back() { # w h out
    cat > "$tmp/back.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$1" height="$2" viewBox="0 0 $1 $2">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#FF9BCF"/><stop offset="0.55" stop-color="#F0559F"/><stop offset="1" stop-color="#B8246E"/>
  </linearGradient></defs>
  <rect width="$1" height="$2" fill="url(#g)"/>
</svg>
SVG
    rsvg-convert "$tmp/back.svg" -o "$3"
}
front() { # w h out: the kitty in the middle, 0.72 of the height (it fills 668 of its 1024 square)
    local s=$(( $2 * 72 / 100 * 1024 / 668 ))
    rsvg-convert -w "$s" -h "$s" "$kitty" -o "$tmp/k.png"
    # the kitty sits 36 above its square's middle: down by that
    magick -size "$1x$2" xc:none "$tmp/k.png" -gravity center -geometry "+0+$(( s * 36 / 1024 ))" -composite "$3"
}

for spec in icon:400:240 icon@2x:800:480 store:1280:768; do
    IFS=: read -r n w h <<< "$spec"
    back "$w" "$h" "$out/$n-back.png"
    front "$w" "$h" "$out/$n-front.png"
done
# the top shelf: one flat picture
for spec in shelf:1920:720 shelf@2x:3840:1440 shelf-wide:2320:720 shelf-wide@2x:4640:1440; do
    IFS=: read -r n w h <<< "$spec"
    back "$w" "$h" "$tmp/b.png"
    front "$w" $(( h * 7 / 10 )) "$tmp/f.png"
    magick "$tmp/b.png" "$tmp/f.png" -gravity center -composite "$out/$n.png"
done
# the launch image tvos zooms the icon into: black, the splash's first frame
magick -size 1920x1080 xc:black -strip "$out/launch.png"
magick -size 3840x2160 xc:black -strip "$out/launch@2x.png"
ls "$out"
