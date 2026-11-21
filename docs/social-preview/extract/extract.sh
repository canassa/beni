#!/usr/bin/env bash
# extract.sh: render ../assets/word.png and ../assets/stars.png from the beni-website hero, headless at
# 1200x600 @2x. word.png is the BENI wordmark with its glow on a transparent background, cropped to what
# it draws; stars.png is the night sky without the planet. If word.png's crop changes, update WL in
# ../build.py (the letters' box inside it). Set SITE when beni-website is not beside this checkout.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
OUT=$(realpath "$HERE/../assets")
SITE=${SITE:-$(realpath "$HERE/../../../../beni-website")}
cd "$SITE"
B="browse --width 1200 --height 600 --dpr 2 --settle 8 --quiet"
nix develop -c $B eval 'index.html?edit' "$(cat "$HERE/word.js")" 2>/dev/null | grep '^"' > "$OUT/word.json" \
  || { echo "extract.sh: the wordmark render returned nothing (run it again; headless WebGL is slow)" >&2; rm -f "$OUT/word.json"; exit 1; }
nix develop -c python3 - "$OUT" <<'PY'
import base64, io, json, pathlib, sys
from PIL import Image
out = pathlib.Path(sys.argv[1])
im = Image.open(io.BytesIO(base64.b64decode(json.loads((out / "word.json").read_text()).split(",", 1)[1])))
box = im.getchannel("A").point(lambda a: 255 if a > 2 else 0).getbbox()
im.crop(box).save(out / "word.png", optimize=True)
(out / "word.json").unlink()
print("word.png: cropped at", box, "of", im.size)
PY
nix develop -c $B --wait-js "$(cat "$HERE/stars.js")" shot 'index.html?edit' -o "$OUT/stars.png" 2>/dev/null | tail -1
