# Did Roc's community ever discuss finer-grained effects than one pure/effectful bit?

**Question.** Roc's purity inference collapses every function to one bit: pure or effectful. beni's
open question is whether that bit is too coarse — we want to know which functions touch the network,
not merely that *some* function is impure. Flix's `\ {Net, Log}` effect sets and Koka's effect rows
give that; Roc's `!`/`=>` deliberately does not. This report checks whether Roc's community ever
raised exactly this granularity question. `roc-purity-inference.md` §3 already covers the 2024-08-28
"Purity Inference" and 2024-08-29 "opt-in effect polymorphism" threads; cited again here only where
they bear on granularity specifically, which that report's excerpts did not surface.

**Sources.** The `roc-zulip` skill, no other tool. Full-text search (`roc-zulip-search.fish`) for
`effect sets`, `named effects`, `algebraic effects`, `effect rows`, `capability`, `fine-grained`,
`which effects`; topic listing (`roc-zulip-topics.fish ideas --grep capab`); full reads
(`roc-zulip-read.fish`) of `#beginners › Algebraic Effects` (2024-04-11/04-30, 68 msgs), `#ideas ›
function effectfulness syntax` (2024-08-29), `#ideas › Purity inference proposal v3` (2024-09-17/18),
`#ideas › Platform extensibility using bundle of effects pattern` (2026-09-02/09-07), and `#ideas ›
Capability-based security` (2026-09-01/09-09, 30 msgs); a skim of `#beginners › What does the Roc
community mean by "effect"?` (2026-08-11), which turned out to be Haskell-terminology debate, not
granularity. Permalinks via `roc-zulip-msg.fish`. No benchmarks, no code run. Accessed 2026-09-14.

---

## 1. Three most relevant things found

**1. Roc built and shipped named per-effect-kind granularity once — a 3-argument `Task` with an
effect-row-shaped third parameter — and Feldman explained exactly why it was dropped.**

> "3-arg `Task` was something we tried out... instead of `File.readBytes` returning a `Task (List U8)
> ReadErr` (2-arg) it might instead return `Task (List U8) ReadErr [FilesystemRead]` (3-arg)... if
> you did both a HTTP request as well as a filesystem read, you'd end up with a `Task` whose third
> argument included both: `[NetworkAccess, FilesystemRead]`"
> — Richard Feldman, `#beginners › Algebraic Effects`, 2024-04-11,
> https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Algebraic.20Effects/near/432707282

`[NetworkAccess, FilesystemRead]` is structurally a named effect set — beni's exact ask. His reasons
for dropping it: threading cost, and that it still wasn't granular enough — "or 'this task only
connects to the database I've named `foo`' or 'this task only does network requests to
`my-error-reporting-service.com`... but not to any other domain'" (same thread,
https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Algebraic.20Effects/near/432708743).
His replacement was capability values passed as ordinary arguments: "I can give it a wrapper around
`Http.request` which only permits contacting a particular domain — essentially, 'sandboxed access'"
(https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Algebraic.20Effects/near/432712549).
**Central finding: Roc didn't decide granularity was undesirable — it decided type-level named-effect
tags were the wrong tool**, because a closed tag vocabulary tops out at "some network access
happened" and can't express "only to this domain," while a capability value can be attenuated at
runtime with no new type needed.

**2. Twenty-two months later, Feldman turned that into a concrete proposal: argument-position
capability tokens, one per effect kind, opaque, platform-defined — Roc's actual mechanism for
"which functions make a network call."**

> "in general I think the following is a simple and effective way to do capabilities in platforms:
> - `main! : Caps, Env, Args => {}`
> - `Caps := { read_file : Caps.ReadFile, write_file : Caps.WriteFile }`
> - the individual caps... are opaque so they can't be instantiated outside the platform
> ('unforgeable')
> - all effectful functions take those as arguments, e.g. `read_file! : Caps.ReadFile, Path => ...`
> - then if any function wants to read a file, it must be passed a `Caps.ReadFile` value, so you know
> which code pathways are doing which operations"
> — Richard Feldman, `#ideas › Capability-based security`, 2026-09-05,
> https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Capability-based.20security/near/621931050

This is finer than a Flix effect set in one sense (per-value, attenuable, revocable at runtime) and
coarser in another (the checker treats it as an ordinary argument type — no effect polymorphism, no
row variables). It is opt-in and platform-defined, not forced on every function by purity inference.

**3. A platform author asked the framing question directly, and the answer was "the platform
decides," unopposed.**

> "Anything that's security interesting is entirely within the purview of the platform and there's
> nothing special about `basic-cli` over something you'd write yourself. The seahaven platform...
> provides the normal APIs which will simply not do stuff outside the configured boundary."
> — Karl, `#ideas › Capability-based security`, 2026-09-01,
> https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Capability-based.20security/near/620742128

Nobody in the 30-message thread disagreed; the whole discussion (Luke Boswell's `roc-ray` spike,
Pierre Thierry's ocap literature, Feldman's `Caps` sketch) is about *how* a platform should expose
finer distinctions, never *whether* the language should. §3 develops this.

---

## 2. Feldman's stated reasons for one bit, verbatim

**(a) Semantic-primitive minimalism**, a general language-design stance, not effects-specific:

> "in general I have a strong preference for keeping the number of semantic primitives in Roc as
> small as possible... the bar for introducing things that are effectively sugar... is much lower
> than the bar for introducing things that are impossible to express in terms of something else."
> — Richard Feldman, `#beginners › Algebraic Effects`, 2024-04-25,
> https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Algebraic.20Effects/near/435415836

He contrasts this with Abilities (a predecessor primitive he judged worth the bar); named effect
sets would be judged the same way, as a new primitive, not a free add-on to purity inference.

**(b) `!` already covers most of the value, so the marginal case is weak:**

> "it seems like especially given `!` the potential benefits of algebraic effects compared to `Task`
> are a lot less clear to me."
> — Richard Feldman, same thread, 2024-04-25,
> https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Algebraic.20Effects/near/435416635

(This predates purity inference by four months — `!` here is still `Task.await` sugar — but the
reasoning carried forward: naming *what* has to clear the same high bar as `!` naming *whether*, and
by his own account a closed tag vocabulary didn't clear it; capability values later did, §0.2.)

A third, narrower point from the same message is ecosystem-fragmentation risk, not a type-system
argument: "having one `Task` type that everyone uses... seems like it can get the performance
benefits... without the drawback of the ecosystem split" seen in OCaml/Scala effects — aimed at
algebraic effects with user-defined handlers, not named effect sets per se, though the thread doesn't
always separate the two.

---

## 3. Is "the platform is the capability boundary" Roc's answer to granularity?

**Yes, with a specific shape: a runtime/argument-passing answer, not a type-checker answer.**

- **2024-04-11**, pre-purity-inference: I/O primitives already arrived as arguments to `main`
  (module params); a package "has no possible way to do HTTP" except by being handed an
  `Http.request`-shaped value, real or domain-locked. Granularity lives in *which value* you hand a
  function, not a type-level tag.
- **2024-08-29**, mid-design, Ayaz Hafiz on the record: *"this is algebraic effects with both
  multiple effect types and handlers. the distinction is that handlers are only defined by the
  platform"* (`#ideas › function effectfulness syntax`,
  https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/function.20effectfulness.20syntax/near/466068808),
  responding to Feldman calling purity inference "a form of algebraic effects, just without the
  'multiple types of effects' and without the 'handlers' concepts" one message earlier. Uncontested.
- **2026-09-01/09-09**, the idea resurfaces unprompted in `#ideas › Capability-based security`: Karl's
  flat statement (§0.3), Feldman's `Caps` sketch (§0.2), and Luke Boswell's working `roc-ray` spike
  restricting effects behind a `--host-caps-allow-all` flag, default-deny
  (github.com/lukewilliamboswell/roc-ray/pull/201, 2026-09-09).
- **2026-09-04**, sibling thread: Kasper Møller Andersen asks for the missing canonical list — "It
  would be nice to list out all the things that we expect platform authors to be responsible for...
  The platform controls: System calls in general, including..."
  (https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Platform.20extensibility.20using.20bundle.20of.20effects.20pattern/near/621654240).
  Feldman's reply is a one-line endorsement, "that sounds right to me!" — not a published policy.

**What this is not:** a type-checker feature. Purity inference's lattice has exactly two non-unbound
states; no thread proposes a third `FlatType` dimension for effect kind. The granularity beni wants
exists in Roc only if a platform opts in by exposing a `Caps.Net`-shaped argument type — `basic-cli`,
the default platform, does not: "I definitely don't think this should be `basic-cli` itself though -
`basic-cli`'s job is to be basic"
(https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Capability-based.20security/near/621931184).
As of 2026-09-14 this is the community's agreed *direction*, not a shipped default.

---

## 4. The one finer-effects proposal actually made, and its fate

**3-arg `Task`** (§0.1) is the only type-level named-effect-set design found, built and removed.
Fate: superseded by module params, then Task itself deleted (Jan 2025, `roc-purity-inference.md`
§3.4); Brendan Hansknecht at the time: "you could have both... A platform would have to roll their
own task type to get 3 arg tasks (which a very security focused platform might)"
(https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Algebraic.20Effects/near/432815740)
— even at deprecation, the exit ramp was "a platform can build this," the same answer that recurs
through 2026.

**The capability-token design** (§0.2–0.3) is the live proposal: a Zulip sketch (2026-09-05) plus one
unmerged platform-side spike (`roc-ray` #201, 2026-09-09), explicitly exploratory per its own author.
No language-level change (new syntax, new unifier case) is proposed anywhere — it sits entirely on
top of purity inference's existing single bit plus ordinary argument types. (`#ideas › Purity
inference proposal v3` was also checked as a candidate near-miss: it mentions platform-defined effect
*classes*, but for compiler scheduling of continuation-machinery, not programmer-visible effect
names — not on point.)

---

## 5. Ranked summary

1. **(documented)** Roc built and removed a genuinely Flix/Koka-shaped mechanism (3-arg `Task` with
   `[NetworkAccess, FilesystemRead]` tags) specifically because a closed tag vocabulary couldn't
   express the granularity users wanted (per-domain, per-path) — not because granularity itself was
   unwanted. `#beginners › Algebraic Effects`, 2024-04-11.
2. **(documented)** Roc's live 2026 answer to "which functions touch the network" is capability
   values passed as ordinary arguments, proposed by Feldman and spiked against `roc-ray` — but
   platform-defined and opt-in, not part of purity inference or the default `basic-cli` platform.
   `#ideas › Capability-based security`, 2026-09-05/09-09.
3. **(documented)** A core contributor (Ayaz Hafiz) stated on the record that purity inference *is*
   multi-effect-type algebraic effects with handlers, with the platform as sole handler author —
   "the platform is the capability boundary" is Roc's own claim, never contradicted. `#ideas ›
   function effectfulness syntax`, 2024-08-29.
4. **(inferred)** The trade-off was reasoned about at the semantic-primitives level ("keep primitives
   small," "high bar for irreducible primitives"), not as a dedicated critique of effect-row type
   systems by name; no thread engages Koka's or Flix's row polymorphism on its own terms.
5. **(unverified)** Whether `basic-cli` or another mainstream platform ships the `Caps` pattern by
   default is open; the September 2026 threads end without a merged PR or RFC.

---

## 6. What was not found, and searches run

**Not found:** a thread naming Koka or Flix in connection with granularity (zero hits for either,
anywhere); a proposal to add a row-polymorphic or set-valued effect annotation to Roc's type system
itself (as opposed to ordinary argument types); any quantified post-mortem of "the bit fired but the
specific effect didn't matter"; a canonical, agreed list of what a platform must expose as
capabilities (Kasper's 2026-09-04 ask went unanswered beyond one endorsement, §3).

**Searches run:** full-text `effect sets`, `named effects`, `algebraic effects`, `effect rows`,
`capability`, `fine-grained`, `which effects`; topic listing `ideas --grep capab`. **Threads read**:
`#beginners › Algebraic Effects` (68 msgs, full), `#ideas › function effectfulness syntax`
(granularity-relevant segment), `#ideas › Purity inference proposal v3` (targeted), `#ideas ›
Platform extensibility using bundle of effects pattern` (capability-relevant segment), `#ideas ›
Capability-based security` (30 msgs, full), and a skim of `#beginners › What does the Roc community
mean by "effect"?` (Haskell-terminology debate, not cited). Not searched separately, redundant with
the above: "Koka"/"Flix" (absence already confirmed), "Unison" (surfaces only in the 2024-04-25
comparison, quoted above), "Task + effect type" (subsumed by the 3-arg `Task` thread), "sandboxing
effects" (subsumed by "sandboxed access," §0.1).

**Plainly:** the community did discuss granularity, more than once across two years, and converged —
without calling it this — on "granularity is the platform's job, expressed as capability values, not
the compiler's job, expressed as effect names." That's a real answer, not silence, but it is a
2026-in-progress design, not a settled 2024 decision baked into purity inference the way the
pure/effectful bit itself is.
