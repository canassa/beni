## 2026-11-13 00:55 CET — ownership v3 blind test, reader A

**What I did.** A blind soundness test of `src/own3/` at `ca2fc63410`, from the code and the kernel text
only. Wrote `bench/ownership-sweeps/blind4a.mjs` (160 programs), six minimal faults with safe twins in
`blind4a-faults/`, and research report 118. `run.mjs` now builds a program for the platform its
`PLATFORM` file names and drives one with a `steps` file under happy-dom.

**What I learned.** Six faults, all where a negative fact was assumed: the entry rule (an escaped new
model list, one new list at two model places, a model location that `update` lets escape, a message
that holds a top-level list or is sent twice), a fold callback's escaped new answer read as its own,
and a derived `eq`/`compare` that calls a part's writing method unseen. v1 shares the derived-method
fault and some fold variants; v2 shares two entry faults. The page test platform runs entry programs
under Node, which made the entry rule testable without a browser.
