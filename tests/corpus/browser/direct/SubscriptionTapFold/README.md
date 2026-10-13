Formerly CK-224 in tests/pending: the checker rejected Main.want inside the
List.foldl callback, although the builder starts with Dict.empty and threads
only replacements. The dated fold-invariant amendment in ownership-checker.md
proves ownership of the tap-list containers without claiming that opaque taps
own their captures. No List.copy is required.

The browser-tea oracle is tests/corpus/browser/tea/SubscriptionTapFold.beni,
against the same page golden. The isolated focused helper is
SubscriptionTapAppend. FoldRight, DictFoldLeft and DictFoldRight also edit the
returned dictionary, pinning preservation of the invariant in the fold result.
Rejected build twins are OwnershipFoldEscape, OwnershipFoldClosure,
OwnershipFoldSecondKey and OwnershipFoldSharedStart.
