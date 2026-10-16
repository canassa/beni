## 2026-10-16 12:19 CEST — The Conduit example wears the RealWorld theme (#234)

**What I did.** The deployed Conduit page showed plain HTML. Its markup already used the class names
of the RealWorld theme, so I gave it a page shell, `examples/conduit/index.html`, with the theme
inline: `assets/theme/styles.css` of `realworld-apps/realworld` (MIT), unchanged. A second `<style>`
holds beni's own rules. It draws the four Ionicons 2.0.1 glyphs that the pages use as SVG masks, and
it moves the theme's `app-root` rules to `div.app`. It also fixes three faults that the theme has at
phone widths: no column padding below 768 px, a floated tag list that runs into the next preview,
and a signed-in navigation bar wider than the phone. The fonts load from Google Fonts, as the
RealWorld spec does. `examples/404.html` stood in for a routed program's page with the default shell,
so `build-pages.mjs` refused a shell of Conduit's own. Now the build puts each routed program's built
shell into the 404 page, and its script puts that shell in place of the page. The shell is 6.4 kB
brotli, against 28.9 kB for the release `_main.mjs`.

**What I learned.** `gothinkster/realworld` is now `realworld-apps/realworld`. The theme moved there
as one file, and the old hosts answer 404: `demo.productionready.io/main.css` and elm-spa-example's
default avatar, `static.productionready.io/images/smiley-cyrus.jpg`. The fix for the avatar changes
Conduit's emitted JavaScript, and then the gates run Conduit's value fuzz under Node. On master that
fuzz costs 7 127M instructions, over its 6 700M grant (measured at 6 088M a day earlier). A matching
`.fuzz-run-hash` skips Node, and `test-run-hashes` records with no budget, so five re-records on
2026-10-16 hid the growth (#237). I left the avatar fix out (#238). Dates as ISO text (#239) and the
Markdown body as plain text (#240) are content gaps, not style, so they have issues of their own.
