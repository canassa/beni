## 2026-11-23 23:44 CET — browser-inline: keys through a wide constructor take their message

**What I did**

- #2640 (part of #966). On `browser-inline`, a key's handler gets only its leaf constructor's
  fields. When the key's path passes a constructor of two or more fields, a record field or a
  tuple component (`Progressed#1 · Sending`, `Record · Just`), the other fields were lost. So an
  arm that read them was refused: "reads its message, or a part of it, whole". 13 `browser/tea`
  pages stopped there.
- Such a key now takes the whole message (`Program.Key.message`, interface 1.35). Emit decides
  this from the key's steps (`keyTakesMessage`). The dispatcher and the event messages hand the
  key the message. The arm reads every part from the message along the key's path, so nothing
  is rebuilt. Off the leaf path, a pattern variable binds its field from the message, so the
  arm stays specialised.
- The pages still differ from browser-tea in order. `SyncCommandOrder` runs bodies in the
  dispatch, and `NavigatePush` hears the URL change before the push's answer. Their headers
  name the difference.
- `ListenerOrder` builds, but I did not copy its page: its `flush` step needs a runtime export
  that inline does not have. `ConcurrentJobs` and `UrlAddress` now stop at the `*` refusal.
- `ArmWideWrapper` builds now. I moved it from `build/bad/inline/` to `browser/inline/`, and it
  now shows the `Int` it reads. New pages: `MessageWhole` (wide constructor, three levels, a
  record, a tuple, a default step, a command's message, a message the model holds),
  `MessageRecordClosure` and `MessageDeepRecordClosure`. New release golden:
  `emit/release/inline/MessageWhole`.
- Sweep (tea + dom pages that build on inline, one script, same master): 167 before, 178 after.
- Runtime bytes: 0. No file under `platforms/browser-inline/` except the interface target, and
  `Inline.beni` did not change.

**What I learned**

- The adversarial reviewer broke the first version. A closure in the arm that read a field of
  an unbound message part had its eager read hoisted (§31.6). `hoistValue` then wrote that read
  by the local's name, which no handler declares: a `ReferenceError` in dev and `undefined` in
  release. This was not reachable before, because record paths were refused. Fix: a held holder
  is read through `heldValue`.
- I found a defect on master: #2642. `--release` drops a helper's in-place write in an arm that
  returns `( said model x, Cmd.perform … )`. The optimiser drops the property of a single-use
  result object that only `.b` is read from. The development build is correct.
- `-Dcorpus` runs that end in `OwnershipV2Differs` stop before they drive the page. A copied
  page's transcript is checked only after its `ownership-v2-known.txt` lines are in place.
