## 2026-10-15 13:06 CEST — Direct group record timing

**What I did**

Opened PR #134 and requested @claude review. Added a separate rotated
fresh-page Conduit batch for complete group-array records, preserving the
original short-path batch and all raw observations. The automatic review
reported no issues; the explicitly requested review is still running.

**What I learned**

The 233 B group-record saving has mixed timing directions inside overlapping
ranges: feed 0.360/0.355 ms, favorite 0.310/0.325 ms and editor 0.285/0.300 ms
for original/prototype. This does not establish a reproducible speed change;
full UI and mount validation remains necessary before implementation.
