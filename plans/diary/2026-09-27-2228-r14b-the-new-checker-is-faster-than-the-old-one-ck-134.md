## 2026-09-27 — R14b: the new checker is faster than the old one (CK-134)

**What I did**

- CK-134 closed: the bench's check line is 0.76× `7427828` on `--dispatch` and 0.72× on plain
  (it was 1.10× / 1.06× at `881e23d`); whole-process user cycles 1.01× / 0.98×. The largest cost
  was invisible to user-cycle profiles: every module's type store mapped and unmapped its own
  pages, so page faults (R9's 3-variables-per-instruction reservation) dominated the wall-clock
  line. The store now lives in the worker's reset scratch arena. Also a stamped memo for
  imported instantiations, rank adjustment skipping roots an earlier walk already reached, and
  small inline fast paths — each measured on its own and as an ablation; nothing resting on a
  soundness argument. A differential over 56 365 output files was byte-identical to `881e23d`.
- Committed path-limited: the compare-bench agent's files are in the same tree.

**What I learned**

- Profile the metric the budget names. Every slice since R8c measured user cycles; the bench's
  wall-clock line was paying for page faults nobody's profile showed.
