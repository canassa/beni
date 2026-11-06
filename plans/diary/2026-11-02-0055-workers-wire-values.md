## 2026-11-02 00:55 CET — Workers exchange typed values

**What I did**

Added Wire checks for manifest entry roles, retained generic field-path obligations in cached interfaces, and compiled selective List normalization plans. Assigned wire fields once across page and worker projections while keeping private release names local. Extended the worker test platform and added typed Chrome round trips and exact diagnostic assertions for nonserializable values.

**What I learned**

A handwritten entry runtime needs its Program representation kept at the JavaScript boundary. A shared field palette also needs explicit reserved spellings in each local assignment. Messages received while the worker's init fiber starts must wait for its typed handler. Chrome passes both development and release round trips; an ordinary development and release build matches the baseline byte for byte. Full gates follow before the PR.

The full run-hash refresh exposed the existing aborted-request handler-count race in `HttpServerBadClients` (#1641). Its release output also matches the baseline byte for byte. A targeted retry matched the unchanged golden and recorded both hashes; every other run in the full refresh passed.

A warm-cache regression also reproduced a stale normalization path after an opaque payload field rename. Wire-enabled dependency digests now include exposed nominal payload layouts and their private type closure. Ordinary builds retain their existing digest path. The regression fails with that digest change set aside and passes with it restored; the new checker traversal uses the existing Walk accessors under the unchanged architecture rules.
