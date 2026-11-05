## 2026-11-05 01:58 CET — Platform FIFO queues

**What I did**

Completed the platform-only slice of #1857 on 41d030a2f9. Socket unread text,
worker stream buffers, worker listener cleanup, the bounded wire walk and
Cloudflare trampoline jobs use the existing core Fifo. The walk uses front
insertion/removal to preserve its old depth-first order. Cloudflare replaces
the active queue before invoking its batch, so callbacks enqueue the next
batch. Cancellation-token queues remain Chain. Protected DOM/inline/fiber
files are unchanged.

New socket/stream fixtures exercise queued order, ring wrap, overflow, reuse
and draining before close/End. Their transcripts match the captured base
compiler. The Workers fixture proves creation-order jobs followed by their
yielded continuations in the same order. Targeted checks and the full Workers
suite pass. Full gates were run once; shared a02b9c83cb evidence was reused.
Eight extra emit mismatches are already present byte-for-byte on 41d (only
#1935 lies between those bases). A V8 TailModConsBranches crash reruns green
on both compilers and their output trees are identical. No queue-attributed
failure and no emit golden blessed.

Size Q11: corpus +36 B in two already-red WorkerEventsLeaf files; all fourteen
standard page lines unchanged; socket fixture +23, stream +13, Cloudflare
fixture -95. The emitted buffered socket/stream paths used Chain.append,
allocating one entry cell and one removal token per enqueue, then one Just
shell per successful dequeue. Fifo removes those three per-message queue
allocations for String/Int payloads; capacity-array setup/growth is occasional,
and generic private Opt escapes remain unchanged. This is a source allocation
count, not a V8 heap-byte measurement. Evidence: ~/worktree-evidence/wd-size2/queues/.

**What I learned**

A FIFO trades small local code growth for fewer per-message objects when a
program still needs Chain for cancellable registrations. Standard page size
cannot show that trade when the changed modules are unreachable; measure the
affected socket, stream and worker programs as well.
