## 2026-10-15 14:57 CEST — vendor the playground editor and measure the shipped page

**What I did**

PR #136 (the editor) was merged at 12:44 UTC, before its review findings
were fixed, so they join the part 1 findings on the review branch.

- Jayson decided `wasm-playground-q6`: the editor's 13 CodeMirror modules
  are files of the site now, not esm.sh's. `playground/vendor.sh` takes each
  package's own ES module from its npm tarball, unmodified, after it checks
  the tarball against npm's SHA-512; `vendor/SHA256SUMS` and
  `vendor/LICENSES.txt` record each file's checksum, source and MIT
  licence. A gate test checks the files and the import map; the Chrome test
  checks that the page asks no other origin for anything.
- `bench/playground/chrome.mjs` drives the editor again (links from
  `share.js`, typed edits) and measured the page that ships: TodoMVC median
  36–38 ms, the depth limit 790 levels (606 on the first page).
- A defect no longer marks the newest version as failed; the version it
  ran for is the one marked.

**What I learned**

- Both pull requests merged while their reviews ran. A finding then has to
  go to a new branch, and a push to the merged branch recreates it on the
  remote: I recreated `feat/wasm-playground` that way and could not delete
  it.
- A status line moves on within milliseconds once the worker is ready, so a
  measurement reads a data attribute the page sets, not the status.
- npm's tarballs are immutable, so a vendor script over them reproduces the
  same bytes; a CDN that rebuilds its output cannot be pinned by a hash.
