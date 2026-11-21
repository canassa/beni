## 2026-11-21 09:18 CET — A social preview card for the repository

**What I did**

- Built `docs/social-preview/`: the 1200×600 card that X and other sites show for a link to the
  repository, with its assets and the scripts that make it again. The owner uploads it in the
  repository's settings (GitHub has no API for it).
- The card: the website's 3D BENI wordmark centred, the owner's painted head to its left and centred
  on the letters, the tagline, and the GitHub link with the real star count (42). `extract/` renders the
  wordmark and the night sky from beni-website's hero; `build.py` and `render.sh` compose the card in
  headless Chrome from beni-website's dev shell.

**What I learned**

- beni-website's hero canvas is premultiplied, and each pixel is at least as opaque as it is bright
  (the OutputPass edit in `src/logo.js`), so `toDataURL` gives a transparent PNG that keeps the bloom.
  Headless WebGL is too slow for the entrance to finish by wall-clock time, so drive
  `window.hero.frame` by hand under `?edit`: the pose is then the same on every run.
- Design choices the owner made: the word is centred on the card, not the head and word as a group,
  because the text below shares the card's axis and two axes 80 px apart look like a mistake. The head
  keeps the website's size relative to the word. A static star count is fine; the mock-up's invented
  numbers (3.4k stars, 128 forks) and its feature claims were not used.
