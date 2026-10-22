## 2026-10-22 17:04 CEST — Integrate #610 with master

**What I did**

- Merged master into #610's branch twice (eee68c822, then a0a372e3b), with merge commits and
  no rebase, because the branch is squash-merged.
- Resolved `browser-inline.md` §8.4 by keeping both texts: master's #668 reversal note and the
  PR's view-helper bullet. In `browser_test.zig`, removed the three budget tests that master
  deleted and kept the PR's two tests. Took the run hashes from master and recorded them again.
- Recorded four goldens again. `WidgetHandler` is a new master fixture. Under this branch's
  handler-at-wiring lowering (#625), each of its 64 buttons gets its own arrow. On master, the
  buttons share one `const`. The other three goldens changed only in names.
- Fixed #758. After the merge, `HelperStaticBool` read `undefined` in release. A literal helper
  argument was one JsIr node with two parents: the parameter's binding and an event capture.
  Master's `Spec` now rewrites the initialiser of an unread binding in place, so the capture
  changed too. `directInlineEnter` now binds a copy of the literal.

**What I learned**

- Master's `Spec` dead-binding sweep (6f90eafa6) changes a node in place. A lowering that puts
  one node in two places breaks without a sign until release. Nothing in JsIr says that a node
  has only one parent.
- On master, `test-pending` fails by itself: `ownership/DictFocusGrow.beni` has no finding line,
  and `RED` still names `emit/release/inline/EnumCycle.beni`, which 862245931 deleted.
