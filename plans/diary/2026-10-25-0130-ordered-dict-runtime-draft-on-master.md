## 2026-10-25 01:30 CEST — Ordered Dict runtime draft on master

**What I did**

Opened #951, a small skill PR: the `invalid_dict_key` rule now has a
refused block in `types-and-dispatch.md`. The key restriction itself landed
earlier in #793.

Ported #294's preserved runtime draft (base `c02d78b92`) onto current master
as a draft PR. I took `core/Dict.beni`, `core/Dict.js` and `core/Set.beni`
whole. The draft's key-constraint and Tea-table parts were left out, because
#793 and #776 replace them. The draft's `src/own` hunks were merged by hand.
Master had added more tree special cases since the base, and they are deleted
too: the `representative` flag, `rootSeparation`'s arrival rule,
`pairwiseApartOnce`'s core-Dict branch and the focus supply's tree scope.
`Dict.empty ⊤` and `Set.empty ⊤` are now calls in every `.beni` file.
`DictFocusGrow` (#663) is accepted again, so it moved from `tests/pending` to
the corpus.

Foreign Dict needed two checker changes, so that a missing compare is still
the collection rule's message and not `unknown_method`. The browser
platform's `Http.headersFrom` changed from a `Js.ref` loop to a
`List.foldl`. The checker cannot see into a `Js.ref`, so the old loop
refused the platform's own body. The new fold is ownership-clean.

Run fixtures that read a live old Dict or Set after a write now take
`Dict.copy`/`Set.copy`. Fixtures whose output was key order now print
insertion order or sort explicitly. Their comments say which.

**What I learned**

A fold over a `⊤`-valued collection drops its result's provenance, on master
too (#952). Because `Set t` is `Dict t ⊤`, a top-level set built by
`Set.fromList` can be written in place with no refusal. That is an unsound
acceptance, not a precision loss. `CoreSetRest` showed it as a wrong output.

The draft's storage message suggests `Dict.copy` even when the cause is
shared values, and a shallow copy does not fix that (#958).

#681 still holds: a default node build accepts a write to a live old Dict
and prints `2/2`. It is pinned as `tests/pending/build/bad/DictLiveOldNode`
until #320.
