# Invalid setup epoch — excluded from every verdict

Benchmark preparation began before `zorg build -Doptimize=ReleaseFast` finished.
The initial machine capture observed compiler SHA-256
270839e6c10277acf59f651f0fef1fae3d4ffc848d6dfbe7e91a3e5b7d6ea17d
(build ID 6585a56fa93bd4409d5e0fa31105ab24); the completed compiler installed
at 13:41:39 CEST has SHA-256
af3e0494dbad405fd55ef5abe87127040d31468d27e6566d8a49854b8c37b0d9
(build ID 7445da00731bab8c2bf686c8b48bf033).

The mismatch was caught at about 14:14 CEST, before any UI sweep or real-app
timing had run. The timed direct table's SHA-256 was
0de0d992b22fbed70a9ee292612e7c98036a805f10de47db1e75b09dc995fc2d;
the same source built by the completed compiler is
fc2ae97fcdcfd1dda590c5b54c87a061ebe1dc4779ba46b94dd7ce7c227a2ce7.
Tea's table hashes match. Later JFB metadata read the new compiler path and
therefore does NOT establish which compiler built the earlier dist/ files.

Round 0's native report/raw observations and round 1's partial observations
are retained here as invalid evidence. No observations from this epoch are
included in the clean summary or compared to its candidates. The incorrectly
built direct source had been overwritten by clean preparation before it could
be archived; the observed hashes above are retained, not a reconstructed file.

The entire comparison campaign was restarted after freezing the completed
compiler at zig-out/beni-s8-frozen and rebuilding every candidate. Valid app
byte/count artifacts already name that completed compiler and remain valid.
The clean sample plan is one JFB batch with five ordinary CPU/memory samples
(and native select's 15), candidate order rotated at every operation; 20 fresh
pages on the unthrottled table and every real-app message; the full research
87 sweep settings. This is a global budget reduction before clean results,
not selective rerunning or sample trimming based on performance.

The owner subsequently confirmed **“Finish the fixed batch”** at about 14:22
CEST. That supersedes the global budget reduction described above: the clean
campaign retains the original four JFB rounds, twenty ordinary CPU/memory
observations and sixty select observations per cell. See ../../PROTOCOL.md.
