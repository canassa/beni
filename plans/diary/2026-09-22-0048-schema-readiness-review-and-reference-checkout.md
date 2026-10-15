## 2026-09-22 00:48 CEST — schema readiness review and reference checkout

**What I did**

- Read report 32 revision 2, its predecessor and owner decisions, and cross-checked
  the relevant language, frontend, checker, backend, boundary, static-dispatch,
  incrementality, effects and browser contracts. This was a design review, not an
  implementation session; existing compiler and test edits were left alone.
- At the owner's request, ran `git submodule update --init --recursive --jobs 8`.
  All nine reference submodules checked out their recorded commits. Read the pinned
  Effect schema guide, its flip/projection implementation and arbitrary-generation
  limitations after checkout.
- Checked JSON numeric loss with Node: `9007199254740991.1` parses to the safe
  integer `9007199254740991`; `1e400` parses to Infinity; NaN stringifies as null.
  No compiler tests or schema performance measurements were run.

**What I learned**

- The owner model is settled, but report 32 is not implementation-ready. Unrestricted
  flipping contradicts a fallible decoder plus an infallible encoder. `typeOnly`
  also needs program-side representation information the proposed Schema does not
  retain. Effect retains both sides and allows failure in either direction.
- Generic selection by `a.schema` loses structural record aliases' schema identity,
  cannot select two wire forms for the same program type, and needs a namespace
  ownership rule. Generic convenience signatures also encounter the existing rule
  that every constraint variable must occur in the annotated type.
- Arbitrary wire keys cannot all become ordinary record field names; flattened
  union records reject legitimate variants sharing a key at different types.
  Recursive schemas with transformed fields need an encoded recursive type beyond
  the identity example. Opaque schemas need an explicit account of their private
  representation and constructor.
- The proposed reader representation does not thread options/path/depth; the
  erased Variant omits structural readers/writers needed by choice. Node loses
  recursive targets, literal values and structured checks. Unconditionally
  successful sampling cannot handle an always-false check. These need executable
  library proofs, not just signatures that type-check.
- Lowering is per-file and cannot inspect an imported conversion's type as claimed.
  Schema/Json ownership must also avoid an import cycle. JSON precision must be
  addressed before token text is lost, and total writing needs rules for values
  admitted by Int/Float but refused by the reader or JSON.
- Recommended next work: settle encoding failure, generic schema selection,
  namespace ownership and wire-presence/union representation; prove a small
  library prototype with adversarial cases; measure browser behavior; then update
  normative contracts and define acceptance fixtures before production slices.
