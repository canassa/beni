## 2026-11-27 16:25 CET — v3: what a walk leaves for the lowering is in the block

**What I did**

- Worker `own3-speed`, issue #2549, PR #2720. CI was green on the head and the manager was ready to
  merge. Then the review branch moved by 11 commits (to d144411a2e) and the pull request conflicted in
  the kernel's header line. I merged the branch again (no force-push).
- Two of the 11 commits change what a walk leaves, and neither made a conflict. `Published.views` is a
  new column that importers read. The codec's compile-time list stopped the build on it. And the walk
  now tells the lowering two more things of a module, in the driver and not in the published
  contracts: whether each of its record updates is accepted (`Driver.records_in_place`) and the calls
  that write a record argument in place (`Driver.record_calls`). Nothing stopped the build for these.
  A module that the cache gave had neither, so a warm build of a `browser-inline` program wrote other
  JavaScript than a build with no cache.
- The block has the calls now, and `Enforce.restore` reads the first fact off the restored channel as
  the walk does. Kernel §7.1 rule 3 names both, and says the rule: each thing that a walk leaves for a
  later phase is in the block or is made again from it.
- A new scenario builds a `browser-inline` program with no ownership flag, in development and in
  release: no cache, cold, warm, and after an edit of `Main` (so `Step` comes from the cache). With the
  restore of the two facts removed, it fails and the other 12 scenarios pass.
- The manager had asked about two `check_test` failures of an earlier CI run. Both were the tests' own
  10 s guard on the compiler. The two commands take 4.0 and 4.4 s on my machine with and without the
  change, so the change is not the cause.
- A build sweep with no ownership flag: 2 885 roots, 0 faults; 496 of them are `browser-inline`
  programs, which choose v3 in the manifest, and each clean one has hits and no miss in its second
  cached build.

**What I learned**

- My guard covers the types that the codec writes. It does not cover a new output of the walk that
  lives beside them. `record_calls` is a column of the driver, written by `walkModule`, and no type of
  the block changed. Only a comparison of the emitted JavaScript with and without the cache finds
  that, and only on a program that uses the new fact. So that comparison must run on the default path
  of each platform, not only under the test flags. My first build sweep had `--ownership=v3` on each
  command, and the manager's comment about the manifest's choice was right about what that missed.
- I read the manager's comments on the pull request two hours late. I looked at the checks and not at
  the comments. After a push, read both.
