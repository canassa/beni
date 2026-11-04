## 2026-11-04 11:54 CET — hostfree ownership, repkeys and realm golden attribution

**What I did.** Lane `wd-own-attr` (Claude agent), on `hostfree-inherited`. Grouped the
45 failing `ownership/` goldens by verdict line, not by text: 38 changed only `summary`
lines, 7 changed verdicts. Bisected each verdict change with one-shot builds on dagon.
`e452fa7dfa` (typed HTTP waits) moved `Rejection.raise` in for `Js.throw`; the native row
had no result word, so its `⊤` sat at the root of `Http.exchange`'s answer and every
`Cmd.task` / `Http.send` tagger lost its need demand (Conduit 0 → 22 rejected, HttpAnswer,
HttpAnswerEdited, HttpSendBody). The row is now `escaped Rejection → fresh a`, as
`Js.throw`'s, and those verdicts are back to master's. `74ccc0f694` (Hosted jobs, Laters
and keys through `Js.Any`) causes the other two: WordsBrowser's dropped keyed command now
escapes its key list (a lost in-place write), and RecordCapture accepts an in-place write of
`model.form` while a command holds the old `model` whole. The second is unsound under
`--ownership-everywhere`; both are left red for a decision. RealmHostedHost now runs its
typed job, which keeps the fixture's premise; the golden is unchanged. Blessed the
summary-only ownership goldens and the six repkeys goldens.

**What I learned.** A diverging native without a result word poisons every path of every
caller's answer, because `⊤` at the root covers each constructor path. An entry escape
through `Any.pack`'s `escaped` word escapes a captured record's object alone (§31.8), where
"a command holds it" held its nested records too. The watcher does not survive a checkout
that adds or removes files; one-shot `zig build` at about 25 s per commit was the faster
bisect.
