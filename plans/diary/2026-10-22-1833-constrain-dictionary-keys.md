# Dict keys and Set members are scalar

Part of #294. Tea's private ordered tables landed in #776 after hosted entry
ownership in #767. The platform no longer needs general Dict keys, so Dict and
Set can now require Int or String at type formation.

The restriction is a closed kind constraint, including the numeric/Int and
appendable/String intersections. A module prepares nominal parameter facts with
a dependency worklist and memoized alias projections. Those facts survive opaque
bodies, inference, generalized schemes, interfaces and cache installation. An
internal Dict use constrains a public function even when no Dict appears in its
exported type. Unsupported heads produce invalid_dict_key and name the key type.

Public collection operations need no key comparison evidence. Their internal
scalar bridge keeps String's Unicode scalar ordering. Collections have no
compare, and default derivation refuses enclosing shapes; a user wrapper can
still declare its own comparator. The current tree, empty constants, traversal
and equality stay until the separately scheduled representation change.

Red fixtures were accepted by the previous compiler before implementation.
Coverage includes each refused key head, unused annotations, local/imported
generics, opaque facts, forward aliases, schema endpoints, key-kind intersections,
command/subscription keys, default comparisons and cached importer invalidation.
The positive module-boundary fixture and runtime Unicode/wrapper checks pass.
The build/check suites, digest/interface units and affected corpus checks pass.

Old list-key ownership probes now fail earlier in build/bad. Their sibling-value
sharing probes remain refused. The subscription accumulator probe assigns scalar
keys while preserving opaque taps; its demand verdict counts are unchanged.
No ownership check was weakened and no copying fallback was introduced.

An additional reduction found a late schema-conversion projection that initially
lost the wrapper's key fact. Endpoint alias identity must be read before chasing
its actual type, and conversion inference must finish parameter facts before
publication. Newly narrowed domains validate earlier live formations once. Local,
imported-function and warm/cold opaque-schema twins now cover this path; using the
same schema at Bool outside the dictionary wrapper remains accepted.

The browser fold probes now give their known single subscription an Int key,
retaining the opaque tap values. Sternhalma's coordinate Dict and Set use a
separator-delimited String key; the page transcripts remain unchanged.

The architecture gate required dense columns/bitsets for parameter bindings and
visited regions, registration of the new checker files, and splitting kind
messages out of Diagnostics. No allowlist exception or file-size rule changed.
