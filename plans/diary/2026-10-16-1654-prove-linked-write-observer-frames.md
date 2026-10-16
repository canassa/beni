## 2026-10-16 16:54 CEST — Prove linked-write observer frames

**What I did**

I added conditional heap frames for the real linked-write operations.
The proof confines every changed address to the receiver's initial undirected link component.
Its corollaries preserve complete independent observations, including the whole permanent observer list.
The example changes both a source and its view while an independent registered observer retains `[7]`.
I kept the three general proof obligations and the audit checks unchanged.
I also corrected stale coverage exclusions for views, the fixed recursive Chain type, and generator v6.

**What I learned**

The conditional frame needs neither empty links nor empty observers.
It requires runtime success and complete footprints outside the initial link component.
It establishes no checker permission or general execution-success theorem.
The accepted-caller proof still needs to derive footprint separation from actual demand checks.
