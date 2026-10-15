## 2026-10-15 14:32 CEST — Grant Bike Wars and promote the paired page

**What I did**

The owner authorized updating the grant and merging. Added an 8,600M
instruction budget for Bike Wars' paired page, about 10% above its measured
7,784M. Its separate value fuzz measured 4,225M and keeps the default 4,300M.
Updated the grant inventories and removed the obsolete pending refusal.

Rebased onto current origin/master, recorded all six Bike Wars run hashes
on x86-64 Linux with Zorg and Node v24.19.0, and ran exact `zorg build gates`
successfully there. The measured and tested tree lives in the isolated
`/tmp/beni-bike-wars-20261015` on shoggoth; content checks match the local
tree. The paired Bike Wars Chrome run also passed on macOS. The app source,
original tea fixture directory and both copied transcripts are unchanged.
No compiler or visit-invariant changes were needed.

Prepared the promotion for a PR, Claude review and the authorized merge.
The earlier diary entry records why work originally stopped; this entry
records the subsequent grant and successful validation.

**What I learned**

The page grant needs to cover only the paired replay. Value fuzz has its own
budget and fits the default even though the page does not. Existing general
helper-document lowering is sufficient for this unchanged application.
