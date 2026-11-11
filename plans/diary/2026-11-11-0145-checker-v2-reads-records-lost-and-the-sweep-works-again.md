## 2026-11-11 01:45 CET — checker v2 reads --ownership-records-lost, and the sweep works again

Part of #1018 (S5c). Closes #2472.

**What I did**

- Under `--ownership=v2 --ownership-records-lost`, each line of a record demand is refused, approximately, with the cause `unknown` and one detail. The list pass does not see the flag.
- The gates report each `ownership/` fixture with a `.v2` file and a record line a second time with the flag: the list lines are the same bytes, and no record line is accepted. The mutant `records_lost_keeps` is killed by 46 of these fixtures.
- `zig build test-records-lost-v2` is the sweep of v1 with `--ownership=v2`: 2 401 programs, no list line differs.
- I corrected `tests/records-lost.mjs` (#2472): it reads no pipe that it does not empty, it reads a `.platform` file as tokens, it knows the four newer `browser/` sub-corpora, and a program with no report is an error.
- I filed #2473: with the corrected script, the v1 sweep ends and finds one line that moves in `run/SanitiserRecordForwardedInList`. v1 is frozen, so it is a record.

**What I learned**

- My first run of the sweep took 2.5 hours and printed nothing. I had given it a limit of 9 000 s, because I did not know how long the sweep takes. It takes 2 minutes. A limit that is 75 times the real time finds a stopped job 2.5 hours late. Before a long limit, I measure one small part, or I read how long the last run took.
- The cause was a pipe that nobody reads. The script took the report from the standard output and gave the error output a pipe too. A run that prints more than the pipe holds stops in its write, with no error and no CPU use. The limit is not one number: under v1, runs with 121 kB and 200 kB ended, and runs with 524 kB and 2.6 MB stopped; under v2 the smaller ones stopped too. `stdio: "ignore"` for a stream that the script does not read removes the question.
- The larger defect was silent. The script compared two runs with the same exit code, also when the code was 2 and there was no report. 66 `ownership/` fixtures had `unknown platform` in both runs, because the `.platform` file got a second token form (`+everywhere`) after the script was written. These are the entry fixtures and many record fixtures: the programs that the rule is about. A comparison of two empty things is green. A check must say how many things it compared, and "nothing to compare" must be an error.
- A sweep that no gate and no CI job runs stops working, and nobody sees it. This is the second time in two days (#2457 was the first). The corpus got four sub-corpora and a new token form, and each one broke the script a little more. Now an unknown sub-corpus makes the sweep fail with `NO REPORT`, and does not stop it.
- When the corrected sweep ran for v1, it found a difference at once (#2473). I did not change the filter to make it green: I do not know if the line is a record line under another name or a list verdict that reads a record condition, and v1 is frozen.
- The rule for v2 holds by construction (two passes), so the sweep found nothing. The mutant shows that the gate check is not empty: with the flag ignored for record lines, 46 fixtures fail.
