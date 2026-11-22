# Writes card.html: the repository's social preview, 1200x600 CSS pixels. render.sh screenshots it.
#
# BENI (the website's 3D wordmark) is centred on the card; the painted head hangs to its left, centred
# on the letters; the tagline and the GitHub link share the card's centre line.
#
#   python3 build.py [stars] [letters width in px]
import pathlib, re, sys
d = pathlib.Path(__file__).parent
stars = sys.argv[1] if len(sys.argv) > 1 else "42"
LW = float(sys.argv[2]) if len(sys.argv) > 2 else 560

# assets/word.png (the website's layer, 2x): where the letters are inside it, without the glow
WL = {"x0": 187, "x1": 1021, "y0": 273, "y1": 468}; WSIZE = (1296, 630)
k = LW / (WL["x1"] - WL["x0"]); LH = (WL["y1"] - WL["y0"]) * k
# assets/head.png: what it draws inside it
HB = {"x0": 98, "x1": 1140, "y0": 5, "y1": 1227}; HSIZE = (1282, 1227)
HH = 1.9 * LH                                     # the head is about twice the letters' height, as on the site
hk = HH / (HB["y1"] - HB["y0"])

TAG, TAG_GAP, PILL_GAP, PILL_H = 22, 34, 62, 64
lx0 = 600 - LW / 2                                # the letters are centred on the card
head_top_to_letters = HH / 2 - LH / 2             # the head is centred on the letters
total = max(HH, head_top_to_letters + LH + TAG_GAP + TAG + PILL_GAP + PILL_H)
top = (600 - total) / 2                           # the block, from the head's top to the pill's foot, is centred
ly0 = top + head_top_to_letters
word = dict(left=lx0 - WL["x0"] * k, top=ly0 - WL["y0"] * k, width=WSIZE[0] * k, height=WSIZE[1] * k)
hx1 = lx0 - 14                                    # a small gap between the head and the B
head = dict(left=hx1 - HB["x1"] * hk, top=top - HB["y0"] * hk, width=HSIZE[0] * hk, height=HSIZE[1] * hk)
tag_top = ly0 + LH + TAG_GAP
pill_top = tag_top + TAG + PILL_GAP
css = lambda r: ";".join(f"{k}:{v:.1f}px" for k, v in r.items())

github = re.search(r'<path d="([^"]+)"', (d / "assets/github.svg").read_text()).group(1)
spark = '<svg class="spark" viewBox="0 0 24 24"><path d="M12 0C13 8 16 11 24 12 16 13 13 16 12 24 11 16 8 13 0 12 8 11 11 8 12 0Z" fill="#F6BD80"/></svg>'

(d / "card.html").write_text(f"""<!doctype html><meta charset="utf-8">
<style>
@font-face {{ font-family: "Inter Tight"; src: url(assets/inter-tight.woff2) format("woff2"); font-weight: 400 600; }}
html, body {{ margin: 0; width: 1200px; height: 600px; overflow: hidden; background: #07050c; }}
body {{ position: relative; font-family: "Inter Tight", sans-serif; color: #f1e9f7; }}
.abs {{ position: absolute; display: block; }}
/* the website's night sky, then the painted nebula at the edges only (its middle holds the painted lockup) */
.stars {{ left: 0; top: 0; width: 1200px; height: 600px; }}
.neb {{ left: 0; top: 0; width: 1200px; height: 600px; background: url(assets/base.png) 0 0 / 1200px 600px;
  -webkit-mask: radial-gradient(ellipse 610px 225px at 585px 190px, transparent 82%, #000 100%);
          mask: radial-gradient(ellipse 610px 225px at 585px 190px, transparent 82%, #000 100%); }}
.tag {{ position: absolute; top: {tag_top:.1f}px; left: 0; width: 1200px; display: flex; align-items: center;
  justify-content: center; gap: 16px; }}
.tag p {{ margin: 0; font-size: {TAG}px; font-weight: 500; letter-spacing: .36em; padding-left: .36em;
  text-transform: uppercase; color: #f3e6da; line-height: 1; }}
.spark {{ width: 14px; height: 14px; filter: drop-shadow(0 0 4px #F0A050); }}
.pill {{ position: absolute; top: {pill_top:.1f}px; left: 50%; transform: translateX(-50%); height: {PILL_H}px;
  box-sizing: border-box; display: flex; align-items: center; gap: 18px; padding: 0 13px 0 26px; border-radius: 32px;
  border: 1.5px solid transparent;
  background: linear-gradient(rgb(14 8 24 / .85), rgb(14 8 24 / .85)) padding-box,
              linear-gradient(90deg, #a24dff, #d070ff 55%, #F0A050) border-box;
  box-shadow: 0 0 26px rgb(160 70 255 / .35), 0 0 44px rgb(240 160 80 / .12); }}
.gh {{ width: 36px; height: 36px; fill: #fff; }}
.url {{ font-size: 28px; font-weight: 500; }}
.url b {{ font-weight: 600; color: #cf7bff; }}
.stars-n {{ display: flex; align-items: center; gap: 9px; height: 42px; padding: 0 18px 0 14px; margin-left: 22px;
  border-radius: 21px; background: rgb(255 255 255 / .06); border: 1px solid rgb(255 255 255 / .12);
  font-size: 24px; font-weight: 600; }}
.stars-n svg {{ width: 24px; height: 24px; }}
</style>
<img class="abs stars" src="assets/stars.png">
<div class="abs neb"></div>
<img class="abs" src="assets/word.png" style="{css(word)}">
<img class="abs" src="assets/head.png" style="{css(head)}">
<div class="tag">{spark}<p>Functional, ahead of time</p>{spark}</div>
<div class="pill">
  <svg class="gh" viewBox="0 0 24 24"><path d="{github}"/></svg>
  <span class="url">github.com/canassa/<b>beni</b></span>
  <span class="stars-n"><svg viewBox="0 0 24 24"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01z" fill="#FFC53D"/></svg>{stars}</span>
</div>
""")
