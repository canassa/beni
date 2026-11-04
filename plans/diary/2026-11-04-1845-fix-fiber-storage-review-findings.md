## 2026-11-04 18:45 CET — Fix fiber storage review findings

**What I did**

Guarded empty FIFO shifts before capacity reads, preserved stopped scheduler
state through lazy hook registration, restored inert template handling and
skipped diagnosed modules in the allocation proof. Moved and scoped the
backend amendment. Added fail-first crash, shutdown and template fixtures;
filed accepted summary precision debt as #1876 and linked it from #1873.

**What I learned**

An uninitialized native slot is undefined, which is a valid Opt payload;
testing the sentinel after reading cannot prove a queue was nonempty.
Shutdown's bridge state must reach the scheduler before any work can drain.
The required guards add bytes; after one unsuccessful handler factoring,
the manager authorized only the measured S1/S5 cap adjustments. No other
budget moved, and no new full gate was run. Targeted checks cover each fix.
