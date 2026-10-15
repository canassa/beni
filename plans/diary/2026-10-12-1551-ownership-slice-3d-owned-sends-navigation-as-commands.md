## 2026-10-12 15:51 CEST — ownership slice 3d: owned sends, navigation as commands

**What I did.** Specified and built slice 3d (`ownership-checker.md` §23, `boundary.md` §9.8.17). A send
is now a demand on every cell of its payload — a write with a deep flag (`S` in a summary) — checked where
the send is written, so a sender that reads what it sent, or sends a list the model still holds, is rejected
at the send. Send positions are asserted rows of `browser`'s `Hosted` (`job`, `later`, `tap`, `hook`,
the `map…` taggers, `runJob`/`callJob`); `fun(j).send` propagates them to `Cmd.perform` and every
command over it; a lambda written at a send position has its parameter marked a send before its body is
walked; constructors handed as taggers have a class; the entry's `msg` is owned and `payload` is the
view-event rule alone. `Browser.Navigation`'s Elm names are commands with a refusal tagger; the direct
forms are `push`, `replace`, `goBack`, `goForward`, `loadPage`, `reloadPage`. Migrated Conduit, the
routing pages and `ApiAndRoutes`; research 80 measures it.

**What I learned.** Owned sends cleared no entry line on the corpus or the applications: every remaining
`payload` is a view event, because views hold the model's lists in markup. The rejections moved to the
senders, and the big new cause is the HTTP answer — a decoder stored in `Expect` over text from JavaScript
— which Change 5 plus a class for `Expect`'s callback would clear. Two checker gaps surfaced and are
fixed: a lambda's own later read of a list it captured was not a use (only the enclosing frame's were), and
a once closure's decision preferred `pending` over a known exact holder. Carrying the view's messages round
the entry fixpoint doubled the pass on Conduit for no verdict; marking the stored payload instead costs a
fifth. The worktree sandbox refuses shell loops and `$VAR` expansions: write small node scripts instead.
