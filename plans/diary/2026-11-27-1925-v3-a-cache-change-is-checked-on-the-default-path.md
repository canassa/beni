## 2026-11-27 19:25 CET — v3: a cache change is checked on the default path

**What I did**

- Worker `own3-speed`, issue #2549, PR #2720, the manager's two checks after the second merge.
- Scenario 14: the corpus's page for a write inside a callee (`browser/inline/ReleaseCalleeWrite`,
  #2642) as a cache scenario, in development and with `--release`: no cache, cold, warm, and after an
  edit. The release optimiser keeps a call that writes a record inside its callee only because the
  lowering marks it from the calls that the walk publishes (`Driver.record_calls`). With those left
  out at a restore, scenario 14 fails and the other 13 pass. Scenario 13 (my own small page) does not
  need the mark: its call returns what the callee answers. So 13 tests the first fact of the lowering
  and 14 the second.
- The one fault of my first default-flag sweep that I could not explain. The manager asked for
  three more full sweeps with a cold build, a warm build and a build after an edit, at `--jobs=1` and
  `--jobs=8`, with the full stderr kept. I wrote `buildsweep-edit.mjs` (in my scratch directory): each
  of the 2 888 program roots on a private copy of its sources, each cached build compared with the
  build with no cache before it. Three sweeps: 5 776 sequences each, 0 faults, under a load average
  of 6 to 10. The fault did not come back, and I still cannot say what it was.
- Two `check_test` failures of an earlier CI run were the tests' own 10 s guard on the compiler. The
  commands take 4.0 and 4.4 s on my machine with and without the change. Issue #2737 has the three
  runs of today where such a guard failed a pull request.

**What I learned**

- My sweep's edit step wrote into a tracked file. One root has a source file that is a symbolic link
  into another directory of the repository, and Node's recursive copy kept the link, so the appended
  comment went through it. I saw it in `git status` after the first run and restored the file. The
  script now turns such a link into a file of its copy and refuses an edit whose real path is outside
  its scratch directory. The second version of the check fired on the next run, before any write. A
  tool that edits a copy must prove that it edits the copy.
- A sweep that has `--ownership=v3` on each command does not test the platform that chooses v3 in its
  manifest. The emitter reads that choice (`ownership_v3_platform`), so the default path lowers
  other code than the flagged path. A cache change needs the default path of each platform in its
  sweep, in development and in release.
- When a result of my own evidence is "one fault, not reproduced", the reader cannot merge past it.
  Keep the full output of a fault from the first run on; the first run kept 400 bytes.
