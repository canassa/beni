## 2026-10-18 13:31 CEST — the owner answers question 3, validation

**What I did**

I recorded the owner's answer to question 3 of `2026-10-18-1313-s1-fit-and-where-the-bytes-go.md`.

- **Yes to the shared validator.** A reader whose error is discarded is a type test, not a decoder. So a compact description run by one shared validator is the same operation, and it is allowed. It is a second lowering for a different case, not a change to `schema.md`'s decision. It is specified in `schema.md` as an amendment beside §6 before it is built (rule 1).
- **The sequence.** The three fixes come first, one attempt each and measured, then the shared validator. Its runtime counts in the fixed cost, and both lowerings are reported.
- **The order of S1's work:**
  1. #352's cause report;
  2. binding pieces;
  3. validation;
  4. per-path passes.

  Binding pieces come before validation because, without validation, beni-inline is at 244 B per widget against tea-inline's 146 all in. The 115 B of binding pieces is the platform's own output.
- **The single-constructor follow-through is approved.**

**What I learned**

- **Read the breakdown for what the platform owns.** I led with validation because it was the largest line. The owner read the same table as "the platform's own output is 1.7× before any validation".
