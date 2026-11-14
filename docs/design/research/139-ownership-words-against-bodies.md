# 139 — Ownership words against bodies, measured

Report 137 §5.2 ("Part 1 — trust is marked, and words are checked") proposes a rule: where a
declaration has ownership words and a beni body, the words may claim less than the checker's walk
of the body derives, and never more unless the declaration is marked `trusted`. This report
measures that rule on the code as it is. It is the "trust report" of part 1, measured, not designed.

Checker: `src/own3/` (`--ownership=v3`) at `a982e4641d` (branch `ownership-v2-design-review`).

## 1. Summary

- `core/` and the six platforms have **88 worded declarations**. 29 are `foreign` (all in `Js` and
  `List`); part 1 does not touch them. **59 have a beni body.** `html` and `cloudflare` have none.
- Of the 59, the walk derives **the same contract for 1** (`Schema.print`). For **58 the words claim
  more** than the walk derives. **No declaration has words weaker than its walk.**
- 45 of the 58 claim more because the body (or an unworded helper it calls) hands the value to `Js`,
  where it escapes. 8 more claim only `entry`, which no walk can derive today (10 claim it in all). 3 are typed beni whose words
  are true but beyond the kernel (a list written at one index, a merge sort). 2 differ only because a
  callee's own words give `outside`.
- **I found no false word.** For every case that does not go through `Js` I read the body and judged
  the word true. Eight probe programs aimed at those words: seven are refused, one is accepted and
  runs the same. No TRAP, no DIFF.
- So part 1, as written, needs **58 `trusted` markers** (56 if the comparison treats `outside`
  handed to a function that may not write as harmless; §4). Part 1 alone would find **no real bug**
  in today's words.
- Report 137's two examples are not in part 1's reach: `Js.lt` is `foreign` (and its word was
  already removed), and `#2504`'s code carries no words.

## 2. How it was measured

v3 already walks a worded body, for its own verdicts, after every contract of the module is known
(`Check.zig`, `checkModule`). It then keeps the words as the contract and drops the walk's result.
The instrumentation (kept out of the tree, in the scratch file `instrument.patch`, 156 lines) keeps
both and compares them. For each worded declaration it prints the words' contract, the walk's
contract and a class:

- **match**: the two contracts are the same.
- **words weaker**: the words are more pessimistic somewhere, and nowhere less.
- **words stronger**: somewhere the words claim more than the walk.
- **foreign**: no body.

"Claims more" is checked on every part of a contract (kernel §4):

- a parameter location that the walk writes, lets escape, hands to a writing function, or reads, and
  the words do not;
- a source of a result location that the walk found and the words do not cover. A source covers
  itself; `outside` covers any new cell; a new cell that does not escape is also covered by a
  parameter or an answer (more aliasing is the safe side); a new cell that escaped (`fresh!`) is
  covered only by `outside` or another escaped new cell;
- two result locations that share one new cell in the walk, apart in the words;
- `nonlinear` set by the walk and not by the words; `old_result` likewise;
- `taken` and `entry` claimed by the words (no walk sets them);
- for a function parameter: a slot the words leave free that the walk does not; a source the walk
  hands it that the words do not; `called`, `lost`, `ans_escapes` or `rewrites` set by the walk and
  not by the words; a function the walk does not follow and the words do.

The walk is the check part 1 asks for: it uses the words of every other declaration, including
the declaration's own words at a recursive call. So a declaration is judged against its callees'
contracts, as a caller would be.

Each package was checked under its own platform: a small platform package that imports every module
of the package, built with a self-hosted ReleaseSafe `beni check --ownership=v3`. `core/` was
checked under `node`; `html` under `node` and `browser` (no words under either).

## 3. Counts

| Package | Worded | `foreign` | With a body | match | words weaker | words stronger |
|---|---:|---:|---:|---:|---:|---:|
| `core/` | 74 | 29 | 45 | 1 | 0 | 44 |
| `browser` | 2 | 0 | 2 | 0 | 0 | 2 |
| `browser-inline` | 4 | 0 | 4 | 0 | 0 | 4 |
| `browser-tea` | 4 | 0 | 4 | 0 | 0 | 4 |
| `node` | 4 | 0 | 4 | 0 | 0 | 4 |
| `html` | 0 | 0 | 0 | — | — | — |
| `cloudflare` | 0 | 0 | 0 | — | — | — |
| **All** | **88** | **29** | **59** | **1** | **0** | **58** |

Every walk finished: no declaration hit a limit or gave up, and no contract had another shape.

`core/`'s worded modules: `Js` (25, all `foreign`), `List` (22, of them 4 `foreign`), `String` (7),
`Task` (6), `Ref` (5), `Deferred` (5), `Debug` (2), `Schema` (2).

## 4. The words-stronger list

### 4.1 The body hands the value to `Js` (42)

The walk derives what kernel §6.10 says of `Js`: the value escapes, and an answer from `Js` is
`outside`. The words state what the JavaScript really does. Each needs `trusted`; none can be
derived without teaching the checker JavaScript, which report 137 §3.2(a) rejects.

| Declaration | What the words claim beyond the walk |
|---|---|
| `Ref.make`, `Ref.get`, `Ref.set` | a cell's contents: `cellnew`, `cellread` read without escape |
| `List.cons`, `append`, `set`, `push`, `pop`, `insertAt`, `removeAt` | parameters do not escape; the result is the list or new storage, its elements are the inputs', linear |
| `List.copy`, `sliceOf` | `copyof`: new storage, elements of π1, linear |
| `List.unsafeGet`, `view`, `base`, `offset` | `elementof` / `returned`: no escape; the answer is π1's element or storage |
| `List.builder`, `List.done` | `fresh exclusive`, `builderdone` |
| `String.words`, `lines`, `split`, `indexes`, `toList` | `fresh exclusive` result (walk: `outside`) |
| `String.fromList`, `String.join` | `borrowed` list does not escape |
| `Task.spawn`, `spawnIn`, `spawnDetached` | `cellempty` result (walk: `outside` and the function) |
| `Task.join` | `cellread` fiber does not escape |
| `Task.raceOk` | elements do not escape; `fresh` result |
| `Task.timeout` | `once`: the work goes nowhere unknown (walk: lost to `Js`); `fresh` result |
| `Deferred.make`, `wait`, `complete`, `poll`, `isDone` | cell words |
| `Node.print`, `Node.printLines`, `Node.exitWith` | `fresh Program` (walk: `outside`); `printLines`' list does not escape |
| `Ssr.render` | `borrowed Html` does not escape |
| `Browser.program`, `Browser.hosted` | `entry` (§4.3), and `hosted`'s record fields do not escape |

### 4.2 An unworded helper hands the value to `Js` (3)

The body is typed beni, but it calls a helper without words whose body uses `Js`, so the walk
derives escape through the helper's derived contract. Each needs `trusted`, or words on the helper.

| Declaration | Helper | Claim beyond the walk |
|---|---|---|
| `Debug.log` | `logAs` (`console.log`) | `returned a` does not escape |
| `Debug.toString` | `toStringAs` | `borrowed a` does not escape |
| `Schema.printWith` | `compiledPrintReady` (`Js.apply worker …`) | schema and value do not escape; `fresh` result |

### 4.3 `entry` (8 more, 10 in all)

`entry` is a claim no walk can make today: the kernel has no state thread (report 137 §2.5, §5.3).

- `browser-inline` `Tea.sandbox`, `element`, `document`, `application`: the body is
  `unreachable "Tea.…"`; the `inline` lowering compiles the program. The walk derives nothing
  (no flag, one new cell). Only `entry` differs.
- `browser-tea` `Tea.sandbox`, `element`, `document`, `application`: typed beni that calls
  `Browser.program` or `Browser.hosted`. At that call the entry rule (`Frame.entryCall`) lets each
  field of the record escape, so the walk finds the record's fields escaping and no `entry` of its
  own. With part 2, these four are the ones that could become derived, from `Browser.program`'s
  and `Browser.hosted`'s contracts.
- `Browser.program`, `Browser.hosted` (listed in §4.1): `entry` plus `Js`.

### 4.4 Typed beni, a true word the kernel cannot see (3)

| Declaration | Claim beyond the walk | Why the walk derives less | Verdict |
|---|---|---|---|
| `List.swap` | result elements linear (no `twice`) | `set (set xs i y) j x`: the walk sees `y` stored at `i` while still at `j`; it has no rule that the second `set` replaces index `j` | **true**: each element ends at one index |
| `List.focus` | `once taken`: the function may write the element it is handed (`free`) | `set xs i (func (unsafeGet xs i))`: the element is still in `xs` during the call; the walk does not see that `set` then replaces index `i` | **true**: nothing reads index `i` before it is replaced, and an element that is at two places is refused by the caller's `twice` rule |
| `List.sortWith` | result elements linear | `merge` puts each element into a builder by index arithmetic; the walk cannot count that each goes to one index | **true**: a merge sort is a permutation |

### 4.5 A callee's own words (2)

| Declaration | Claim beyond the walk | Verdict |
|---|---|---|
| `Ref.update`, `Ref.modify` | the function is handed only cells of the parameters; the walk hands it `outside` (`Ref.get`'s `lent` result) | **true, and harmless**: the function may not write what it is handed (not `free`), so handing it `outside` asks nothing more of anyone. A comparison that knows this would class both as match or weaker. |

## 5. Probes of the true-but-unseen words

The probes are in `bench/ownership-sweeps/words-faults/` (results in `words-faults.v3.txt`). Each
aims at one way the words of §4.4 could be wrong: an element held under another name, two places of
one element, a function that reads the list it updates.

| Program | Aim | Result |
|---|---|---|
| `update-alias` | `List.update` (via `focus`) writes an element that another name holds | REFUSED `later-use` |
| `update-dup` | `List.update` on `List.repeat [ 1 ] 2`: one list at two indexes | REFUSED `element` |
| `update-self` | the function reads the list being updated | REFUSED `disjoint` |
| `sort-alias` | write an element of `sortWith`'s answer while the input is read | REFUSED `later-use` |
| `sort-dup` | `sortWith` of one list at two indexes, then write one | REFUSED `element` |
| `swap-dup` | `swap` of one list at two indexes, then write one | REFUSED `element` |
| `swap-same` | `swap xs 0 0`, then write an element another name holds | REFUSED `later-use` |
| `swap-fresh` | `swap` of two new elements, then write both | SAME |

No TRAP and no DIFF. The duplicates are caught by the caller's frame (`twice` at the element
location), not by these words, which is why linear words on `swap` and `sortWith` are safe.

## 6. What this says about report 137 part 1

- **The trusted set is nearly everything.** 58 of 59 worded bodies would need `trusted`. That is the
  expected result of report 137 §5.2's own example: the boundary's bodies go through `Js`. But it
  means part 1, today, is a list of 58 names, not a check that finds faults.
- **Part 1 finds no bug now.** Every word I could judge is true. The value of part 1 is for the
  future: a word added on typed code (like `swap`, `focus`, `sortWith`, the `browser-tea` `Tea`
  functions) becomes checked, and a new `Js` body must say `trusted`.
- **Three words would turn into precision losses or `trusted` for a kernel reason.** `swap`,
  `focus` and `sortWith` are typed beni whose words are true. Part 1 must either mark them `trusted`
  or the kernel must learn index-precise replacement. Report 137 does not mention this class.
- **Two differences are artefacts of a strict comparison.** `Ref.update` and `Ref.modify` should not
  need `trusted`. The comparison part 1 specifies must say that `outside` in a supply that the
  function may not write is no claim.
- **`entry` is 10 of the 58.** Part 2 (the state thread) could derive the four `browser-tea` ones from
  `Browser.program`/`hosted`. `Browser.program`/`hosted` stay trusted (`Js`). The four
  `browser-inline` ones have a placeholder body; their contract is the lowering's, which is part 4's
  territory, not part 1's.
- **Typed-but-`Js`-through-a-helper is a real class (3).** `Debug.log`, `Debug.toString` and
  `Schema.printWith` are typed; only a helper uses `Js`. Words on the helpers, marked `trusted`,
  would move the trust to the smaller declaration.

Report 137's examples, checked:

- **`Js.lt`.** It is `foreign` (`core/Js.beni:73`): part 1 never checks a `foreign`. Its wrong word
  was already removed (commit `a3b381ba7a`): the operands now carry no word and escape. Part 1 would
  not have caught it; only a review of `foreign` words can.
- **`#2504`** (`platforms/browser/Rt.beni:1342-1350`, `startRows`). Its signature is
  `V, V, V, … → Int`, with no ownership word. Part 1 has nothing to compare there. The fault is in
  the hand rule of `boundary.md` §9.4.8, which report 137 gives to part 4. The data agrees.
- **"How many `trusted`."** 58 under the strict comparison; 56 with the supply rule above; 52 if
  part 2 derives the four `browser-tea` entries; fewer only if the kernel learns index-precise
  replacement (3) or helpers get their own trusted words (3 moved, not removed).

## 7. What I could not measure

- **The 29 `foreign` words.** No body, so nothing to compare. `Js.lt` shows that is where a wrong
  word lived.
- **Type-alias words** (`sender`, kernel §6.13) and the platform manifests' `entryKinds`: they are
  not declaration words, and the instrumentation does not see them.
- **New-cell names.** The walk numbers new cells by allocation site and the words by result
  location. I compared them by escape and by sharing between result locations, not by name. A
  difference that only the names would show is missed.
- **Contracts relative to callees.** Each walk uses its callees' words. A declaration that matches
  only because a callee's words are trusted (for example `Schema.print`, through `printWith`) is
  "match" relative to that trust.
- **The walk's own soundness.** Where the walk derives more than the words (all 58), I trusted the
  walk's reading of the body; I did not check the walk.
- **Platforms on other lowerings.** `html` was checked under `node` and `browser` only.
- **Run time.** No build writes a list in place yet; the probes use the stale-read sanitiser, as
  every sweep does.

## Sources

- `src/own3/Check.zig` (`checkModule`, `wordedContract`, `walkDecl`), `src/own3/Contract.zig`.
- `docs/design/ownership-v3-kernel.md` §4, §6.10, §6.13, §7.
- Report 137, `docs/design/research/137-ownership-and-the-platform-boundary.md` §2.1, §2.5, §3.2,
  §5.2 (branch `platform-boundary-study`, #2509).
- `core/List.beni`, `core/Ref.beni`, `core/String.beni`, `core/Task.beni`, `core/Deferred.beni`,
  `core/Debug.beni`, `core/Schema.beni`, `core/Js.beni`, `platforms/browser/Browser.beni`,
  `platforms/browser/Rt.beni`, `platforms/browser-inline/Tea.beni`, `platforms/browser-tea/Tea.beni`,
  `platforms/node/Node.beni`, `platforms/node/Ssr.beni`.
- Probes: `bench/ownership-sweeps/words-faults/`, results `bench/ownership-sweeps/words-faults.v3.txt`.
