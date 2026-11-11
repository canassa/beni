## 2026-11-11 03:25 CET — 23 open record lines of pages are a schema call, not the entry

Part of #2477. Part of #1018. More evidence for #2480.

**What I did**

- 23 more open record lines of the parity net's known list have a reason. 21 are in the `pushed` function of 14 `browser/inline` pages, and 2 are in `run/` programs. In each one, `Schema.read` or `Schema.parse` took a schema value before, and checker v2 then refuses the update of the model (`escaped`).
- `ownership/RecordBesideSchema` has the form now (`pushed`): the refused object is a parameter that the call did not take.
- The pinned number of open entries is 135.

**What I learned**

- I had these 21 lines down as "the entry, S7" in my notes and in the first table of #2477, with the words "I did not check each line". The program is a page, the record is its model, and the cause is `escaped`. Each of the three facts fits the entry. The cause was a schema call two lines above. A guess that fits three facts is still a guess, and I am glad that it was in a note and not in the known list.
- A script that finds the declaration of each line and searches it for one pattern checked 25 lines in a second. Two of the 25 had no schema call, and they are still open. The check gave me the 23 that are true, and it gave me the 2 that are not.
- The finding matters more than the classification. Fourteen pages of the corpus do not build under v2 with enforcement because they validate a server's value before they update their model. That is the normal shape of a page that talks to a server.
