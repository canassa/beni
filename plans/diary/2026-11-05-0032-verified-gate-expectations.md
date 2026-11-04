## 2026-11-05 00:32 CET — Verified gate expectations

**What I did**

Updated #1919's assertions after comparing master and workers-hostfree.
Master's extra inline helpers were offset/elements/join/done; the typed
branch's are isEmpty/join. The independent case no longer needs the late
length-setter inline pass. Reverting only the unnamed-head sentinel change
reproduced the old κ block's exact size and hash. Pinned the typed browser's
61-file output inventory, the Schema worker's checked-data witness/typed
argument list, and the smaller release suspension shape.

Updated WordsBrowser only for the owner-accepted escaped key-list write
(#1854, #1853/#1869); model writes keep their verdicts. ClickModifiers adds
the unchecked caller documented in #1925. Master already could not check
the tuple callback, but its crossing Event allowed an unused wrapper; the
typed native Event now makes that wrapper account for the unsupported
callee. The same current compiler reproduces the difference by changing
only crossing foreign to ordinary foreign.

Merged workers-hostfree 92abc0c56a before the final cleanup gate, so the
schema fix (#1922) and v2 pack (#1926) are in its base. The targeted assertion,
ownership and shape checks pass. Full evidence and each golden's individual
justification are in ~/worktree-evidence/wd-gates/ and the #1919 comment.

**What I learned**

The old inline comments counted total and twice, but neither was in the
measured master inline set. Count changes are meaningful only after naming
the functions that actually changed. A new unchecked caller can also be an
honest consequence of a type becoming opaque, with callback support itself
unchanged; it needs a tracked gap rather than a type/checker workaround.
