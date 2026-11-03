## 2026-11-03 06:38 CET — Resolve lane: deep paths read off their nodes

**What I did**

- Step 1 (`7b1b90d6bd`): #1225's owed test (c) passes at its original bounds. `shared256` went from 6 954 records (growth 1 033) to 1 824 (growth 0), and `call256` from 1 649 to 1 134. A path node keeps a skew-binary jump pointer and a "`⟲` on the way" bit, packed with its depth so `PathNode` stays 24 bytes. A place keeps a `family` bit. A hold at the leaf's own slot is the target's path. Liveness asks only as deep as the holder's deepest use. An arrival keeps its path for the expansion, and the write graft's walk carries its path.
- Step 3 (`96de38d9b3`): a failed graft test reads the slot's steps off the path and charges nothing. `Codec.Decode.field`'s +3 growth and `Dict.insertHelp`'s +20 are gone.
- Step 2 (the inline knot chain) is not started. It needs the DAG descent to carry route sets, and the manager asked that hold route sets share the values lane's representation, which is not posted yet. Status and the plan are on #1714.

**What I learned**

- A per-account first read makes every module-table entry cost its full fill once per account. So a deep path costs its depth to every account that derives it. Only data made with the node, such as a jump pointer or a flag, or handed over in a contract, such as an arrival's path, makes such a read constant.
- A tree profile (a trie of return addresses, with recursion folded) shows which caller pays. The flat per-address profile cut stacks at 64 frames and counted `reserve` twice.
- Small cost wins can break a test that pins a growth band. The near-limit test asks for its bounds to be moved, and moving them is the intended use.
- A fast path for `canon` must not add a `set` record per call. That made `h`'s growth go up, not down.
