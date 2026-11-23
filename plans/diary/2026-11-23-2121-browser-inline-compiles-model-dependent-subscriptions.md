## 2026-11-23 21:21 CET — browser-inline compiles subscriptions that depend on the model

**What I did**

- #2632 (part of #966): `browser-inline` no longer refuses a program whose `subscriptions`
  reads the model. Spec first: a dated amendment at the end of `browser-inline.md` §3.
- The lowering (`inline.zig`) makes the program's live table at the mount (`Inline.liveSet`)
  and hands `Inline.settle` the set `subscriptions model` gives, at the mount and in each
  handler whose writes conflict with what `subscriptions` reads (`programSettles`, the write-set
  pass's subscription reads, which browser-direct used before it was retired). All of it was
  already in the interface; only the lowering and the runtime were missing.
- The runtime (`Inline.beni`) is `Tea.settle`'s diff over a sorted array keyed with
  `Hosted.compare`: stop what left at once, retap what stayed, start what arrived in the order of
  first declaration. A value goes through the taggers current when it is sent, one guarded send
  per tagger, re-checking that the key is live when applied. A listener is added in a microtask,
  so it never hears the event that made the set.
- `Emit.findLifts` no longer cuts the `subscriptions` field from reachability for a `.model` set.
  `Writes` answers `.model` for an application whose own set reads the model, which the lowering
  refuses (class 1): only the pass adds its navigation subscriptions.
- Tests: seven `browser/inline/Subscription*` pages; 13 `browser/tea` pages copied (each the
  same transcript, but for text-node shape); `emit/release/inline/SubscriptionsFixedSet` (bytes
  unchanged) and `SubscriptionsModelSet`; `build/bad/inline/ApplicationModelSubscriptions`.
  The old `build/bad/inline/ModelSubscriptions` is gone.
- Pages that build on inline: 153 → 166 of 357. Three of the 16 pages stop at other limits
  (`AdvanceSettlesEachTimer`, `HttpTrack`, `ListenerOrder`).

**What I learned**

- The adversarial reviewer found two real defects: a listener added inside the dispatch heard the
  native event still bubbling (a keydown that turns on a keydown subscription), and a throwing
  `start` left a row with a null remover that the defect path then called, which hid the
  program's error. Both fixed, each with a page.
- Inline stops a key in the dispatch that wrote the model, and tea once per render. So a body
  that sends a burst loses what follows the message that removed its key. Written as a difference
  in the amendment.
- Bytes (release, brotli 11): a listen-only page whose set depends on the model is 1 310 against
  638 for the same page with a fixed set (`browser-tea`: 3 809); `ClockStops` 2 958 against 2 167
  fixed (`browser-tea` 4 967). A fixed set is byte for byte as before.
- Open: `if True then … else Sub.none` is read as depending on the model (the pass's
  precision), so it pays for the diff.
