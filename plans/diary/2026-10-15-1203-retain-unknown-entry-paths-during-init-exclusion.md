## 2026-10-15 12:03 CEST — Retain unknown entry paths during init exclusion

**What I did**

Answered Claude's review questions on #116 by narrowing the init-field filter:
only a known first field named init is excluded; root and wildcard entries stay
retained. An absent init lookup now yields an unknown model rather than an
unchecked unwrap. Added a helper-returned entry record with a record update;
its diagnostic is the intended list_still_used at the constructor, not a
separate unseen-callback limit. Clarified that expand follows ordinary captures
before the carried-binding worklist. Added the empty-base hint fallback and
clarified the lazy memo and cache-version history. Ownership blocks advance to
8 for the conservative path fix; the earlier capture proof first used 7.

Exact Linux gates pass after the refinement and the final helper-record fixture.
The post-rebase full hash recording already passed; these checker changes do not
change emitted JavaScript. The existing page grants and original tea goldens
remain unchanged. Prepared the follow-up review reply without merging.

**What I learned**

Symmetric path overlap is the wrong predicate for excluding one field: roots and
wildcards overlap init but may also represent other retained callbacks. A known
first field is a sufficient exclusion proof. A helper-record regression must
reach the entry check; putting an unseen writing callback inside the helper can
instead fail at that unrelated precision limit.
