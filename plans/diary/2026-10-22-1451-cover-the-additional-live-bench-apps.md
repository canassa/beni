## 2026-10-22 14:51 CEST — Cover the additional live bench apps

**What I did**

Supplemented the original benchmark app list with the two fiber apps,
the websocket server and page, the empty page, and the API/routes page.
The websocket server had the same genuine borrowed-Ref append as the chat
server; copied its current players list before extending the replacement.
The other five additional apps check under the hidden ownership flag.

The combined audit covers 1,356 roots/module sets and 988 list demands,
with zero rejected or pending list lines and no command error. This
supersedes the earlier 1,350-root total, whose benchmark app selection
followed the older list in ownership-checker.md §30.2. Updated the pending
completion PR's specification counts and preserved the audit evidence.

**What I learned**

The bench directory also contains parser inputs, library comparison
workloads and dated research evidence outside §30.2's app set. A broader
diagnostic sweep recorded their outstanding reports in #741. The schema
prototype README explicitly identifies dated evidence whose limitation
assertions deliberately pin wrong behavior. Keep that evidence intact;
O1's applications are not an instruction to rewrite the research artifacts.
No benchmark measurement runner was executed, and no core/platform copy,
checker weakening or budget change was introduced.
