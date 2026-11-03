# Follow Schema provenance through typed evidence

The decoded-record regression #1757 came from an evidence-count assumption.
Json decoders and Schema's derived/structural entry points have one codec method
requirement, followed by independent identity and checked-data witnesses. The
ownership bridge required exactly one total root and therefore treated known
codecs as unknown. It now reads the codec method root independently of the
representation witnesses, preserving the existing conservative unknown case.

Conversion-slot analysis also still projected a former erased Pair. It now
reads the actual typed Conversion constructor fields, retaining the captured
callback classes. This restores the specific top-level-record refusal for
RecordConversionAnswer. SchemaConversionShared still reports a conservative
escape instead of its captured-holder explanation; that review item remains
open. No escape checks or callback demands are removed.

The imported-record positive fixture fails with record_may_be_shared twice
before the fix. It prints2 through both compiled/library paths, in dev/release,
cold and warm caches, with jobs1/8. The targeted ReleaseSafe black-box scenario
passes twice. All nine affected inline loader projects check and build in dev
and release with ownership everywhere twice, without source changes. The
shared-record conversion remains refused twice as top_level_record_changed.

Evidence: `~/worktree-evidence/hostfree-review1/schema-ownership-evidence/`.
Full gates and complete run hashes remain for the completed PR under the shared
lock. This checkpoint closes #1757; the remaining diagnostic and performance
review work is explicitly unfinished.
