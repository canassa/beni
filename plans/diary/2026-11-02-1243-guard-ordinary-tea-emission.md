## Guard ordinary TEA release output

**What I did**

Added an ordinary navigation page to the TEA release emission corpus, with
byte-for-byte JavaScript and source-map goldens (#1680). An emit fixture's
optional `.map` golden enables the existing source-map build flag and compares
that output alongside its JavaScript.

**What I learned**

Reverting lazy worker-runtime loading changes this page's short JavaScript
names, while preserving map coordinates. A temporary unused comment in Rt
changes only the source map. Both local regressions failed the new fixture;
restoring the production files made the targeted test pass.
