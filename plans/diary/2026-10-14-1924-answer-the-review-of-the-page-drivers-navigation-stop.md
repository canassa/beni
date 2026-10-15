## 2026-10-14 19:24 CEST — answer the review of the page driver's navigation stop

**What I did**

Asked `@claude` for a review of PR #103 (the automatic one posts nothing on
a draft) and answered its six findings. Added a `reload` to
`browser/direct/NavigateCommands` and a new `browser/tea/NavigateFragment`
(a fragment load stays, the bare address is stopped); both fail with
master's driver. `fuzzSend` now names a page that left its document.
Declined two findings with evidence: Chromium 153 marks
`Page.resetNavigationHistory` neither experimental nor deprecated, and no
download navigation is reachable past the click step.

**What I learned**

For a fragment navigation the page makes, Chrome fires `popstate` and
happy-dom does not, so a follower of the address hears it only in Chrome.
It is older than this work; the README lists it.
