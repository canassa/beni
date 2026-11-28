## 2026-11-15 19:12 CET — own3: precision on real programs

**What I did**

- Listed every v3 refusal in the real programs: the ledger's 32 real roots (36 refused lines), the
  corpus (345 refused programs) and `core/` (none). A compiler with the channel's refusal dropped
  built each refused corpus program in place: 236 printed another output, 109 the same. Grouped
  the 109 and the ledger's lines by cause (report 143 §2).
- Fixed three causes, each with a corpus fixture and a live twin, and a paragraph of the kernel:
  `escapeAnswer` asks each location of an escaping answer on its own (one set of 24 answers in work
  for all of them read Conduit's model as escaped through `updateWith`); a `send` asks nothing of
  the sender (the message is never `update`'s own, so its line guarded no write); an answer that holds
  no cell the holder handed on does not make an entry `twice` over aliased arguments.
- Made the scan of an answer's map read the other map once for the location asked (`AnswersAt`): the
  per-location queries made it the square of the layout's lookups.
- Wrote `answers-sends.mjs` (54 programs), ran every sweep, fault folder and the corpus under the four
  legs (84 431 programs, no fault but the sanitiser's own expected trap), and had one adversarial
  reviewer write 704 programs: no fault.
- Rebased onto report 142 (records in place) and checked the combination: no line lost on 2 323 roots,
  Conduit's `Main` no longer passes its budget. Found `ShowAndBranches` trapping at report 142's head,
  not from these changes: #2530.
- Issues: comments on #2508 and #2501, new #2521 (cell contents), #2522 (list pattern parts).

**What I learned**

- The 24-place set of answers in work was the cause #2508 item 3 blamed on `Hosted.mapJob`. A limit
  that falls to the pessimistic side still hides a precision loss on real code, and the only way to see
  it is to instrument the walk on the real program, not to reason from its contract.
- With records judged, the same lost answers cost Conduit's `changeRouteTo` its budget: a pessimistic
  fallback that holds every argument in sight is also the expensive one.
- On a loaded machine (load 40 to 70), run timing only with the sweeps paused, many runs and the least
  time; a 25-minute timeout killed one LLVM build outright.
- `beni check` without `--no-cache` from inside `tests/corpus/run/` leaves a `.beni-cache` that the
  corpus walker takes for a fixture and fails the gates.
