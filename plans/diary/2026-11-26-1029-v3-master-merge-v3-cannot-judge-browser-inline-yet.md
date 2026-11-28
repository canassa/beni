## 2026-11-26 10:29 CET — v3: master merge; v3 cannot judge browser-inline yet

**What I did**

- Merged `origin/master` (110 commits) into the ownership v3 branch, reusing the
  resolutions of the earlier kept merge where the same files conflicted. The markup
  interface keeps master's 1.39–1.41 and renumbers the branch's `Lowering.keeps_let`
  to 1.42. Master's inline copies of `DictFoldLeft`, `DictFoldRight`, `FoldRight` and
  `SubscriptionTapFold` call `Dict.empty ⊤`, as their tea twins on the branch do;
  `HttpResponseMeta`'s inline transcript lists headers in insertion order, as its twin's
  does. Master's `Http` came through its move to `browser-base` with the branch's
  `Dict.empty ⊤` in `headersFrom`, so the three Http pages type-check.
- Swept every `browser/inline` page with `check` under v1 and v3, before the merge
  (146 pages) and after it (422 pages). No page that existed before changed verdict
  under either checker.
- The v3 ledger on real roots: 309 of 319 of v1's list writes accepted, as before.

**What I learned**

- v3 cannot be the checker that judges `browser-inline` yet: it refuses 39 of the 422
  pages, 38 of which the corpus treats as safe (the 39th is `CellSendTypedLive`, a
  pinned refusal). 30 of the refusals are `unknown` at an `entry … update` demand ("the
  runtime does not hand this as the function's own"), 8 `later-use` on record writes.
  Switching the platform to v3 would refuse 35 pages that v1 accepts today.
- v3 accepts `HttpRequestShape`, `HttpTrack`, `ValueCommands` and `SubscriptionTapFold`;
  it refuses `DictFoldLeft`, `DictFoldRight` and `FoldRight` (`disjoint` and `element`
  at `want k kind t built`). v1 refuses all seven on the branch's `Dict`, so the merge
  is not green and was not pushed.
