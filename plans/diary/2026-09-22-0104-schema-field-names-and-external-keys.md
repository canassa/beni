## 2026-09-22 01:04 CEST — schema field names and external keys

**What I did**

- Recorded the owner's agreement that `Type` and `Encoded` retain declared Beni
  field names while `as` maps external keys. Updated the queue and report 32's
  supersession notice. Documentation only; no implementation changed.

**What I learned**

- Arbitrary external keys need no quoted-field language feature: `userId` remains
  the typed field on both sides even when the JSON key is `user-id`. This rule
  applies to all renames, not just keys that are invalid Beni identifiers.
