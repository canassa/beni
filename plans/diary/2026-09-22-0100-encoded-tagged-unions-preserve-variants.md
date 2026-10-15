## 2026-09-22 01:00 CEST — encoded tagged unions preserve variants

**What I did**

- Recorded the owner's acceptance of custom unions for a tagged schema's encoded
  side, superseding report 32's flattened-record recommendation. Recorded the
  accepted encoded/program constructor paths in the queue and updated the report's
  supersession notice. Documentation only; no implementation changed.

**What I learned**

- `Message.Encoded.Count` and `Message.Count` keep each side's payload types tied
  to its variant while the codec preserves the declared JSON shape. Variants can
  therefore share a wire key with different types without renaming that key.
