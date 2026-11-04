## 2026-11-04 03:47 CET — Add checked optional Any opening

**What I did**

Added the approved core/platform-private Any.unpackOpt compiler intrinsic: exact identity checking with raw payload or NONE, preserving nested optional escapes and callback/native facts. Added development/release emit and runtime fixtures, application refusal, HostFree rollout coverage, and a v2 refusal for an unknown decoded list. Recorded run hashes for the new program. Kept the rows port separate.

**What I learned**

V1 already accepts a shared List.push after existing Js.some/optWithDefault projection on the frozen base. V2 refuses it, and today's List.push remains persistent. Issue #1831 records the requirement to fix the projection before emitting destructive list writes on v1's judgement. The approved reduced case remains red under tests/pending with the expected refusal, rather than weakening the v2 check. Full gates remain for the rows PR; this is the requested primitive checkpoint.
