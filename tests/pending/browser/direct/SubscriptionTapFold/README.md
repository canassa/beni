The intended builder uses destructive focus, starting with `Dict.empty` and
threading each replacement through `List.foldl`. No old dictionary is retained
and no tap-list container is inserted at a second key. Repeated opaque taps
intentionally share their callbacks, which the append does not mutate.

Pinned refusal on 2026-10-14, at Main.beni:15:69:

> `Main.want` changes `d#Dict.0#Node.2.1` in place, and the checker cannot show
> that nothing else still holds the list.
>
> This is a limit of the checker, not proof of sharing: it needs what List.foldl
> supplies it not to share, and it may.

The code and count are pinned in tests/pending/RED. The browser-tea oracle is
tests/corpus/browser/tea/SubscriptionTapFold.beni, with the same expected page.
The isolated focused helper is accepted in
tests/corpus/browser/direct/SubscriptionTapAppend. The aliased-input helper in
tests/corpus/build/bad/direct/OwnershipSubscriptionTapAliases stays rejected.
