## 2026-11-08 03:25 CET — WebGPU checked operations: review fixes

**What I did.** Answered the review of #2255 on the merged branch. A checked operation's wait
now ends through a finaliser: cancelled, or interrupted before it waited, the operation is
done and an unexpected pop it had kept goes to the device's program instead of being lost;
`browser/gpu/CancelledCheckedDefect` releases one rejecting pop, cancels, and shows the crash
screen. Each pending pop holds the device's channel, so the sentinel ends once the loss is
reported and no pop is pending (`browser/gpu/CancelledChecked` counts it). A pop reaction's
throw is a defect, not an unhandled rejection. `checked` takes the call's own synchronous
classifier (`sync (⊤ → Result Error V)`); `createSampler`'s has nothing to classify.

**What I learned.** The ownership checker v2 now refuses `[ … ] ++ f x` where the literal is
written in place, which the old fixtures did; naming the parts and using `List.concat` reads
the same. The merge of the two branches is where the engine had to be reassembled: the S1a
channel model replaced the per-device sentinel the S1b code assumed.
