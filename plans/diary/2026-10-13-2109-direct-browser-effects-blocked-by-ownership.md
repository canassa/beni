## 2026-10-13 21:09 CEST — direct browser effects blocked by ownership

**What I did**

Read CLAUDE.md and the browser-direct effects contract and dated amendments. Started
`browser-direct-s5` from freshly fetched origin/master. Specified and attempted the
compiled host, copying browser-tea's beni command/subscription driver as required.
Checking the embedded direct platform rejected the Concurrent appends in keyed and
keyedNow and the tap append in want, all as list_may_be_shared checker limits. Kept
the attempted implementation outside the working tree at
`/tmp/beni-browser-direct-s5-blocked.patch`; no incomplete runtime changes are in this
branch. Added the reduced subscription-tap page under tests/pending with its error
signature pinned, and an identical gated browser-tea oracle and transcript. Recorded
its run hashes with Node 24.19.0, using zorg for builds and tests. The PR records a
blocker, not a completed effects slice; no merge is requested.

**What I learned**

The copied driver itself must pass ownership checking before the embedded direct
platform can build. This prevents independently shipping element, document,
subscriptions or after-render work through the required host. Q5 was already decided;
subscription fiber policy is not the blocker. A platform-only reproduction can miss
this failure because its unused driver is trusted or unreachable in the application
ownership walk; the app-level want reproduction reaches the same diagnostic directly.
No List.copy, list-mode change or JavaScript rewrite was used to bypass it.
