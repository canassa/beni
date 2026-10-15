## 2026-10-14 19:29 CEST — answer the review of the budget PR

**What I did**

Asked `@claude` for a review of draft PR #104, because the review workflow
skips drafts. Fixed two findings: `gates --release=fast` passed the refusal
(`--release` sets the mode without the build options), and the refusal tests
now hand their child `zig build` this build's local cache. Added a third
refusal test. Answered the other five findings on the PR.

**What I learned**

Zig 0.17's `zig build` takes a global cache only from `ZIG_GLOBAL_CACHE_DIR`.
A superset check of the host's CPU features against the resolved
`x86_64_v3+sha` model fails on a Zen 2: the model carries six tuning flags
that no CPU reports, so the feature list stays by hand.
