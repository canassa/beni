## 2026-10-30 14:29 CET — Ownership v2: imported calls (S3b slice 3)

**What I did.** Opened #1316 and built it on `own2-s3b3`. Under `--ownership=v2` a call of an
unworded declaration of another module was `.unbuilt`, so every caller of an imported summarised
function stayed unchecked. Now `Groups.callee` asks `Groups.Imports` for the callee module's
classes; `Enforce.ImportReader` reads that module's published block from its interface (once per
importer, at the first call), resolves its names in the session (heads by qualified name, fields
by text, shared values by `Module.name`, instructions in a namespace of the importer's past its
own) and decodes it with `BlockRead.read`. `Ownership.publish` writes a directory beside the string
table — `(declaration name, applies)` per class, `applies` clear for a walk left unbuilt or stopped
at a limit — and the block version is 12.

The first working version held v1's verdicts on the whole corpus, but a new fixture
(`CallOtherPathsImported`, `CallOtherPaths` with its callees in two other modules) refused
`depthsDistinct` where the same-module fixture accepts it, and an imported `CallChainShare`
counted test grew per call (2 137 records a call at 160 calls against 731 same-module). Both had
one cause: a block's places are a namespace of their own, so `Calls.argAt` met the caller's
`Tree` and `List (List Int)` as recasts. §2.1 says the reader re-interns a block's places onto its
own graph; §8 gives that to S6, but S3b's own acceptance (imported forms agree) needs it now. So
the commit of `BlockRead.read` re-interns every place whose structure alone names the adapter's
node (`Adapter.ownPlace`: a nominal type of no parameters, a crossing type, a sequence or cell of
a named element, a record or tuple of named fields, a leaf), checked by `Place.equals`, and the
parts below it by a walk of the pair of graphs. For that, a crossing type's place now carries its
`TypeId` and `⊤`'s leaf none (they were all `(cross, 0)`). With it the imported chain is flat (777
against 776 records a call for a `Maybe` root) and the imported verdicts are the same-module ones.
A parameterised constructor type named alone keeps the block's namespace (#1317, S6).

Fixtures: `CallOtherPathsImported`, `ImportedSummaries` (a shared value through the block; an
unbuilt callee leaves its caller unchecked), imported `step`/`shared` `CallChainShare`; all fail on
master's `src/` (checked in a scratch copy). `ApartAcrossModules`, `CrossModule`,
`core/CastAcross` and part of `Conduit` are now checked by v2 with v1's verdicts. PR opened, not
merged; no reviewer launched (the manager's).

**What I learned.** A green parity run is not evidence that two code paths agree: the first version
held every v1 verdict and still read imported recursive types approximately. The precision gap and
the cost gap showed only because the new fixture was a same-module fixture moved across modules
and the counted test was run imported. Places' identity is load-bearing in `Calls` (a place
mismatch is a recast), so anything that builds a class in another table must land on the
adapter's places, not on bisimilar copies.
