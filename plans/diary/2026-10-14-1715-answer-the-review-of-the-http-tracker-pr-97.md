## 2026-10-14 17:15 CEST — answer the review of the Http tracker (PR #97)

**What I did**

Answered the adversarial review of PR #97 and Cesar's four decisions. The
spec (`boundary.md` §9.8.19) now says that only `--release` drops the
tracked arm of an untracked `send`: a development page grows by about
6.5 kB raw (`ValueCommands` 80 968 → 87 522). It states that a tracked
command starts after the untracked commands of its batch, lists the coarse
`Sending` and the double `Sending 0/0` of an empty body as departures, and
records two decisions of Cesar: one tracker table for the page, and no
`Http.cancel`. Issue #100 asks for `XMLHttpRequest` on a tracked request
and reopens H4. New tests: `HttpTrack` (`#again`, `#batch`, `#missing`),
`HttpTrackInit` (from `init`, an empty body, a timeout), the tracked
credentials in `HttpRequestShape`, and a new corpus kind,
`emit/release/tea/`, with two whole-file release goldens. The tracked arm
with `same-origin` fails `HttpRequestShape`. Gates: exit 0 on the pushed
base.

**What I learned**

`origin/master` (`b03a8d369`, and `748745c01` before the ownership merge)
fails `zig build gates` on this Linux x86-64 machine:
`browser/direct/HttpJson` costs 4 798 M instructions and `HttpJsonBody`
4 942 M, over the 4 300 M budget, with Node skipped. The browser-direct
work measured its gates on macOS. My change moves them by +12 M. I did not
push the merge of master, because the gates must be green before a push;
the question is in the report. A `track` that has left hears nothing for
two reasons: the table deletes its listener, and a closed relay drops the
value. So removing the table's delete fails no transcript; it only keeps
memory. A size claim about a platform module needs a build named: the
development build keeps every arm that reachability sees.
