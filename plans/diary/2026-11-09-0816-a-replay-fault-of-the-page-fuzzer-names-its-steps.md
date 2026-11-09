## 2026-11-09 08:16 CET — A replay fault of the page fuzzer names its steps and both plays

**What I did**

- Issue #2144: the page fuzzer once failed on `browser/tea/Hello.beni` with "development does not replay itself" in the gates, and the next two runs passed.
- I ran the Hello value fuzz 610 times: 300 in sequence, 160 with two drivers at once, 150 with six drivers at once with every page copy stale, so that every process prunes. No run failed.
- `fuzz.mjs` now prints a replay fault as it prints a difference: the seed, the step, the actions up to it, and what the first play and the replay showed. A new test in `page_fuzz_test.zig` breaks a build so that its second load shows another title. The test fails on master's fuzzer and passes with the change.

**What I learned**

- The gates always fuzz seed 1 of 30 steps, so the old report did name the sequence. What it did not show was the part that differed, and without it a one-time fault cannot be explained.
- A build directory that is a symlink makes `cpSync` copy the link itself. Then every page copy is one real directory, Node gives the replay the cached module, and the replay page stays empty. This gave me a false reproduction for an hour. `beni build` writes no symlinks, so the gates cannot hit it. Put real copies in a stress test.
- In happy-dom under the driver, each page has its own global object, but happy-dom's classes are shared. A test that must carry state from one page to the next keeps it on `Node.prototype`.
