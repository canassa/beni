# Private Schema endpoint identities

Schema's source builders now receive checked endpoint identity demands through
the same channel as Any.pack. A private compiler-owned witness replaces packing
empty lists and slicing their type text. Generated producers and source builders
use the same typed constructors and identity grammar. Any exposes pack/unpack
only; its unsupported fingerprint operation is removed (#1771).

Release linking numbers compiler-marked identity atoms in lexical order before
specialisation. This is an injective private alphabet, with no module/type-name
strings in identity metadata. Checked dispatch retains the original demands;
numbering occurs after cached lowering, so caches cannot retain stale ordinals.

Imported generic builders agree with generated descriptions in development,
release, compiled and forced-library builds, cold and warm at one/eight jobs.
Those checks passed twice with both native backends. The new release golden
failed twice with numbering omitted and passed twice when restored. Packet/Box
unpack and generic Any tests also passed twice. Full gates remain for the final PR.

Performance parity is still open. Two locked CPU-pinned base/current comparisons
put library flat decode at 2.1–2.5x base and list decode at 2.5x; encode is also
above 1.2x. Compiled measurements show no consistent regression. Repeated CPU
profiles put small List growth and the field traversal among the remaining costs.
Evidence and exact samples are in hostfree-review1/schema-cleanup/parity on dagon.
The next change targets offsets and typed array construction in that traversal.
