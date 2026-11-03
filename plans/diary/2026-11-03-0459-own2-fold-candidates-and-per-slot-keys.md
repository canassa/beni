## 2026-11-03 04:59 CET — own2: fold candidates and per-slot keys

**What I did**

- Precision lane 9 on `own2-precision-6` (#1685): four commits, pushed, no PR.
- Formatted the four sanitiser fixtures that failed `beni-fmt-check`. Only two known rows of
  `SanitiserEmptyValue` sat on moved lines.
- #1713 (b)/(c): the distinct check now reads the entries made from one non-deep occurrence at a path
  of fields and indices as candidates of one object, and does not compare them. A repeated
  candidate, or apart entry, is not made twice. 8 positions accepted; `groupOrder` is off its limit.
  Spec §2.9.3, *candidates of one object*.
- #1756: a call's or a supply's key now reads an open arrival's object at its own slot (deep only at a
  type variable's or opaque slot), and a known code's deep answer carries its subtree's slots. Record
  update callbacks pass through any label, as tuples did. 14 positions accepted; 3 refusals moved to
  the caller, where the fixtures want them. Spec §2.10 *Read-off*.
- #1713 (a)/(d), the `Fed.at` patch: it now fits (`build` 56 175 of 65 536), but it moves one refusal
  (BallMachine `Physics` 296:23, which v1 accepts) to the caller and I could not prove it unsound.
  Held back; rebased copy in the lane's scratch.
- Four fixtures (`run/SanitiserFoldAlternatives`, `…Shared`, `run/SanitiserRecordCallback`,
  `…Shared`), 30 adversarial probes. Status on #1713, #1756, #1714, #1685.

**What I learned**

- `Arrival.deep` means two things. On an open node it is a subtree that holds place for place. On a
  plain node (`aliased`'s every-slot row) it means "any object of it may be here". The tree's `Hit.open`
  tells them apart. A reader that ignores this either over-reads (the old key reads) or loses holds.
- The old deep key read hid a second gap: a known code's answer leaf named only its top slot, and was
  deep only because the key read was. Any precision change to a shared reader must look for the
  places that leaned on its slack.
- A precision gain in a callee can move a refusal to its callers. Lane 8 saw it too. The bar's
  "a2r against the previous step" catches it. To prove such a refusal needed, the probe has to keep
  the callee's write in place, and the reduced one I wrote did not.
- An experiment's number is not the committed rule's: the spec quoted 31 872 for `build` from the
  experiment, and the commit gives 53 715. Re-measure the commit itself.
