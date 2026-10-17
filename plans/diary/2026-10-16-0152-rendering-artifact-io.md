# 2026-10-16 — Reuse immutable compiler dumps during the stress sweep

Filesystem I/O pressure was leaving CPU capacity idle: compiler-dump processes
were waiting in the filesystem while rewriting thousands of cached prefix
modules. New batches hard-link immutable compiler-pinned BIR into each app;
existing files must byte-match the cache, and cross-device links fall back to
copies. Source, chunks and analysis witnesses are exactly unchanged for all
four lowerings on the original mixed N32 app. The protocol records this
artifact-handling amendment; compiler and compression output are unchanged.

The published checkpoint contains 2,306 measured sizes, including 884 stress
measurements. Fourteen curves have measured target crossings and thirteen
have recorded compiler limits; the remaining family sweep continues. The latest
remote audit verified 882 stress artifacts before two additional arrivals.
The table now compares most families through N2,592, with explicitly different
windows for direct, explicit cells and Solid. The report remains below 2,000
words, and the standalone HTML, exports and data are refreshed together.

No repository gates or suites and no new application timing measurements ran.
