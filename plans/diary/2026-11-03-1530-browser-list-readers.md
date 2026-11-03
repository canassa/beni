## 2026-11-03 15:30 CET — Browser readers accept every List representation

**What I did**

Extracted the existing trie reader correction as an independent fix for #1786.
Rt.elements handles plain arrays, a trie's cached $plain reader, and suffix
views. Browser.programs walks its public List through List.foldl and retains
native iteration only for each program's internal mount array. Audited the
remaining Rt and Browser readers and the inline runtime: no other b/o List
materializer remains; inline's List traversals already use List operations.

Added gated happy-dom pages for a 40-element List.push trie rendered through
both keyed and positional For, its suffix view and a plain array; a second
page flattens a trie-backed list of program groups. Both fixtures failed twice
on exact workers-hostfree d0bf054166. Direct happy-dom runs also failed twice
in each of dev and release. The fixed corpus passed twice in both modes and
recorded its successful run hashes.

Full gates ran twice on the exact base and twice with the fix. Both candidate
runs added zero failing tests or fixtures; both also fixed the existing Tea
ForForms page failure. Full gates remain red on inherited failures. Logs and
the List reader audit are under ~/worktree-evidence/wd-hf-dom/list-forms/ on
dagon. Heavy work was locked; the initial benchmark crash reproduced after
preserving local caches and rebuilding clean, so it is a software defect.

**What I learned**

A foreign renderer reader must implement the complete current List protocol.
The trie was restored upstream while these two readers still assumed that
every non-array List had a view's b/o fields. That crashes ordinary large
pages, including Create 1000, before they can provide benchmark evidence.
