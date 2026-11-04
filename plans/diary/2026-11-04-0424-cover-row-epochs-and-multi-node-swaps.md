## 2026-11-04 04:24 CET — Cover row epochs and multi-node swaps

**What I did**

Added real-producer browser fixtures for the full keyed/positional/Show operation set, item/environment/Show epochs, and the minimal two-row multi-node swap in #1833. The epoch fixture uses concrete Int keys and proves uncontrolled item and Show inputs survive type-identity changes. The ABI driver now checks Int-to-Float key identity changes with identical raw numbers, old-callback disposal, and unchanged retained-site data.

**What I learned**

The stronger ABI matrix passes 5,856 steps in each output mode; 2,896 single-node DOM and mutation traces match legacy. The operation and epoch browser fixtures pass development and release in happy-dom. MultiNodeKeyedSwap deliberately fails on the unwired legacy producer in both output modes and both happy-dom and Chrome; its correct transcript remains pinned for the typed integration. Generic source keys remain refused by key_not_primitive, so defensive key mismatch is ABI-only coverage. Final browser verification, hashes, gates and report 29 performance measurements await the shared producer wiring.
