## 2026-11-05 00:03 CET — Core gets a calendar, and Conduit shows dates

**What I did**

I added `core/Date` (`boundary.md` §9.8.21, #1912): moments, zones by the name of the host's time zone database, the calendar's parts, and RFC 3339 parsing and printing. The browser's `Time.Posix` is now an alias of `Date.Posix`. The test harness gives every child `TZ=UTC`, Chrome included. Conduit keeps the reader's zone in `Session` and shows "February 18, 2016" (#239). Where the calendar lives is the owner's decision (`conduit-fixes-q1`). I built the recommended answer, a core module.

**What I learned**

- A module's `pub eq` is the `eq` of every type that the module declares (`static-dispatch-spike.md` §11). My `pub eq` for `Zone` broke `==` on `Posix`, `Month` and `Weekday`. My own fixture did not see it, because it compares none of them with `==`. The doc-example gate did. The answer was to make `Zone` plain data and keep the host's formatters in a cache.
- `Basics.clamp` takes the value first: `clamp n low high`. With Elm's order, every moment took the offset of the year 275760, and all named zones were wrong by the DST hour.
- A `Js.Value` inside a model value changes the ownership checker's report: a host call on it counts as a write to the value that holds it. With a formatter in `Zone`, Conduit's ownership golden got new rejections (`Home.fetchFeed writes π1`). With plain data it has the same 38 as master.
- Node's `Date.parse` turns `2016-04-31` into 1 May and `2015-02-29` into 1 March, with no error.
- One `RegExp` and range checks are 359 bytes of brotli smaller in Conduit than the same parser over `String`, because the `String` helpers that it pulls in are gone. The parser over `String` also accepted a fraction with no seconds.
- `beni check` accepts an impure call in a view. I wrote the opposite in the skill text first, then tested it and corrected it.
- The harness gives a child an empty environment, so Node reads `/etc/localtime`. `env -i node out/_main.mjs` reproduces the old harness exactly: the fixture's `here` line printed `Europe/Berlin`.
