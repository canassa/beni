## 2026-09-22 17:36 CEST — Layout record declaration bodies

**What I did**

- Pulled first (already current), read report 35 and the language/frontend/schema
  contracts, then specified option A before implementation. Spec commit `fee8a02`;
  feature commit `1faf6fe`. Delegated parser, formatter and fixture implementation
  to separate agents and independently reviewed and validated their work.
- Added the field-block grammar, exact later-line `lower_ident ':'` nesting test,
  sibling/continuation/recovery columns and always-vertical declaration formatting;
  appended schema A.5 and updated CLAUDE.md and the schema queue. Only
  `src/parse/Parse.zig` and `src/fmt/Format.zig` changed under `src/`; AST node
  shapes and the checker, resolver, BIR and JS phases are unchanged.
- Added 15 corpus cases: parse/good `BraceRecordAlias`, `LayoutRecordAlias`,
  `LayoutSchemaDeclarations`, `LayoutSchemaFallbacks`, `SchemaTaggedBraceNextLine`;
  parse/bad `LayoutFieldWrongColumn`, `LayoutFieldMissingColon`,
  `LayoutNestedAfterType`, `LayoutFieldRecovery`, `LayoutFieldEof`,
  `LayoutSchemaViaMultiline`; fmt `RecordDeclarationBodies`,
  `LayoutDeclarationBodies`, `RecordLayoutOneLine`, `TaggedSchemaComments`.
  Two black-box scenarios assert complete AST/BIR spelling equality and complete
  recovery diagnostics/AST, retaining malformed siblings, `kept` and `after`.
- Verified byte-identical brace/layout dumps: the record alias pair is 593 AST
  bytes and 850 BIR bytes; the complete SchemaDeclarations mirror is 2,255 AST
  bytes and 2,683 BIR bytes. Its `.ast` golden is copied from the brace oracle,
  and the black-box `expectEqualStrings` checks make equality an explicit law.
  The fmt corpus supplies AST preservation, comment preservation and fixed points.
- Proved red before source edits with the old binary, then saved and reversed the
  implementation patch, restored the seven old formatter goldens temporarily,
  rebuilt and ran the full black-box suite: exactly 14 NEW corpus cases and the
  two NEW scenarios failed; no existing case failed. The old brace compatibility
  control passed. The six negative cases differed in their full diagnostic
  goldens; the one-line and tagged-comment formatter cases parsed but differed in
  output; the remaining red good/fmt cases were rejected by the old syntax/doc
  rules. Reapplied the patches without `git stash`. After updating two stale
  supplementary formatter expectations, verified the refreshed patch still
  reverses to the exact same original source tree; production code did not change.
- Read all seven existing fmt golden diffs: AlreadyCanonicalModule,
  AlreadyCanonicalTypes, CommentsBetweenAndInside, ExtraSpacesEverywhere,
  NaryTypes, SchemaDeclarations and TypeDeclUgly. Only declaration record bodies
  and tagged variants moved, including comments formerly attached to removed
  delimiters. Inline/extensible records, ordinary `type`, `case`, `let` and record
  values remain unchanged. The one-line Point alias always becomes layout.
- Reformatted ten benchmark files in this separate source-format commit:
  `bench/corpus/{Counter,Data/Parser,FormValidation,JsonCodecs,NotesApp,PrettyPrinter,Router,Ui/View}.beni`
  and `bench/schema-prototype/{cases/Cases,src/Schema}.beni`. Compared every
  worktree file's before/after BIR stdout byte for byte (both exits 0), then passed
  `beni fmt --check bench/corpus bench/schema-prototype`. No core/platform source
  required reformatting and no emit/run golden changed.
- All three gates passed before the feature commit and after source reformat:
  `zig build test` 464/464; `zig build test-blackbox` 285/285, including jobs 1/8
  determinism and the development/release runtime corpus; `zig build fmt-check`.
  Independent 17-case probes also checked old brace geometry, nested/inline and
  extensible types, n-ary continuations, modifier/via layout and malformed sibling
  recovery. Both 4,100-level layout alias/schema inputs stopped with
  `nesting_too_deep`, without panic. Detailed command logs and patch/proof files
  are in `/tmp/beni-layout-proof/` for this workspace session.

**What I learned**

- Nesting must compare the next token's line with the COLON, while indentation
  belongs to the field name; bracket columns never enter the rule. Old tagged
  brace payloads can legally sit left of the variant name, so detecting layout
  must not tighten the old brace arm's declaration-relative indentation.
- Ordinary brace record-type fields previously rejected field docs. Consuming
  those docs in the parser is necessary for the commissioned two-spelling
  equivalence; they stay comments, without adding semantic AST/BIR payload.
- A payloadless variant and an explicitly empty record payload have different
  ASTs. The latter therefore retains `{}` (`Empty as "empty" {}`); schema record
  operands with outer modifiers likewise retain braces because a nested field
  block has no outer-modifier production.
- Moving a tagged rename before its payload reverses source-token visitation.
  Its comments must be emitted after payload comments, exactly once and in the
  original order; the tagged comment fixture catches both duplication and
  second-pass indentation drift.
- Confirmed a separate pre-existing S1 defect and recorded queue row 70 without
  fixing it: `schema X = { a : Int } nullable` is rejected at `nullable` despite
  schema §2's operand/value-modifier grammar. The direct brace arm in
  `parseSchemaDecl` bypasses value modifiers. This layout slice leaves it alone.
