## 2026-11-05 00:19 CET — V2 ownership in the embedded pack

**What I did**

Specified pack version 4 and separate versioned v2 ownership rows (#1854).
The maker computes them beside v1 while solved types are alive; ordinary
entries, budgets and the module-wide publication rule stay unchanged.
The fractionSent regression fails on base and passes through the pack,
checking only Main and installing 85 embedded modules. Maker runs with one
and eight CPUs produced identical bytes. The measured extra rows add
292,628 bytes; cold probe medians were 127.7 ms base and 124.5 ms fixed.

Audited the recovered unchecked inventories individually: 57 declarations
become checked, and other first-unsupported markers advance beyond calls
whose v2 summaries are now available. The only new unchecked declaration is
ClickModifiers.prevented, kept separate for #1925. Three managed inventories
record the manager-accepted interim-trie cost: removeLeaf exceeds its budget,
the module rule withholds List's classes, and callers cannot use List.drop.
That debt is tied to ownership-checker.md §30, O0–O6.

**What I learned**

The old v2 run disabled the disk cache but still installed v1-only pack
entries. A separate row restores summaries without runtime source rechecking.
Master already left ClickModifiers' tuple callback unchecked; the typed
Event migration removed crossing, making its opaque-event caller account
for that unsupported callee. A same-compiler crossing-only probe reproduces
that change; #1925 records the independent callback-analysis work.
