## 2026-11-06 14:50 CET — A need waits for complete contracts

**What I did.** Closed the comparison gaps on #2134: `Needs.compared` reads the draft after the fixed point, and any write accepted on a ground but `fresh` is refused. `Q30` was `callback_param`, on a quiet line, so the old test for `param` passed over it. A need a fresh answer meets carries `fresh_answer`, so `Q32` stays accepted. §2.11.3 now states the three assumptions of its soundness argument and what breaks them. The PR is a draft.

**What I learned.** A need turns a refusal into an acceptance, so it inherits every shortness in the contracts it reads, and guarding those one by one in this PR was the wrong order. My last entry called the discharge check a general rule. It covers one shape of one cause. The order is: rows, the fold decision, then this.
