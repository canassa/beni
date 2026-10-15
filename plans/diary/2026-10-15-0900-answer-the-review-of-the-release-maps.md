## 2026-10-15 09:00 CEST — answer the review of the release maps

**What I did**

The automatic review of PR #117 posted nothing, so I asked `@claude` for
a pass. It found no blocking defect. I added a needle that pins the bytes
before the hoisted file's first stretch as unmapped, a note that only the
map marks read a `JsIr` position, and a clearer help line. I declined a
`write`/`writeJoined` equality test, because one wraps the other, and an
assert on the pending function name, because a legal path sets it.

**What I learned**

A file that the build declines to hoist is imported before the first
stretch, so it is unmapped by the same rule as the line start. The
automatic review workflow ran three turns and posted no comment; an
`@claude` comment gave the real review.
