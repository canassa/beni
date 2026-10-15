## 2026-10-14 19:34 CEST — grant the direct JSON pages their own budgets

**What I did**

Measured why `browser/direct/HttpJson` and `HttpJsonBody` go over the
4 300M budget on Linux (issue #101): 4 799M and 4 942M on master, 5 710M
and 5 809M when Node runs the pages. A direct page is four builds in one
case, and `Http.expectJson` and `Http.jsonBody` reach the `core/Schema`
library interpreter. In one direct release build that adds 768M, and
641M of it is `specialise`. I filed that cost as issue #105. I asked the
owner through the dashboard. A review of my first question showed that
a split of the `browser-tea` builds into a case of their own also fits;
I built and gated it, and kept it as a patch outside the repo. The owner
chose a grant. I added the two `.budget` files (8 500M and 8 800M), sized
on `-Dcpu=x86_64` counts with Node running plus 10%, and listed them in
the README and CLAUDE.md. `zig build gates` is green.

**What I learned**

My first question said that no smaller input fits; that was wrong. The
budget rule names a split, and churn is not a reason to reject one. On a
baseline CPU the run-hash check computes SHA-256 in software, and with
both cases in one process the case that runs first costs about 500M
more. Each case alone gives a stable count. PR #104's reference CPU,
`x86_64_v3+sha`, gives the Zen 2 counts, so the grant can shrink to
6 300M and 6 400M after it lands.
