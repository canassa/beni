## 2026-10-24 21:20 CEST — E6 measured and dropped

**What I did**

- I priced E6 on master after step B and E7. A script folds the four
  per-widget lists into one table, built at load, on the 12 S1 outputs.
- One-file brotli: N = 16 +16 / +28 / +13 B, N = 64 −23 / −52 / −70 B,
  N = 256 −359 / −511 / −486 B. The 64→256 slope is about −2.1 B/widget.
- I dropped E6 and recorded the numbers in the hand-minify plan's new §6.
  This closes #946: step B (#948), E7 (#949) and E6 measured.

**What I learned**

- The raw bytes shrink at every size, but brotli grows at N = 16. A
  raw-size proxy cannot tell where E6 pays, and only a threshold tuned to
  the benchmark could. Under the brief's rules that is not a size rule.
