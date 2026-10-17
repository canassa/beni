# Follow-up to the research 106 review

[Review](https://github.com/canassa/beni/pull/180#issuecomment-6201317594).
This records what changed and what the evidence does **not** establish.

1. **Runtime versus application code.** At mixed N32, the normalized rendering
   response is 11.82 kB TEA versus 7.29 kB local. Runtime alone is 3.51 versus
   1.79 kB; the app increment in that response is 8.31 versus 5.51 kB. This is
   reachable platform support versus a pure-sandbox prototype, not full platform
   parity. Cmd/Sub and async effects are not exercised. The review's claim that
   no disposal exists is incorrect: generated factories have `d()`, clear `live`,
   recursively dispose children and remove roots; switch/list blocks call it.
   The retained 22 detached-callback probes exercise that path. Generated Main
   uses `Html.map`; instance routing is recognized through generator construction.

2. **Repeated instances versus new features.** Agreed. The ten-family catalogue
   varies instances but is finite. Its slopes cannot establish the cost or ranking
   of arbitrary new features. The extended 512 kB campaign deliberately retains
   that catalogue unchanged, discloses repetition, and measures every plotted
   point. It adds scale, not a claim that each instance is a new algorithm.

3. **Root admission.** Agreed. `audit.mjs` checks byte equality with the generator
   and a 19-primitive pure-call allowlist. Cross-component separation comes from
   construction. It is not a general whole-program ownership checker. The
   source-derived read/write and operation witnesses are separate from that
   restricted precondition.

4. **Aliasing.** Fixed: `$model` intersects every field, and a read of a candidate
   array by another field's RHS anywhere in update conservatively disables the
   ownership optimization for that array. Fresh initialization alone is not
   sufficient. The whole-model helper and cross-arm snapshot fixtures prove
   real before-fix divergences and correct copying fallback after the change.

5. **Event payload captures.** The asserted mount-time evaluation was not present.
   `val` in `dom-compiler.mjs` is generated expression text, inserted *inside* the
   event callback. Factory `set()` updates the variables it reads. The new direct
   model-payload, helper-callback and pattern-helper fixtures exercise changing
   values. The direct model-payload fixture matches TEA both before and after.

6. **Higher-order and pattern dependencies.** Fixed a related real omission:
   non-top-level calls now include the callee closure's dependencies as well as
   argument dependencies. Case patterns explicitly inherit scrutinee dependencies.
   The callback-helper fixture diverges before the fix in A/B and matches after.
   The pattern-helper fixture matches both; it is additional coverage, not a
   claimed before-fix failure. All five fixtures are outside the root equality
   guard and are deliberately passed to the research lowerer to challenge it.
   They do not turn its limited scalar emitter into an arbitrary beni compiler.

7. **Accounting sensitivity.** Excluded Owned_map/filter/append/reverse cost
   **137 B brotli standalone**. In mixed-17-32, unmapped spans are 1.25% of raw TEA,
   0.54% of direct and ≤0.05% of the other full bundles. Classifying every gap as
   excluded versus rendering changes the brotli account by at most 164 B in that
   sample and does not change rank. This is a sensitivity diagnostic, not a
   confidence interval. Details: `results/sensitivity.json`.

8. **Timing.** The user subsequently requested bundle size only. The HTML report
   and stress campaign omit timing entirely. Existing timing artifacts remain
   historical evidence; no more interaction timing is run. Their reversal result
   must not be attributed specifically to local routing: all four prototypes use
   the same reconciler. Vanilla is a concrete comparator, not a speed ceiling.

9. **Adversarial evidence and unchanged original prices.** Five additional actual
   beni programs compile for both browser platforms. All **30 current outputs**
   (TEA/direct/A/B/C/D) match TEA's exercised observations in Chrome; **7 of 20 old
   prototype outputs diverge**. The remaining old outputs matching these DOM
   observations does not establish that their internal aliasing was sound.
   `results/adversarial.json` retains each result, bundle/transcript hash and
   before/after ownership witness. `check-generation.mjs` proves that all **792**
   original candidate sources are unchanged byte-for-byte against the unminified
   sources retained in their measured maps. The analysis fix does not invalidate
   those prices. No repository gates or suites were run.
