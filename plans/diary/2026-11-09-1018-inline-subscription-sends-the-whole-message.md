## 2026-11-09 10:18 CET — browser-inline: a subscription sends the whole message to a key that takes it

**What I did**

- Reproduced #2258 on master. The development build of `update (Got s) model` with a
  subscription showed `"undefined"`. Release was right, because release unboxes a
  constructor of one field.
- Found the cause. The write-set pass resolves the tagger to a key with no step, or with a
  default step last. That key's handler takes the message itself, as an event's handler
  does. The subscription mount sent it the bare value.
- Added `Declaration.whole` in the write-set pass and `Program.Subscription.whole` in the
  markup interface (version 1.25). `inline` now sends `programSubscriptionMessage(j, v)` to
  such a key. Amended `browser-inline.md` §3 and `boundary.md` §9.4.6.
- Added two fixtures: `browser/inline/UpdateParamPattern` and
  `browser/inline/SubscriptionDefaultArm`. Both fail without the fix and pass with it.

**What I learned**

- `browser/inline/DefaultTagger` had the same defect, but its `_` arm does not read the
  message, so the fixture could not see it.
- A record or a tuple pattern cannot reach a subscription's key: a tagger must give a
  constructor of the message type.
