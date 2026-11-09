## 2026-11-09 09:05 CET — end the release hang on a non-regular type

**What I did**

- Reproduced #2225 on master 9d5a878494: `beni build --release` did not end in 15 s; the development build did.
- Took a stack with gdb: the build spun in `RepKeys.closeThrough`, the closure of the wild set of representation keys (`backend.md` §9, fact 3's declared-type filter).
- Used the fix of PR #2307 for `RepKeys.zig`, byte for byte, with its `backend.md` amendment: the closure counts the applications of each named type that it closes through, and past 1024 every key is wild.
- Added `run/NonRegularMatchRelease` with the issue's program. It timed out without the fix and passes with it.
- Moved `FamilyFunctionRun` from `ownership/` to `run/`, with its two v1/v2 known lines.

**What I learned**

- A type that recurs with larger arguments (`Wrap (T (List a))`) has no finite wild closure: a wild `T X` makes `T (List X)` wild, then `T (List (List X))`, and so on.
- Every `run/` program also gets the v1/v2 ownership parity check. A fixture moved there keeps that coverage, and its known lines must follow the new path.
- The issue's program was not formatted; `beni-fmt-check` gates every corpus `.beni` file.
