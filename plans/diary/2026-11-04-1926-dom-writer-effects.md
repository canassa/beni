# DOM delegate writer effects

The typed DOM delegate passed a protocol whose `turn` field honestly calls its
callback once. Ownership treated that call itself as a possible list write,
even when all supplied callbacks had known read-only bodies. The five-line
reduction also refused before the deep-escape merge.

Part of #1825: effect-only callback argument facts retain direct writes,
unknown effects and dependencies on enclosing callback parameters or record
slots. Only conditional writer-need resolution reads them. Unknown, missing,
cyclic and bounded-out proofs keep refusing. Summary block 39, cache entry 15
and interface 24 invalidate old bytes.

The complete ownership corpus comparison changed exactly three sites: the
reduced delegate, a read-only supplied callback and its imported equivalent.
Each loses a rejected need because that need is discharged. No accepted site
becomes pending or rejected; the callback writing the retained list and the
unknown writer remain refused. The imported cache test fails before the fix
and passes after it, for both acceptance and refusal. Codec round-trip and
corruption checks pass. All ten cache files and interface hashes match byte
for byte at jobs 1 and 8. The three browser platform ownership checks pass.

Evidence: `~/worktree-evidence/wd-dom-wire/ownership-turn/report.md` and
`verdict-changes.json` on dagon. Existing stale ownership reports are preserved,
rather than refreshed as part of this precision fix.
