# Guarded arms and the occurrence-fact spike

Management continues from Codex on the owner's Mac, with native Codex implementers editing and running on dagon through SSH. No remote AI sessions are started. Lean remains paused.

## Owner decisions

For #459, the owner approved amending browser-inline §8.2: only expressions proven pure and total may be evaluated eagerly. Everything else runs in the selected arm, including Debug.log, Debug.crash, foreign calls and partial operations. Arm entry computes guarded values from the current model after hidden updates; there is no persistent memo. Helper-argument effects preserve source order, including when an argument throws. Red-first fixtures must prove that a hidden arm never logs, revealing it logs once with the current value, and a throw in a hidden arm does not throw. The two `--lists none` size workloads, unique-components and big-component, must remain byte-identical, measured before and after. The size bars are unchanged.

For #456, the owner approved a design spike only. Production changes wait for the proposed spec and measured costs. The spike must first explain whether #379's level marker can carry the occurrence fact and use it if it can; otherwise it must explain why. There is to be one precision mechanism, not two. The owner explicitly corrected the earlier question's reference to existing limits: the checker has no contractual caps; caps are defects, and no depth or count cap may be added. Both aliasing twins must be refused, while ConstructorDiscardedAlias, ValuePath and EntryInvariantCommand remain accepted. A differential over the full corpus must show zero other changed verdicts. Measure checker instructions on core against the unchanged budget, and state the invariant precisely enough for later Lean work without touching the paused proofs.

Routine fixes and golden maintenance remain delegated to the manager; language, spec and important design changes return to the owner.

## Merged and running

#460, the clean linear replacement for #441, merged as a5a77f834 after full reference-host gates, CI and GitHub review. Original #441 is closed. The review's Listen.on debt question was answered with existing issue #440. #461 replaces #454 and #462 replaces #409; both passed reference-host gates and have GitHub review requests. The originals remain open until their replacements merge.

`view_helpers` owns #459 in beni-view-helpers. #436 stays blocked until selected-arm semantics, fixtures and measurements are complete. `ownership_soundness` owns the isolated #456 spike in beni-occurrence-spike; #447's green preservation checkpoint c9712b484 remains blocked on soundness. The unfinished #448 master merge is preserved in beni-codex-crosscheck and has been released by the view agent. `send_demands` owns #449's retirement cleanup and the size-run diagnosis. Full suites remain serialized with the shared gate lock.

## Measurement state

The pinned research clone at e574cdcfe91eeeca86c2b654b65156281744643b reproduced tea-inline's fits: unique-components 2,025 + 146.1 B/widget; big-component 1,552 + 71.8 B/widget. The frozen pre-#459 compiler is `/tmp/beni-codex-pre459/beni` from #436 head 2d298e446. Its first unique-components run stopped at N=64 without a compiler diagnostic. A raw single-build diagnosis showed rapid memory growth; the cause and termination are still under investigation. This is not a completed fit or byte-identity result. No compiler cap or benchmark change is authorized as a workaround.

The last complete beni figures remain the handoff measurements, not new results: unique-components 2,328 + 274.4 against tea 2,025 + 146.1, and big-component 2,068 + 92.7 against tea 1,552 + 71.8. The final S1 judgement still awaits records and the shared validator; report the compiler-constant validation line beside each fit.
