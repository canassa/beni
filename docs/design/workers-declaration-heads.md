# Declaration value nominal heads

Specified 2026-10-30 for workers entry discovery. This module artifact is separate
from the site-only partial ContinuationPlan. It changes no language semantics,
source annotations, entry validation or runtime behavior.

Publish Dispatch.decl_heads, one row per BIR declaration, while Module's solved
store is alive. A row is the actual nominal TypeId of a value scheme's outermost
head after expanding aliases, or none. Preserve nominal identity even when its
arguments are symbolic. A function returning Program, a record containing Program,
unit, a bare variable and declarations outside the value namespace have no head.
This is a shape fact only; it proves neither an entry-kind contract nor launch
safety. No annotation is required and private declarations are included.

The existing dispatch sidecar format16 carries a distinct heads column. TypeIds
are encoded through its existing stable package/declaring-module/type reference
table, then resolved into the current session before installation. Validate every
reference, require exactly one row per BIR declaration in a clean module, and
reject nominal rows on nonvalue declarations. Unknown nominal identities or
malformed counts/references are cache misses. Old sidecar versions are misses.
No public interface format change or TypeKeys.wild fallback is involved.

Modules with their own or dependency errors publish no usable metadata. Reset
previous heads/continuation artifacts before revalidation and clear them after
a source/compiler diagnostic. Preserve Session.storeEntries' existing rule:
error modules are not cached; only clean modules and warnings are cacheable.
A missing clean-module plan is a miss, never an implicitly complete empty plan.
Restoring an earlier clean source may reuse its still-valid old cache entry.

Entry discovery consumes these immutable resolved rows along with its existing
metadata/evidence. It must still perform all required entry proofs and distinguish
actual declarations and packages. Tests cover inferred/private/polymorphic values,
alias heads, function/record negatives and cold/warm cache identity preservation.

The hidden continuations inspector prints a separately labeled declaration-heads
section, including explicit none rows, for black-box identity/negative checks.
This does not make heads part of the site-only plan or certify entries.

Typed Program declaration and role-root prerequisite: [workers-typed-entry-roots.md](workers-typed-entry-roots.md).
