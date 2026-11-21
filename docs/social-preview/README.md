# The repository's social preview

`beni-og.png` is the image that sites such as X, Slack and Discord show for a link to the repository.
It is 1200×600, the size of GitHub's own card. Upload it in the repository's Settings → General →
Social preview. There is no API for this step.

The card shows the BENI wordmark in the middle, with Beni's head to its left. Under them are the tagline
and the GitHub link with the star count. The wordmark, the tagline and the link share the card's centre
line. The head is centred on the letters.

## Rebuild it

```sh
./render.sh          # the current star count, from gh
./render.sh 120      # a given star count
```

`build.py` writes `card.html` from the assets. `render.sh` then takes a screenshot of it in headless
Chrome. Chrome and Python come from the dev shell of the website repository, `beni-website`. The script
expects that checkout beside this one; set `SITE` when it is not.

The star count is fixed in the image. X keeps a link's card for some days, so a new upload can take time
to show. To make X read the new card, add a query string to the link, for example `?v=2`.

## The assets

| File | What it is |
|---|---|
| `assets/word.png` | The website's 3D wordmark with its glow, 2×, transparent. From `extract/`. |
| `assets/stars.png` | The website's night sky without the planet, 2400×1200. From `extract/`. |
| `assets/head.png` | The painted head, transparent. |
| `assets/base.png` | The painted card. `build.py` keeps only the nebula at its edges. |
| `assets/inter-tight.woff2` | The website's sans font, Inter Tight (SIL OFL 1.1, `assets/OFL.txt`). |
| `assets/github.svg` | The GitHub mark (Simple Icons, CC0). |

`extract/extract.sh` renders `word.png` and `stars.png` again from the website's hero. It runs
`?edit`, plays the entrance one frame at a time so that the pose is the same on every run, and reads the
hero canvas back. That canvas is premultiplied, and each pixel is at least as opaque as it is bright, so
the read-back keeps the glow. If the crop of `word.png` changes, update `WL` in `build.py`. `WL` is the
box of the letters inside the image.
