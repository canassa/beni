## 2026-11-04 23:54 CET — CI loads the 404 stand-in at deep paths

**What I did**

For #244 I wrote `tests/browser/pages.mjs` and the step `zig build test-pages`. The step builds the examples' site with the tests' compiler under `/beni/`. The script serves the site on 127.0.0.1 with the 404 rule of GitHub Pages, and loads it in the Chrome of `nix develop .#browser`. In that Chrome, no host other than 127.0.0.1 resolves. At `/beni/conduit/`, `/beni/conduit/login` and `/beni/conduit/article/x`, the script checks one `div.app`, the title of the route, the shell's styles, the address, no `#not-found`, no failed request to the server and no page error. At `/beni/no/such/page` and `/beni/conduitlogin`, `#not-found` must show. The routed programs in the built `404.html` must be the ones that the script checks. In CI, the `browser` job runs the step. `browser-plan` has a second output, `pages`, for master and for a pull request that changes the examples, the browser runtime or the check. I asked the owner where the check runs (`pages-404-check-q1`).

Before the commit, I broke the stand-in three times, and each break failed the check. When `404.html` does not make the scripts again, 6 checks fail. A shell without its styles fails 2 checks. A `404.html` without a routed program fails 9 checks.

**What I learned**

- Headless Chrome asks for `/favicon.ico` at the root of the origin, outside the site's base. On GitHub Pages that path is another site. The check ignores that one request.
- Chrome writes into its profile until it exits. When I removed the profile before the exit, `rmSync` failed with `ENOTEMPTY`, but only in some runs. Wait for the `exit` event first.
- `--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1` blocks every other host. The fonts and the RealWorld API fail fast, and Conduit still renders each route. Thus the check does not need a stub API.
- `tests/corpus/browser/managed` is not on master. Thus on a pull request, the Chrome corpus of the `browser` job never runs. Before this change, the job never ran on a pull request. Now it runs for the site check only.
- The `prepend_in_loop` warnings in the site build come from `examples/bike-wars`, not from sternhalma. The log prints a program's warnings before its `built` line. That is #1918.
