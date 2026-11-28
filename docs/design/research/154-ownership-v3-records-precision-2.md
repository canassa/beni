# 154 — Ownership v3: records precision, round 2

*Research report, 2026-11-18. The second lane of the records precision round of the checker v3
(`--ownership=v3`, `src/own3/`): win back safe programs v3 refuses, without losing soundness. Issues #2552,
#2548 and #2532. It revises kernel (`ownership-v3-kernel.md`) §4.4 (*The parts of a list pattern are
apart*), §5 test 1, §6 rules 1 and 10, and `boundary.md` §9.8.3.*

---

## 1. Result

| Issue | Rule | Won | Left |
|---|---|---|---|
| #2552 `Hosted.compare` | the row rests on `Hosted`'s body: a private table of comparers that only `key` writes (§2) | `Tea`'s nine evidence refusals of its tables | **v1 reads the row and enforces no evidence in a platform layer: a hostile layer's key traps under v1, which the base v1 refused (§2, owner decision #2556)** |
| #2548 item 1, element walks | the parts of a list pattern are apart where the list holds each cell once (§3) | 55 lines of 22 roots: `PrettyPrinter`, the `dom`/`tea` `Keyed` pages' `rotate`, 11 corpus fixtures | a scrutinee that is a call's answer whose root is not `linear` (`List.map`) |
| #2548 items 2–4, #2532 items 2 and 4, #2518 | not built: each needs a fact of its own (§5) | — | see §5 |

- **Real-writes ledger** (`ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): **294 of 308 before and
  after**, row for row. v3 refusals at positions v1 has no line for: **39 → 18** (Tea's five evidence lines;
  `bench/corpus` `PrettyPrinter`'s sixteen).
- **Verdicts on every ownership root** (§6): refused → accepted 61 lines; accepted → refused 14 lines, in two
  roots that were refused before and after, 13 of them unsafe writes v3 had accepted at the call (§4).
- **Sweeps** (§7): 88 867 programs, the three known faults only.
- **Two reviews** (§8): three faults, each fixed with a fixture.

## 2. `Hosted.compare` borrows both keys (#2552)

The owner's condition was that every `Key` come from `Hosted.key`. It is not enough: a real key carried its
comparer in a writable property, which a platform can overwrite (`Js.set (Js.from k) "c" …`), or a sibling on
any value handed at a type variable. A construction fence would need a new interface bit for every quantifier
a cast or a `Js.from` reaches, and a fence on generic `foreign` parameters in project platforms, and would
still leave this. So the fact moved into `Hosted` (comment on #2552 before the edit): a private `Map` from a
type identity to that type's `compare`; `key` is its only writer (`register`, `Js.pure`, so `key` stays pure)
and builds `{ t, v }`; `compare` reads the comparer from the map, never from a key, and an identity with no
comparer is a defect. The row `compare : borrowed Key, borrowed Key → Order` is back.

- `browser/tea/KeyForgedKeeps` (a forged key whose comparer keeps it) and the new `KeyAltered` (a real key whose
  comparer property a layer overwrites): refused on the base, `TRAP` with the row on the old body, accepted and
  `SAME` in every leg now. `KeyForgedIdentity` pins the defect. `KeyCompareKept` stays the refused half.
- **First review, fault 1**: a project's own layer made a key of its own type whose `compare` kept its list.
  The evidence refusal was computed in the layer and dropped, since only the program's writes were enforced.
  Now a refusal of evidence stops the build of every package (`Enforce`, kernel §6 rule 10):
  `browser/tea/KeyLayerKeeps`. **v1 reads the same words and still accepts that program** (it traps; the base
  v1 refused it): v1 enforces nothing in a platform layer. v1 is out of this lane: the owner's decision is
  #2556 (v1 enforces evidence in every package, or the row is read by v3 alone, or the words are reverted).
- **First review, fault 2**: a layer that replaces `Map.prototype.get` reaches the table. Not fixed: a platform
  that changes a built-in changes it for every module, as it could the `Array` methods every sibling of core
  calls; the kernel text says so.
- Size: keyed `browser-tea` pages +38 to +107 bytes brotli in release (`bench/size.mjs`), the table and the
  defect's text.

## 3. The parts of a list pattern are apart (#2548 item 1)

`[ b, …rest ] → loop rest (List.push acc (write b))` was refused (`disjoint`, `later-use`): `b` and `rest` read
one summary location and no atom said at which position. Kernel §4.4 now says: where the scrutinee is a part of
a parameter (the apart-arguments rule) or of a `linear` root the frame made with no `twice` entry, each part of
one match carries its position (`Node.pos`, `Atom.pos`, `listParts`), and two atoms of one match at two
positions are two cells (`overlap`). A match is one run of the binding, not the instruction; an inner pattern
takes its own positions; a set with positions is tested in pairs, since `runsShare`'s tables key by `via`.

Fixtures: `run/PatternPartsApart` (a walk, `[ a, b, …rest ]`, `[ …init, last ]`; refused on the base, `SAME`
in every leg) and `run/PatternPartsShared` (a literal holding one record twice, and a parameter its caller
hands such a list: refused). Sweep family `precision-154.mjs` (`parts.<scrut>.<pat>.<write>.<read>`, `walk.*`,
`rot.*`): 188 programs, all refused on the base; 26 `dead` accepted and `SAME`, every `live` refused.

## 4. A function value's write below the handed location (second review)

`app [ r, r ] λl → case l of [ a, …rest ] → …` trapped: the lambda's parts are apart, and the call that hands
it a list holding `r` twice did not refuse, because a flow's write below the handed location was asked whether
the *handed* entry (the list) is single, never the written one (its elements). The base had the same hole,
hidden where the lambda refused its own write: `app [ a, a ] λl → List.map l push1` traps on the base
(`run/HandedListElements`). `OwnSink.atoms` now asks at the written location (kernel §5, test 1);
`run/PatternPartsHanded` is the review's program.

## 5. Not built

- **`List.set` over the element `List.get` read at the same index** (#2532 item 4: Sternhalma's `setOccupant`,
  Markdown 1271:22) and **`Dict.get` → write → `Dict.insert` at the same key** (#2548 item 2): both need a fact
  that the write replaces the element it was read from, which needs the index or key to be one value at both
  calls. Recommendation: a positional row, as §3's positions, keyed by a local bound once and not rebound
  between the two calls. `Dict` has a second wall first: `insert` reaches `insertHelp` through a
  `type_dispatch` (the key's `compare` chosen by type), whose answer is `unknown` over its arguments, so every
  value of a `Dict` built by `insert` holds `outside` (`Dict.singleton`'s is accepted). Recommendation: apply
  the join of the candidates' contracts at a `type_dispatch` whose candidates are declarations with contracts.
- **#2532 item 2** (`Gpu.Make`, budgets) and **#2548 item 4** (LIMIT in a chain of `Store.apply`): budgets,
  not verdicts; unchanged.
- **#2548 item 3** (a view helper of another module on `browser-inline`): the #2529 loader fact (report 153
  §5).
- **#2518**: not reached.

## 6. Verdicts on every ownership root

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 429 roots, base (`d9073fe718`) against
the last commit. Lines that only moved (a fixture's comment grew) are left out.

| Root | Change |
|---|---|
| `platforms/browser-tea` | nine `value <call Tea.table…>` evidence refusals gone (§2) |
| `browser/tea/KeyForgedKeeps` | `List.push ys` accepted (§2) |
| `bench/corpus` | `PrettyPrinter` 16 lines accepted (§3) |
| `browser/dom` Keyed, KeyedInPlace; `browser/tea` KeyedInPlaceMap, KeyedOriginal | `entry … rows[*].label=`/`.done=` accepted (§3) |
| `run/` SanitiserAnswers, SanitiserAnswersApart, SanitiserCallbackAnswerPending, SanitiserForwardedLabelApart, SanitiserLevelRead, SanitiserLevelResultEscaped(Apart), SanitiserPatternStoredBackApart, SanitiserSplitLocalLoop, SanitiserTraversalApart, SanitiserWideDistinctApart, SplitSingletonRest | accepted (§3) |
| `ownership/` ElementPositions, HolderRestApart, LimitSpine, RecursiveSiblings | accepted (§3) |
| `run/SanitiserOnceCallbackShared` | 13 calls refused (§4): each hands a list holding one list twice to a function value that writes its elements; the program was refused before by other lines |
| `ownership/FoldElementPaths` (`opaqueSharedKeys`) | `rows[*].1` refused (§4); the root was refused before (`rows`) |

**Refused → accepted: 61 lines. Accepted → refused: 14 lines, in two roots refused before and after.**

## 7. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both` with the self-hosted ReleaseSafe compiler: the sweeps
from `alias-ctors` to `blind4b` with §3's commit, the rest and the reviewers' programs with §4's (which only
refuses more). Faults are `TRAP`, `DIFF`, `IPTRAP`, `IPDIFF`, `RIPTRAP`, `RIPDIFF`, `CRASH`.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `corpus` | 1777 | 1244 | 512 | 1 | 3 | 12 BOTHFAIL 4 PLAINFAIL 1 TIMEOUT |
| `records` | 1876 | 353 | 1523 | 0 | 0 |  |
| `precision-154` | 188 | 26 | 162 | 0 | 0 |  |
| `precision-153` | 63 | 34 | 27 | 0 | 0 | 2 PLAINFAIL |
| `aliased-arguments` | 5160 | 1270 | 3890 | 0 | 0 |  |
| `answers-beside` | 240 | 90 | 150 | 0 | 0 |  |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 |  |
| `blind4b` | 6596 | 1270 | 5324 | 2 | 0 |  |
| `folds-callbacks` | 30300 | 5669 | 24631 | 0 | 0 |  |
| `recursive-levels` | 16131 | 3869 | 12262 | 0 | 0 |  |
| 39 other sweeps and fault folders | 16744 | 4185 | 12400 | 14 | 0 | 121 PLAINFAIL 24 TIMEOUT |
| **all** | **88 867** | 19 685 | 68 998 | 17 | **3** | |

The three faults are the known ones: `run/ListSanitiserTrieHolder`, and `dom` and `tea` `ShowAndBranches`
(#2504). Against report 153's table, 704 more programs are `SAME`. The reviewers' 168 programs, rerun: one
`TRAP`, the `Map.prototype` program (§2).

## 8. Reviews

Two fresh adversarial readers (Opus).

- **After #2552** (45 programs): two faults, §2's. Fault 1 fixed (`KeyLayerKeeps`); fault 2 answered.
- **After #2548** (123 programs): one fault family, 12 programs, §4's; fixed (`PatternPartsHanded`,
  `HandedListElements`). Everything else they tried was refused or `SAME`: lists holding a cell twice built by
  `push`, spreads, `++`, `concat`, `reverse`, `set`, `update`, `sortWith`, `filterMap`, joins, `Ref`, captures;
  deeper sharing; recursion; `as`; escapes; `rest ++ [ x ]` variants; a Tea `init`.

## 9. Timing

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real`, ReleaseFast LLVM compilers of the
base and the last commit: v3 on the 33 real roots **1 308.8 ms → 1 297.9 ms** (−0.8 %, within noise).

## 10. Reproduce

```sh
node bench/ownership-sweeps/precision-154.mjs <dir>/p154
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/p154
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=PatternParts   # and HandedListElements, tea/Key
```
