## 2026-10-16 14:17 CEST — The Conduit fonts no longer hold back the program (#234)

**What I did.** An adversarial review of PR #241 measured the home page of the styled Conduit example:
206–234 ms to `div.app`, against 37–55 ms on master, and 6.3 s with the Google Fonts CSS 6 s late. The
shell's font link is now a print stylesheet whose `onload` applies it to the screen. With the font CSS
6 s late, ten cold loads took 40–64 ms (master 37–52), and the fonts still apply on the home page and on
deep links. The page has no `<noscript>` copy, because the page shows nothing without scripts. No test
loads `404.html` at a deep path, and CI has no browser for it, so that check is issue #244. I also
corrected two statements on the PR: its body, and my reply about `AGENTS.md`, which is a tracked
symlink to `CLAUDE.md`.

**What I learned.** A stylesheet link that the parser inserts blocks every script after it, a deferred
module script too, so a slow font host stops a beni program from starting. The 404 stand-in hid this:
there the link is inserted by a script, so it blocks nothing, and deep links stayed fast. `DOMParser`
parses with scripts off, so a `<noscript>` in a shell that `404.html` embeds gives live elements there.
In this measurement the first page of a fresh Chrome was sometimes 3–4 times slower than the next ones,
so one cold sample per process shows that warm-up, not the page.
