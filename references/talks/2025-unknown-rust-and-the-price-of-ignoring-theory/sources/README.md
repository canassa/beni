# Sources for "Rust and the price of ignoring theory"

Primary sources the talk cites or relies on, retrieved **2026-11-02** from open copies only (arXiv,
authors' and institutional pages, publishers' open-access copies, GitHub, official sites; the MSRC post
through the Internet Archive because msrc.microsoft.com answered 403). Nothing here was executed.
The talk names few of its sources, so most rows are **identified from context**; the "Basis" column
says how sure that identification is. Time stamps are the talk's, from
[`transcript.md`](../transcript.md) (auto-captions; quote from the video).

Layout: `pdf/` papers and reports (each PDF has a `.txt` from `pdftotext -layout`), `web/` web pages
saved as Markdown with a header giving URL and date, `code/` GitHub material. There is no earlier
precedent for stored sources in `references/talks/` or `docs/design/research/`, and no LFS rule; the PDFs
are plain files (about 20 MB in all).

Status: **downloaded**, **paywalled**, **not found**, **ambiguous** (a source was saved but may not be the one meant).

| Time | Claim it backs | Citation | URL / DOI | Local file | Status | Basis |
|---|---|---|---|---|---|---|
| 0:00 | Algebraic data types first appeared in Hope in the 1970s | Burstall, MacQueen, Sannella, *Hope: An experimental applicative language*, LISP Conference 1980 | <http://homepages.inf.ed.ac.uk/dts/pub/hope.pdf>; doi:10.1145/800087.802799 | `pdf/hope-burstall-1980.pdf` | downloaded | Hope named; paper is the standard citation. The paper is 1980, the language 1970s |
| 0:00 | Microsoft: ~70% of security bugs are memory related | MSRC, *We need a safer systems programming language*, 2019-07-18 | <https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/> | `web/msrc-safer-systems-language-2019.md` | downloaded (Wayback copy) | Inferred. Says ~70% of **CVEs Microsoft assigns**, not "security bugs" |
| 0:00 | Chromium: ~70% of security bugs are memory related | Chromium Security, *Memory safety* | <https://www.chromium.org/Home/chromium-security/memory-safety/> | `web/chromium-memory-safety.md` | downloaded | Inferred. Says ~70% of "serious" / "high severity" bugs. Both posts are about C and C++ code, as the talk says |
| 1:36 | Oxide, a region-based formalisation of Rust, including non-lexical lifetimes | Weiss, Gierczak, Patterson, Ahmed, *Oxide: The Essence of Rust*, arXiv 2019 | <https://arxiv.org/abs/1903.00982> | `pdf/oxide-weiss-2019.pdf` | downloaded | Named in talk |
| 1:36 | Lifetime subtyping tried first in RustBelt; "abandoned" at non-lexical lifetimes | Jung, Jourdan, Krebbers, Dreyer, *RustBelt: Securing the Foundations of the Rust Programming Language*, POPL 2018 | <https://plv.mpi-sws.org/rustbelt/popl18/paper.pdf>; doi:10.1145/3158154 | `pdf/rustbelt-popl18.pdf` | downloaded | Named in talk. See **Flags**: the paper does not say this |
| 6:25 | Hylomorphism, folds and unfolds as recursion schemes | Meijer, Fokkinga, Paterson, *Functional Programming with Bananas, Lenses, Envelopes and Barbed Wire*, FPCA 1991 | <https://maartenfokkinga.github.io/utwente/mmf91m.pdf> | `pdf/bananas-meijer-1991.pdf` | downloaded | Inferred (not named in talk); the founding paper of the term |
| 13:56-15:54 | A soundness hole from lifetime subtyping / implied bounds, "reported in 2015, unfixed" | rust-lang/rust issue #25860, *Implied bounds on nested references + variance = soundness hole* | <https://github.com/rust-lang/rust/issues/25860> | `code/rust-issue-25860.md`, `code/rust-issue-25860-comments.md` | downloaded | Identified by the code: the issue's example is the talk's `foo`/`bar` with a `&'static &'static ()`. Open, opened 2015-05-28 |
| 17:12-18:13 | Dependent types: `Vect n` with `Fin n`; Idris brings them to general-purpose use | Brady, *Idris 2: Quantitative Type Theory in Practice*, ECOOP 2021 | <https://arxiv.org/abs/2104.00480> | `pdf/idris2-brady-ecoop21.pdf` | downloaded | Idris named; paper chosen by me |
| 19:51-21:20 | Quantities / graded modal types; usage grades `dupe`, intervals | Orchard, Liepelt, Eades, *Quantitative Program Reasoning with Graded Modal Types*, ICFP 2019 | <https://www.cs.kent.ac.uk/people/staff/dao7/publ/granule-icfp19.pdf>; doi:10.1145/3341714 | `pdf/granule-quantitative-reasoning-icfp19.pdf` | downloaded | Granule named; this is its main paper |
| 19:51 | Granule itself, its repository and examples | granule-project/granule (README) | <https://github.com/granule-project/granule> | `web/granule-readme.md` | downloaded | Named ("Granule's repository") |
| 21:20 | Linear Haskell has the same trouble with several arrays; phantom region parameters | Bernardy, Boespflug, Newton, Peyton Jones, Spiwack, *Linear Haskell*, POPL 2018 | <https://arxiv.org/abs/1710.09756> | `pdf/linear-haskell-popl18.pdf` | downloaded | Named in talk |
| 22:44-24:51 | Unique modality `*`, `share`, `clone`, fractional borrows `withBorrow`/`split`/`join` | Marshall, Orchard, *Functional Ownership through Fractional Uniqueness*, OOPSLA 2024 | <https://arxiv.org/abs/2310.18166> | `pdf/fractional-uniqueness-marshall-orchard-oopsla24.pdf` | downloaded | Inferred; the features match the paper's title and abstract |
| 22:44 | Uniqueness and linearity together | Marshall, Vollmer, Orchard, *Linearity and Uniqueness: An Entente Cordiale*, ESOP 2022 | doi:10.1007/978-3-030-99336-8_13 | `pdf/entente-cordiale-esop22.pdf` (Kent repository copy, CC BY) | downloaded | Inferred; the talk does not name it. Text extraction needed `pdftotext`'s xref repair but is complete |
| 24:37 | "Complete example from the Granule project" splitting a unique array in two and summing the halves concurrently | `examples/parallelWithMutation.gr`, granule-project/granule @ `85a463f` (HEAD on retrieval) | <https://github.com/granule-project/granule/blob/main/examples/parallelWithMutation.gr> | `code/parallelWithMutation.gr` | downloaded | Identified by the code (`withBorrow`, `FloatArray`, `Parallel`). The repo has other related files (`work-in-progress/Fractional.gr`) |
| Resource reasoning in general | "linearity or quantitative reasoning" | Atkey, *Syntax and Semantics of Quantitative Type Theory*, LICS 2018 | <https://bentnib.org/quantitative-type-theory.pdf>; doi:10.1145/3209108.3209189 | `pdf/atkey-qtt-lics18.pdf` | downloaded | Background; the transcript says "quantitative" but never names Atkey. Kept because Idris 2 and the grades rest on it |
| 28:03-29:04 | Swift's stable ABI and resilient layout via witness tables | swift.org, *ABI Stability and More* (2019); `docs/LibraryEvolution.rst`; `docs/ABIStabilityManifesto.md` | <https://www.swift.org/blog/abi-stability-and-more/>; <https://github.com/swiftlang/swift/blob/main/docs/LibraryEvolution.rst>; <https://github.com/swiftlang/swift/blob/main/docs/ABIStabilityManifesto.md> | `web/swift-abi-stability-and-more.md`, `web/swift-library-evolution.md`, `web/swift-abi-stability-manifesto.md` | downloaded | Inferred; the talk only says "Swift ... stable ABI ... witness tables" |
| 31:17-32:21 | "[Vong?] recently reported 32% of exploited vulnerabilities were zero day" | VulnCheck, *State of Exploitation, 1H 2025*, 2025-07-30 | <https://www.vulncheck.com/blog/state-of-exploitation-1h-2025> | `pdf/vulncheck-state-of-exploitation-1h2025.pdf` | downloaded, **ambiguous** | The captioned "Vong" is most likely "VulnCheck"; the figure 32.1% matches. See **Flags** |
| 33:22 | "Clownish repository ... satirical commentary on a hello world game setup in Rust" | mTvare6, *hello-world.rs* | <https://github.com/mTvare6/hello-world.rs> | `web/hello-world-rs-readme.md` | **ambiguous** | Best match, but it is a hello-world program, not a game, and I found nothing about a "culture war" in its README. The speaker may mean another repo |
| 34:25 | "Vulnerability density: continuous upward trend at the package level, decreasing at the code level"; vulnerable code has more `unsafe`; most vulnerabilities are memory safety and concurrency | Zheng, Wan, Zhang et al., *A Closer Look at the Security Risks in the Rust Ecosystem*, TOSEM 33(2), arXiv 2023 | <https://arxiv.org/abs/2308.15046> | `pdf/security-risks-rust-ecosystem-zheng.pdf` | downloaded | Identified by the quoted sentence, which is in the abstract |
| 40:09 | Discord's Go to Rust gain came from further changes (BTreeMap, metrics library, fewer copies) | Discord, *Why Discord is switching from Go to Rust*, 2020-02 | <https://discord.com/blog/why-discord-is-switching-from-go-to-rust> | `web/discord-go-to-rust-2020.md` | downloaded | Named in talk. See **Flags** |
| 40:09 | ripgrep's speed comes from a different SIMD algorithm inspired by Hyperscan | Gallant, *ripgrep is faster than {grep, ag, git grep, ucg, pt, sift}*, 2016 | <https://burntsushi.net/ripgrep/> | `web/ripgrep-announcement-2016.md` | downloaded | Named in talk. The post does say Teddy is from Hyperscan |
| 43:40 | FFmpeg: "proudly written in the C programming language ... other fashionable languages ... do not meet the needs of FFmpeg" | FFmpeg project | not found on ffmpeg.org; repeated in <https://levelup.gitconnected.com/rust-isnt-always-the-answer-ffmpeg-s-bold-defense-of-c-82fc557f091e> without a link | `web/ffmpeg-about.md`, `web/ffmpeg-developer-doc-excerpt.md` (neither has the sentence) | **not found** | Probably a social-media post by the project's account; I could not locate it. See **Flags** |
| 44:37 | Linus on Rust for Linux: "if it were to become a failure ... that's how you learn" | Edge, LWN, *Linus and Dirk show*, Open Source Summit Europe, 2024-09-25 | <https://lwn.net/Articles/990534/> | `web/lwn-torvalds-hohndel-2024.md` | downloaded | Inferred; LWN contains the words. See **Flags** |
| 44:37 | Rust "most beloved" in the 2020 Stack Overflow survey | Stack Overflow Developer Survey 2020 | <https://insights.stackoverflow.com/survey/2020#most-loved-dreaded-and-wanted> | `web/so2020-most-loved-excerpt.md` | downloaded (excerpt) | Named in talk. Charts are images and were not captured |

## Flags

Nothing here is a hunt for errors. These are the places where a source did not match the speaker's wording.

1. **RustBelt and non-lexical lifetimes (1:36).** The speaker says RustBelt's lifetime-subtyping model
   was abandoned once extended to non-lexical lifetimes. The POPL 2018 paper says the opposite:
   "our type system already handles ... non-lexical lifetimes" (and notes that its lifetime logic needs
   to handle lexical read-only permissions differently). Oxide's introduction does treat NLL as the
   motivation for a new, region-based formalisation. The talk's account may come from a later source
   (a talk, a blog post, or another RustBelt paper); I did not find one. Treat the claim as unsupported.
2. **The 32% figure (32:21).** VulnCheck's 32.1% is the share of KEVs with exploitation evidence **on or
   before the day the CVE was published**; the report does not use the words "zero day". The speaker's
   point (known, patched flaws are the usual route in) also needs the other half of the report, which
   I did not check. The source name is a guess from a garbled caption.
3. **Zheng et al. (34:25).** The abstract says the density decrease at code level holds "since August
   2020"; the talk leaves out the date. "Majority ... memory safety and concurrency" is "nearly two thirds"
   in the paper. Otherwise the quotes match.
4. **Rust issue #25860 (15:54).** The issue is open since 2015-05-28 as the speaker says, but its first
   comment records that the reported example was fixed in rust-lang/rust#129021 for non-higher-ranked
   function pointers and that "the underlying issue still persists" with a higher-ranked variant.
   This fits his "hack for the reported example", so it is support, not a contradiction.
5. **Discord (40:09).** The post says the first Rust version had latency "just as good as Go's" with no
   spikes, and that "even with just basic optimization" it outperformed the tuned Go service; the three
   changes (BTreeMap, metrics library, fewer copies) then made it beat Go on every metric. The talk
   says the initial rewrite "had the same performance". Close; the post claims slightly more.
6. **FFmpeg (43:40).** The exact sentence is not on ffmpeg.org's About or Developer pages that I saved.
   Only a third-party article quotes it, with no link. The official developer page says FFmpeg is
   mainly ISO C11 and that handwritten assembly is used because compilers cannot generate good SIMD
   from C, which is a related but different statement. The talk also calls it a benchmarked
   port; no source for a benchmark was found.
7. **Linus (44:37).** LWN quotes: people have "even talked about the Rust integration being a failure",
   which is "way too early to determine", and "even if that happens, 'and I don't think it will,
   that's how you learn'". The talk's reading ("smashing endorsement") is the speaker's gloss on a
   lukewarm but not negative remark; the claim that Linus "hasn't bothered to learn" Rust is not in LWN.
8. **Stack Overflow (44:37).** "Loved" in that survey means the share of **current users** who want to
   keep using the language, so "most beloved but most respondents are not familiar with it" is a
   fair gloss of the definition. The survey does not say that itself.
9. **The "hello world game" repo** could not be pinned down (see the table); do not cite hello-world.rs for
   this claim without checking the video.

## Not tied to the talk (dropped)

The task listed some candidates the transcript does not mention: no talk passage names Quantitative
Type Theory, Idris 2, Atkey, the Granule "Entente Cordiale" paper or Swift's docs by title. They are kept
above, marked "inferred", because the talk relies on those ideas by name (quantities, Idris, Granule,
witness tables). Nothing was found in the transcript for any "70% of bugs" academic study beyond the
two vendor posts, nor for Meijer et al. by name (hylomorphism only).

## Not in the talk, not saved

The talk does not name the papers behind: its "type-directed solutions are simpler, faster, and make
better error messages" claim, the OCaml module-system theory (no ML-module paper is cited), the
hashed-flat-namespace ELF criticism, or "Rust matches C through LLVM is overblown" (no benchmark).
No source was sought for those.
