## 2026-10-20 04:03 CEST — a member read reads the field summary

**What I did.** Issue #498: in `src/js/Spec.zig`'s `Pts`, a load cell of a name's property
takes two copy edges from the name's field summary (its var of the property and its `any`) in
place of two per site. The summary gained per-property marks (`Mark`: read, `lacks`, the cell),
`escaped`, `whole`, its folded `sites` and its feeding `preds`; a mark reaches the folded
sites, the sites folded later and the feeding summaries by a worklist. Two unit tests, the corpus
case `emit/release/inline/MemberReadsWide` (5 124M instructions before, 3 445M after, golden
blessed by the base compiler), an *As built* note in `backend.md` §9. Gates green, run hashes
unchanged, every output byte-identical on the dashboards.

**What I learned.** Reading through the summary as it was made things worse: a summary joined
every field of every site, so a var read for one field of a 78-field record paid for all 78, and
the N=64 dashboard went from 6.3 s to 14.1 s. A summary must hold only what is asked of it — every
field when a spread reads it whole, else the fields a read marked (`demands`) — and then N=64 is
6.05 s and the no-`withDefault` build's edges per run fall 418 837 → 91 818. `foldSite` used to
mark every folded site `all_read`, which was right only while every summary came from a spread;
it is now the `whole` mark. Marking at fold time is earlier than the old per-evaluation linking,
so in another walk order a site can be marked before it escapes, and a spread then copies its
extra keys into a live target: the shuffled-order check now skips per-key `written` on a site
written under an unknown key (no fact reads it there). Summary vars had to be `uncapped`, or a
summary made for a read escaped sites a cell never escaped.
