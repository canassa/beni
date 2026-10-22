## 2026-10-22 03:35 CEST — Combine field colours with shape names

**What I did**

Opened #667 after the field-colouring gates passed. #659 then landed, making
one release golden conflict. Merged origin/master, regenerated the release
goldens and run hashes, and ran the whole self-hosted gate on the combined
tree on dagon. All passed. Compared against the new master: all 25 changed
existing release goldens differ only in property names or shape slot-3 output
names. No output-size or speed measurements. No test or budget changed.

**What I learned**

The source integration needed no field-colouring changes: schema plan sets
cover the shared copy loop independently of boundary pinning, and #659's
field-name leaf is counted by the same table. The runtime schema fixture now
checks the unpinned shape path as well as workers, updates and the library
interpreter. Dagon's shared suite locks prevent full suites from competing.
