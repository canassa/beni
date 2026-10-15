## 2026-10-14 14:01 CEST — preserve nominal casts across foreign forwarding

**What I did**

Answered the review of PR #89 with a stronger typed and whole-sibling proof.
An identity cast between nominal types can reuse a tag while producing the
target type; the initial proof incorrectly pruned its arm. A real dev/release
fixture printed dropped instead of kept with typed-result protection disabled.
Non-equivalent nominal results now retain the whole annotation, including
returned callback inputs and record fields. Unclassified code elsewhere in
a sibling also retains its exposed annotation types; disabling that module
guard made the mixed-export runtime fixture print the wrong variant.

Added six executable foreign boundary fixtures (casts, wrapped casts, returned
closures, callback casts, tagged producers and mixed siblings), verified in
both builds. Scoped the exact-only ownership diagnostic flag with defer.
Reverified the two page-fuzzer scenarios whose digests changed; their expected
reports matched, two hashes updated, without a budget change. Final native
zorg gates again have 1,295 passes, 15 skips and only the four authorized
macOS baseline failures. No LLVM build. The corrected compiler emits the exact
same four timed TodoMVC bundles, checked by SHA-256, so no timing was rerun.

**What I learned**

No allocation is not no constructor production: nominal casts and function
argument casts can preserve representation while changing the type whose
case arms must survive. An inert export's signature can expose a type to other
code in its own sibling. Only a wholly closed inert sibling and a matching
returned-parameter type justify the stronger omission. Foreign-visible tags
still use dollar keys and source strings in release; runtime fixtures pin it.
The corrected size stop stays withdrawn, but the complete timing misses stay.
The PR remains draft and must not be merged under this request.
