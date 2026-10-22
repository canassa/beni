## 2026-10-22 11:41 CEST — Copy shared Ref lists

**What I did**

Started #210 again from origin/master 9c9de7a66 on dagon. Posted the
no-cost ownership-everywhere baseline on the issue: nine rejected programs,
no crashes, and core plus every shipped platform clean. Copied the lists
borrowed by six Log fixtures, WebSocketArena and the todo server before
extending them. Added a rejected twin for Ref.update and Ref.modify spreads.
Recorded the refusals before changing the fixtures and refreshed run hashes.

**What I learned**

The schema and RefModify decisions have already landed. New Ref users repeat
RefModify's real-sharing pattern. FormValidation still needs #223's general
function-value precision work. The old audit script only dumps rejected
programs and therefore cannot prove absence of pending lines; a separate
whole-program dump audit is needed. Staged record refusals now share the
report with list demands; their scope relative to #210 needs to be explicit.
