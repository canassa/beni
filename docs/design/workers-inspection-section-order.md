# Composition of diagnostic entry suffixes

Integration-only protocol note: existing compact/typed/native-realm sections retain their complete byte prefix. The ordinary solved-provenance section follows that prefix, then the owned anchored-role section is last. Exact schema1 headers and negative proof flags are unchanged. No language, proof or public execution semantics change.

Legacy prefix tests first validate and strip the complete role section, then validate and strip the complete solved section, then apply their unchanged native-realm grammar. Neither suffix may be cut at a marker without parsing its entire known grammar/counts. Unknown rows/fields, extra/truncated sections, positive HostFree/Wire flags, bad enums/IDs and inconsistent original/reached/root/formal counts fail.

The generic solved reader accepts any valid original graph, including zero roots, no aliases/nominals, and an empty inventory. Per module it checks D/T/E/F/parent counts; original R/Q and observed reachable nodes/edges; root/formal/node IDs and enums; known edge kinds/order/selectors; all referenced reachable nodes, formal variable kinds and exact shared reachable union. It does not reconstruct the ordinary solver or infer a proof from the graph. Repeated display names are not global identity: IDs are scoped by the actual module block.

Fixture-specific solved tests retain their stronger actual-source expectations for entry/nominal/alias roots. They validate the final role suffix before their existing solved assertions. Pure malformed-text controls supplement the unchanged real source/cache scenarios. Root owns production preflight/order/error-union integration; this helper slice changes test parsing only.
