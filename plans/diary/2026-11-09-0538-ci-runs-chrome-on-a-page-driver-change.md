## 2026-11-09 05:38 CET — CI runs Chrome on a page driver change

**What I did**

- Issue #2003. The pull-request plan of the `Chrome` job selected the corpus on the browser runtime, core's Task dependencies and `src/js` only. The step now also selects it when `tests/browser/driver.mjs` or a local module it imports changes.
- The import list comes from the code: a loop follows each `from "./x.mjs"` and `import("./x.mjs")`, transitively. Today it finds `compile-cache.mjs` and `fuzz.mjs`.

**What I learned**

- `tests/corpus/browser/managed` exists on master now, so the issue's second point (every pull request skipped) no longer applies.
- The site check (`tests/browser/pages.mjs`) does not use the page driver, so the driver is not in its list.
- The gates' page digest holds `driver.mjs` and `fuzz.mjs`, not `compile-cache.mjs`. That file only prunes Node's compile cache, so its bytes do not change a page.
