# Coverage audit by experiment — 2026-09-18

Two questions, asked of the binary rather than of the source: does every
diagnostic code in `src/diagnostic.zig` have a corpus fixture that produces
it, and is every `pub` value in `core/` executed by some `tests/corpus/run/`
fixture? Both tables below were produced mechanically, not by reading.

**How the core table was measured.** Grepping fixture sources for a name
over-counts (`.size` matches `Dict.size`) and under-counts (`++` reaches
`Basics.append` with the name nowhere in sight). So every `run/` and
`regress/` fixture was built with `beni build --platform=node` and run under
`NODE_V8_COVERAGE`, and a core function counts as covered when V8 reports a
non-zero entry count for it. That is execution, not mention. Two consequences
worth knowing: a core value that is a CONSTANT rather than a function
(`Basics.e`, `Basics.pi`, `Dict.empty`, `Set.empty`) has no V8 function
record and shows as uncovered here although it is used; and a function the
emitter inlines (`&&` for `Basics.and`) is only reached when it is passed as
a VALUE.

## Counts

| | before | after |
|---|---|---|
| diagnostic codes, total | 107 | 107 |
| …with a corpus fixture | 97 | 97 |
| …blackbox only | 10 | 10 |
| …with nothing at all | 0 | 0 |
| `core/` `pub` values (excluding types) | 205 | 205 |
| …executed by a `run/` fixture | 126 | 199 |
| …executed, counting the four constants V8 cannot see | 130 | 203 |

The two that remain: `Basics.never`, which cannot be called by anyone because
its argument is a `Never` and no `Never` can be built (it is now *emitted*,
via `tests/corpus/run/CoreBasicsCalls.beni`), and `Debug.todo`, which ends
the process and therefore cannot live in a kind whose contract is stdout at
exit 0 — it is covered by a blackbox scenario in `tests/blackbox/build_test.zig`
instead.

## Part A — diagnostic codes

Ten codes have no corpus fixture. All ten are `build`/boundary codes, and the
reason is structural rather than an oversight: the corpus walker never passes
`--platform`, and `check --platform=<name>` (commit b3156c6) is what makes
§4's sibling checks reachable outside `build` at all.

| code | why not corpus | what would unlock it |
|---|---|---|
| `foreign_bad_shape` | `Emit.checkForeignShapes`, reached only from `Emit` | a platform-carrying `check/bad` kind |
| `foreign_sibling_missing` | `Emit.checkSiblings` (and `copyAssets`, build only) | the same, for the first site |
| `foreign_export_mismatch` | `Emit.compareExports` | the same |
| `foreign_unbound_reference` | `Emit.checkSiblings` | the same |
| `foreign_arity_mismatch` | `Emit.checkArity` | the same |
| `not_implemented` | `Emit.checkSiblings` (a relative import in a sibling `.js`) | the same |
| `missing_main` | `Emit.findEntry`, which `checkContract` deliberately skips | a *build-that-must-fail* kind |
| `main_not_program` | `Emit.checkMainType`, same gate | the same |
| `internal` | only `Lower.missingCoreValue` is reachable from outside, and needs `--core-root` | a kind carrying `--platform` + `--core-root` + exit 1 |
| `duplicate_module` | needs TWO root paths in one argv; a project fixture is one root, so its relative paths are unique by construction | a multi-root / `--root`-carrying kind |

`check --core <file>` does **not** run the sibling checks: `src/check/Command.zig:67`
returns before `Emit.checkContract`, so `--core` buys the privilege to write
`foreign` and nothing else.

### Update, 2026-09-19 — nine of the ten are now corpus fixtures

The "what would unlock it" column above asked for two kinds and got one:
**`tests/corpus/build/bad/`**, a directory fixture that is a whole project,
built with `--platform=<its own `platform/` subdirectory, or node>`, which
must exit 1, write no `out/`, and match `_expected.diag`. One kind covers
both rows because a project that carries its own platform package is also a
project that can be *built*. The nine that moved, one fixture each:
`foreign_bad_shape`, `foreign_sibling_missing`, `foreign_export_mismatch`,
`foreign_unbound_reference`, `foreign_arity_mismatch`, `not_implemented`,
`missing_main`, `main_not_program`, and `duplicate_main` — which this table
does not list because it predates the code. So **97 → 106 of 107 codes have
a corpus fixture**, and one — `internal` — does not.

`duplicate_module` is no longer in the count above for the reason it was
never unlockable by a fixture: it needs two root paths in one argv, and a
project fixture is one root. It, `internal` and the usage errors stay
blackbox-only; `tests/corpus/build/bad/README.md` says so and why.

The blackbox scenarios for all nine **stay**. They assert what a golden
cannot: exit codes across `check` and `build`, byte-equality between the two
commands' stderr, and the second site of `foreign_sibling_missing`, which is
asset copying rather than `Emit.checkSiblings`.

Reading the nine rendered messages in human form turned up five that are
wrong or misleading; they are listed with the slice that added the fixtures
and are not fixed here.

Full table:

| code | phase | corpus fixture(s) | blackbox | status |
|---|---|---|---|---|
| `invalid_utf8` | parse | parse/bad/InvalidUtf8.diag | abuse_test.zig | corpus |
| `invalid_module_path` | parse | parse/bad/invalid_module_path.diag | abuse_test.zig, blackbox_test.zig | corpus |
| `bare_carriage_return` | parse | parse/bad/BareCarriageReturn.diag | abuse_test.zig | corpus |
| `tab_in_source` | parse | parse/bad/TabInSource.diag<br>parse/bad/TabInString.diag | abuse_test.zig, blackbox_test.zig | corpus |
| `invalid_character` | parse | parse/bad/InvalidCharacter.diag<br>parse/bad/InvalidCharacterControl.diag | abuse_test.zig, blackbox_test.zig | corpus |
| `invalid_number` | parse | parse/bad/InvalidNumber.diag | blackbox_test.zig | corpus |
| `unterminated_string` | parse | parse/bad/InterpolationOpenAtEof.diag<br>parse/bad/OnlyDoubleQuote.diag<br>parse/bad/UnclosedInterpolation.diag<br>…(5 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `invalid_escape` | parse | parse/bad/InvalidEscape.diag<br>parse/bad/InvalidEscapeInChar.diag | abuse_test.zig | corpus |
| `nested_string_in_interpolation` | parse | parse/bad/NestedStringInInterpolation.diag | — | corpus |
| `invalid_char_literal` | parse | parse/bad/InvalidCharLiteral.diag<br>parse/bad/TwoErrorsRecovery.diag | abuse_test.zig, blackbox_test.zig | corpus |
| `doc_comment_unattached` | parse | parse/bad/DocAtEof.diag<br>parse/bad/DocBeforeImport.diag<br>parse/bad/DocCommentAtEofNoNewline.diag<br>…(5 total) | abuse_test.zig | corpus |
| `module_doc_not_at_top` | parse | parse/bad/ModuleDocNotAtTop.diag | — | corpus |
| `expected_declaration` | parse | parse/bad/ExpectedDeclaration.diag<br>parse/bad/ExpectedDeclarationContinuation.diag<br>parse/bad/LoneMultilineMarkerAtEof.diag<br>…(5 total) | abuse_test.zig | corpus |
| `expected_token` | parse | parse/bad/BindOutsideLet.diag<br>parse/bad/ExpectedToken.diag<br>parse/bad/ExpectedTokenTypeAlias.diag<br>…(6 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `unexpected_token` | parse | parse/bad/BindOutsideLet.diag<br>parse/bad/ComposeOperatorsRemoved.diag<br>parse/bad/SyntaxAndLoweringErrors.diag<br>…(6 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `unclosed_delimiter` | parse | parse/bad/DeepParens2000.diag<br>parse/bad/OneMegabyteLine.diag<br>parse/bad/TwoErrorsRecovery.diag<br>…(7 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `annotation_without_definition` | parse | parse/bad/AnnotationWithoutDefinition.diag<br>parse/bad/BindWithAnnotation.diag | — | corpus |
| `pub_on_definition` | parse | parse/bad/PubOnBoth.diag<br>parse/bad/PubOnDefinition.diag | — | corpus |
| `opaque_not_on_type` | parse | parse/bad/OpaqueNotOnType.diag | — | corpus |
| `case_without_branches` | parse | parse/bad/CaseWithoutBranches.diag | — | corpus |
| `args_after_question` | parse | parse/bad/ArgsAfterQuestion.diag | — | corpus |
| `non_associative_chain` | parse | parse/bad/NonAssociativeChain.diag<br>parse/bad/NonAssociativeChainPipes.diag | — | corpus |
| `negation_with_space` | parse | parse/bad/NegationWithSpace.diag | — | corpus |
| `invalid_tuple_index` | parse | parse/bad/InvalidTupleIndex.diag | — | corpus |
| `refutable_let_pattern` | parse | check/bad/RefutableLetCtor.diag<br>parse/bad/RefutableLetPattern.diag | — | corpus |
| `refutable_parameter_pattern` | parse | check/bad/RefutableParameterCtor.diag<br>check/bad/RefutableParameterNested.diag<br>parse/bad/RefutableLetPattern.diag<br>…(5 total) | — | corpus |
| `placeholder_outside_argument` | parse | parse/bad/PlaceholderOutsideArgument.diag<br>parse/bad/PlaceholderPositions.diag | — | corpus |
| `multiple_placeholders` | parse | parse/bad/MultiplePlaceholders.diag | — | corpus |
| `operator_not_a_function` | parse | parse/bad/OperatorNotAFunction.diag | — | corpus |
| `pipe_rhs_not_application` | parse | parse/bad/PipeRhsNotApplication.diag | — | corpus |
| `bind_rhs_not_application` | parse | parse/bad/BindRhsNotApplication.diag | — | corpus |
| `bind_rhs_forward_reference` | parse | parse/bad/BindRhsForwardReference.diag<br>parse/bad/NestedBindForwardReference.diag | — | corpus |
| `arrow_in_tuple_element` | parse | parse/bad/ArrowInTupleElement.diag<br>parse/bad/ArrowInTupleElementAllFunctions.diag | — | corpus |
| `nesting_too_deep` | parse | check/depth/AliasChainDeep.diag<br>check/depth/AnnotationDeep.diag<br>check/depth/InferredDeep.diag<br>…(6 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `duplicate_exposed_name` | bir/resolve | parse/bad/DuplicateExposedName.diag | — | corpus |
| `duplicate_import` | bir/resolve | parse/bad/DuplicateImport.diag | — | corpus |
| `duplicate_import_alias` | bir/resolve | parse/bad/DuplicateImportAlias.diag | — | corpus |
| `import_after_declaration` | bir/resolve | parse/bad/ImportAfterDeclaration.diag | — | corpus |
| `self_import` | bir/resolve | parse/bad/SelfImport.diag | — | corpus |
| `duplicate_declaration` | bir/resolve | parse/bad/DuplicateDeclaration.diag | — | corpus |
| `duplicate_type` | bir/resolve | parse/bad/DuplicateType.diag | — | corpus |
| `duplicate_constructor` | bir/resolve | parse/bad/DuplicateConstructor.diag | — | corpus |
| `shadows_import` | bir/resolve | parse/bad/ShadowsImport.diag | — | corpus |
| `duplicate_field` | bir/resolve | parse/bad/DuplicateField.diag | — | corpus |
| `foreign_outside_platform` | bir/resolve | check/bad/EquatableOutsideCore.diag<br>parse/bad/ForeignOutsidePlatform.diag | blackbox_test.zig, build_test.zig | corpus |
| `equatable_outside_core` | bir/resolve | check/bad/EquatableOutsideCore.diag | blackbox_test.zig | corpus |
| `equatable_not_first_occurrence` | bir/resolve | check/bad/core/EquatableNotFirst.diag | blackbox_test.zig | corpus |
| `unbound_variable` | bir/resolve | parse/bad/InterpolationOpenAtEof.diag<br>parse/bad/NestedStringInInterpolation.diag<br>parse/bad/SyntaxAndLoweringErrors.diag<br>…(6 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `unbound_constructor` | bir/resolve | parse/bad/UnboundConstructor.diag | — | corpus |
| `unbound_type` | bir/resolve | parse/bad/UnboundType.diag | — | corpus |
| `unknown_module_alias` | bir/resolve | parse/bad/UnknownModuleAlias.diag | blackbox_test.zig, check_test.zig | corpus |
| `question_in_lambda` | bir/resolve | parse/bad/QuestionInLambda.diag<br>parse/bad/QuestionInPlaceholderLambda.diag | — | corpus |
| `question_outside_function` | bir/resolve | parse/bad/QuestionOutsideFunction.diag | — | corpus |
| `shadowing` | bir/resolve | parse/bad/ShadowingExposed.diag<br>parse/bad/ShadowingLet.diag<br>parse/bad/ShadowingParam.diag<br>…(5 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `duplicate_pattern_variable` | bir/resolve | parse/bad/DuplicatePatternVariable.diag | — | corpus |
| `duplicate_type_parameter` | bir/resolve | parse/bad/DuplicateTypeParameter.diag | — | corpus |
| `unbound_type_variable` | bir/resolve | parse/bad/UnboundTypeVariable.diag | — | corpus |
| `unknown_module` | check | check/bad/UnknownModule.diag<br>parse/bad/DuplicateImportAlias.diag | blackbox_test.zig, check_test.zig | corpus |
| `duplicate_module` | check | — | blackbox_test.zig | BLACKBOX ONLY |
| `import_cycle` | check | check/bad/Cycle/_expected.diag<br>check/bad/CycleDense/_expected.diag | blackbox_test.zig | corpus |
| `unknown_import_name` | check | check/bad/SelfReference/_expected.diag<br>check/bad/UnknownImportName/_expected.diag<br>parse/bad/DuplicateExposedName.diag | blackbox_test.zig | corpus |
| `private_name` | check | check/bad/PrivateName/_expected.diag | blackbox_test.zig | corpus |
| `opaque_constructor` | check | check/bad/OpaqueConstructor/_expected.diag | blackbox_test.zig | corpus |
| `wrong_type_arity` | check | check/bad/WrongTypeArity.diag | blackbox_test.zig | corpus |
| `recursive_alias` | check | check/bad/RecursiveAlias.diag<br>check/bad/RecursiveAliasChain.diag | blackbox_test.zig | corpus |
| `type_mismatch` | check | check/args/AccessorWhereBinaryWanted.diag<br>check/args/ArgumentOrderSwap.diag<br>check/args/BareConstructorAsValue.diag<br>…(17 total) | blackbox_test.zig | corpus |
| `rigid_mismatch` | check | check/bad/RigidMismatch.diag | blackbox_test.zig | corpus |
| `infinite_type` | check | check/bad/InfiniteType.diag | blackbox_test.zig | corpus |
| `kind_mismatch` | check | check/bad/CaseBranchesDisagree.diag<br>check/bad/FieldNamedMain.diag<br>check/bad/InferredSchemeMisused/_expected.diag<br>…(7 total) | blackbox_test.zig, check_test.zig, build_test.zig | corpus |
| `too_few_args` | check | check/args/CallThroughParameter.diag<br>check/args/ConcatMapMissingFunction.diag<br>check/args/ConstructorBareInPattern.diag<br>…(25 total) | blackbox_test.zig | corpus |
| `too_many_args` | check | check/args/ConstructorTooManyInPattern.diag<br>check/args/MapTwoListsWithMap.diag<br>check/args/MissingParensAroundInnerCall.diag<br>…(8 total) | blackbox_test.zig | corpus |
| `not_a_function` | check | check/args/AppliedRecordField.diag<br>check/args/NotAFunction.diag<br>check/args/NullaryConstructorApplied.diag | blackbox_test.zig | corpus |
| `missing_field` | check | check/bad/FieldTypo.diag<br>check/bad/MissingField.diag | blackbox_test.zig | corpus |
| `unknown_field` | check | check/bad/UnknownField.diag | blackbox_test.zig | corpus |
| `record_not_closed` | check | check/bad/RecordNotClosed.diag | blackbox_test.zig | corpus |
| `not_equatable` | check | check/bad/CompareOnTypeHoldingFunction.diag<br>check/bad/IndirectFunctionPayload.diag<br>check/bad/NotEquatableFunction.diag<br>…(6 total) | blackbox_test.zig | corpus |
| `not_interpolatable` | check | check/args/MissingArgInInterpolation.diag<br>check/bad/NotInterpolatable.diag | blackbox_test.zig | corpus |
| `ambiguous_interpolation` | check | check/bad/AmbiguousInterpolation.diag | blackbox_test.zig | corpus |
| `ambiguous_tuple` | check | check/bad/AmbiguousTuple.diag | blackbox_test.zig | corpus |
| `tuple_index_out_of_range` | check | check/bad/TupleIndexOutOfRange.diag | blackbox_test.zig | corpus |
| `not_a_tuple` | check | check/bad/NotATuple.diag | blackbox_test.zig | corpus |
| `try_shape` | check | check/bad/TryMixedShapes.diag<br>check/bad/TryShape.diag | blackbox_test.zig | corpus |
| `missing_patterns` | check | check/bad/ImportedCaseIncomplete/_expected.diag<br>check/bad/MissingPatterns.diag<br>check/bad/MissingPatternsList.diag<br>…(6 total) | abuse_test.zig, blackbox_test.zig | corpus |
| `redundant_pattern` | check | check/bad/RedundantPattern.diag<br>check/bad/RedundantPatternLiteral.diag | blackbox_test.zig | corpus |
| `foreign_bad_shape` | build/boundary | — | build_test.zig | BLACKBOX ONLY |
| `foreign_sibling_missing` | build/boundary | — | build_test.zig | BLACKBOX ONLY |
| `foreign_export_mismatch` | build/boundary | — | build_test.zig | BLACKBOX ONLY |
| `foreign_unbound_reference` | build/boundary | — | build_test.zig | BLACKBOX ONLY |
| `missing_main` | build/boundary | — | blackbox_test.zig, check_test.zig, build_test.zig | BLACKBOX ONLY |
| `main_not_program` | build/boundary | — | build_test.zig | BLACKBOX ONLY |
| `not_implemented` | build/boundary | — | build_test.zig | BLACKBOX ONLY |
| `internal` | build/boundary | — | blackbox_test.zig | BLACKBOX ONLY |
| `where_variable_unbound` | bir/resolve | parse/bad/WhereConstraintBracketedComma.diag<br>parse/bad/WhereConstraintFreeVariable.diag<br>parse/bad/WhereVariableUnbound.diag | — | corpus |
| `duplicate_where_constraint` | bir/resolve | parse/bad/DuplicateWhereConstraint.diag | — | corpus |
| `unknown_method` | check | check/bad/TypeDispatchUnpinnedResult.diag<br>check/bad/UnknownMethod.diag<br>check/bad/UnknownMethodThroughGeneric/_expected.diag<br>…(4 total) | — | corpus |
| `private_method` | check | check/bad/PrivateMethod/_expected.diag | — | corpus |
| `no_methods_on_shape` | check | check/bad/CompareOnFunction.diag<br>check/bad/CompareOnTypeHoldingFunction.diag<br>check/bad/IndirectFunctionAcrossModules/_expected.diag<br>…(9 total) | — | corpus |
| `missing_where_constraint` | check | check/bad/MissingWhereCaller/_expected.diag<br>check/bad/MissingWhereConstraint.diag<br>check/bad/NotEquatableRigid.diag | — | corpus |
| `method_constraint_mismatch` | check | check/bad/MethodConstraintMismatch.diag | — | corpus |
| `type_dispatch_needs_annotation` | check | check/bad/TypeDispatchMethodNotInWhere.diag<br>check/bad/TypeDispatchUnannotated.diag | — | corpus |
| `ambiguous_method_receiver` | check | check/bad/MethodConstraintMismatch.diag<br>check/good/InferredConstraint.diag<br>check/good/SixtyFourConstraints.diag<br>…(5 total) | abuse_test.zig, blackbox_test.zig, check_test.zig | corpus |
| `constrained_constant` | check | check/bad/ConstrainedConstant.diag | — | corpus |
| `too_many_inferred_constraints` | check | check/bad/TooManyInferredConstraints.diag | abuse_test.zig | corpus |
| `foreign_arity_mismatch` | build/boundary | — | check_test.zig, build_test.zig | BLACKBOX ONLY |
| `pattern_budget_exhausted` | check | check/depth/PatternNestDeep.diag | abuse_test.zig, blackbox_test.zig | corpus |
| `let_forward_reference` | bir/resolve | parse/bad/LetForwardReference.diag<br>parse/bad/LetForwardThroughFunction.diag<br>parse/bad/LetSelfReference.diag<br>…(4 total) | — | corpus |
| `cyclic_value` | check | check/bad/CyclicValueChain.diag<br>check/bad/CyclicValuePair.diag<br>check/bad/CyclicValueSelf.diag<br>…(6 total) | — | corpus |

## Part B — every `pub` value in `core/`

Eleven new `run/` fixtures were added, grouped by module:

| fixture | what it covers |
|---|---|
| `CoreBasicsCalls.beni` | `eq` `neq` `lt` `gt` `le` `ge` `and` `or` by name, `and`/`or` again as VALUES (the only way the sibling runs), `always`, and `never` emitted through a `Never`-consuming function |
| `CoreBasicsMath.beni` | `logBase` `e` `pi` `cos` `sin` `tan` `acos` `asin` `atan` `atan2` `isNaN` `isInfinite` `degrees` `radians` `turns` `toPolar` `fromPolar` |
| `CoreCharRest.beni` | `isUpper` `isLower` `isAlphaNum` `isOctDigit` at every range boundary |
| `CoreDictRest.beni` | `singleton` `member` `isEmpty` `update` `union` `intersect` `diff`, duplicate insert, absent remove |
| `CoreListEdges.beni` | zero/negative/overlong counts for `take` `drop` `repeat` `range`, sort stability, already-sorted and reversed inputs |
| `CoreListRest.beni` | `singleton` `minimum` `intersperse` `isEmpty` `tail` `unzip` `map3`-`map5`, uneven and empty inputs |
| `CoreMaybeResultRest.beni` | `Maybe.map2`-`map5` `andThen`; the whole of `Result` |
| `CoreNumericExtremes.beni` | infinities, NaN through `compare`/`min`/`max`/`round`, integers past 2^53, `modBy`/`remainderBy` by zero and with negative operands |
| `CoreSetRest.beni` | `empty` `singleton` `remove` `isEmpty` `member` `size` `union` `intersect` `diff`, duplicates |
| `CoreStringRest.beni` | `toLower` `trimLeft` `trimRight` `isEmpty` `dropRight` `startsWith` `endsWith` `indices` `uncons` `pad` `padRight` and every count edge |
| `CoreStringUnicode.beni` | astral characters and combining marks through `length` `slice` `reverse` `left` `right` `dropLeft` `dropRight` `toList` `uncons` `pad` `map` `foldl`, and `Char.fromCode` out of range |

### Doc examples

All 257 indented `--|` example lines were extracted; 213 are top-level `==`
assertions. Each was compiled into a program that evaluates both sides:
**188 ran, 188 OK, 0 MISMATCH** — no documented value in `core/` is wrong. Nine
examples do not compile at all (six are the `f -1` rule, three name something
that does not exist); see the audit notes.

Full table:

| function | covered before | covered after (fixture) |
|---|---|---|
| `Basics.add` | yes | run/Arithmetic.beni<br>run/CallbackOrderDict.beni<br>run/CallbackOrderList.beni<br>…(66) |
| `Basics.sub` | yes | run/Arithmetic.beni<br>run/BindPipeRhs.beni<br>run/CallbackOrderList.beni<br>…(45) |
| `Basics.mul` | yes | run/Adt.beni<br>run/Arithmetic.beni<br>run/CallbackOrderDict.beni<br>…(29) |
| `Basics.fdiv` | yes | run/Arithmetic.beni<br>run/CoreBasicsMath.beni<br>run/CoreNumericExtremes.beni<br>…(8) |
| `Basics.idiv` | yes | run/Arithmetic.beni<br>run/NumericEdge.beni |
| `Basics.pow` | yes | run/Arithmetic.beni<br>run/CoreNumericExtremes.beni<br>run/ReleaseEverything.beni |
| `Basics.eq` | **no** | run/CoreBasicsCalls.beni |
| `Basics.neq` | **no** | run/CoreBasicsCalls.beni |
| `Basics.lt` | **no** | run/CoreBasicsCalls.beni |
| `Basics.gt` | **no** | run/CoreBasicsCalls.beni |
| `Basics.le` | **no** | run/CoreBasicsCalls.beni |
| `Basics.ge` | **no** | run/CoreBasicsCalls.beni |
| `Basics.and` | **no** | run/CoreBasicsCalls.beni |
| `Basics.or` | **no** | run/CoreBasicsCalls.beni |
| `Basics.append` | yes | run/CoreBasicsMath.beni<br>run/CoreCharRest.beni<br>run/CoreDictRest.beni<br>…(20) |
| `Basics.toFloat` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/NumericEdge.beni |
| `Basics.round` | yes | run/CoreNumericExtremes.beni<br>run/NumericEdge.beni |
| `Basics.floor` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/NumericEdge.beni |
| `Basics.ceiling` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/NumericEdge.beni |
| `Basics.truncate` | yes | run/CoreNumericExtremes.beni<br>run/NumericEdge.beni |
| `Basics.modBy` | yes | run/Arithmetic.beni<br>run/CoreNumericExtremes.beni<br>run/LibraryArgumentOrder.beni<br>…(8) |
| `Basics.remainderBy` | yes | run/Arithmetic.beni<br>run/CoreNumericExtremes.beni<br>run/LibraryArgumentOrder.beni<br>…(4) |
| `Basics.sqrt` | yes | run/CoreBasicsMath.beni<br>run/CoreMaybeResultRest.beni<br>run/CoreNumericExtremes.beni<br>…(5) |
| `Basics.logBase` | **no** | run/CoreBasicsMath.beni<br>run/CoreNumericExtremes.beni |
| `Basics.e` | **no** | NONE |
| `Basics.pi` | **no** | NONE |
| `Basics.cos` | **no** | run/CoreBasicsMath.beni |
| `Basics.sin` | **no** | run/CoreBasicsMath.beni |
| `Basics.tan` | **no** | run/CoreBasicsMath.beni |
| `Basics.acos` | **no** | run/CoreBasicsMath.beni |
| `Basics.asin` | **no** | run/CoreBasicsMath.beni |
| `Basics.atan` | **no** | run/CoreBasicsMath.beni |
| `Basics.atan2` | **no** | run/CoreBasicsMath.beni |
| `Basics.isNaN` | **no** | run/CoreBasicsMath.beni |
| `Basics.isInfinite` | **no** | run/CoreBasicsMath.beni |
| `Basics.negate` | yes | run/Arithmetic.beni<br>run/CoreBasicsMath.beni<br>run/CoreListEdges.beni<br>…(12) |
| `Basics.abs` | yes | run/Arithmetic.beni<br>run/CoreNumericExtremes.beni<br>run/ReleaseEverything.beni |
| `Basics.max` | yes | run/CoreNumericExtremes.beni<br>run/MaybeResult.beni<br>run/NumericEdge.beni<br>…(4) |
| `Basics.min` | yes | run/CoreListRest.beni<br>run/CoreNumericExtremes.beni<br>run/NumericEdge.beni<br>…(4) |
| `Basics.clamp` | yes | run/CoreNumericExtremes.beni<br>run/LibraryArgumentOrder.beni<br>run/NumericEdge.beni<br>…(4) |
| `Basics.compare` | yes | run/CoreListEdges.beni<br>run/CoreNumericExtremes.beni<br>run/SortByKeyOnce.beni<br>…(4) |
| `Basics.not` | yes | run/CallbackOrderList.beni<br>run/CallbackOrderString.beni<br>run/Comparison.beni<br>…(4) |
| `Basics.xor` | yes | run/Comparison.beni |
| `Basics.identity` | yes | run/HigherOrder.beni |
| `Basics.always` | **no** | run/CoreBasicsCalls.beni |
| `Basics.never` | **no** | NONE |
| `Basics.degrees` | **no** | run/CoreBasicsMath.beni |
| `Basics.radians` | **no** | run/CoreBasicsMath.beni |
| `Basics.turns` | **no** | run/CoreBasicsMath.beni |
| `Basics.toPolar` | **no** | run/CoreBasicsMath.beni |
| `Basics.fromPolar` | **no** | run/CoreBasicsMath.beni |
| `Char.toCode` | yes | run/CallbackOrderString.beni<br>run/CharOps.beni<br>run/CoreCharRest.beni<br>…(6) |
| `Char.fromCode` | yes | run/CharOps.beni<br>run/CoreStringUnicode.beni |
| `Char.toUpper` | yes | run/CharOps.beni<br>run/CoreStringUnicode.beni |
| `Char.toLower` | yes | run/CharOps.beni<br>run/CoreStringUnicode.beni |
| `Char.isUpper` | yes | run/CoreCharRest.beni<br>run/ReleaseEverything.beni |
| `Char.isLower` | yes | run/CharOps.beni<br>run/CoreCharRest.beni<br>run/ReleaseEverything.beni |
| `Char.isAlpha` | yes | run/CharOps.beni<br>run/CoreCharRest.beni<br>run/ReleaseEverything.beni |
| `Char.isAlphaNum` | yes | run/CoreCharRest.beni<br>run/ReleaseEverything.beni |
| `Char.isDigit` | yes | run/CharOps.beni<br>run/CoreCharRest.beni<br>run/CoreStringRest.beni<br>…(4) |
| `Char.isOctDigit` | **no** | run/CoreCharRest.beni |
| `Char.isHexDigit` | yes | run/CharOps.beni<br>run/CoreCharRest.beni |
| `Debug.log` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CallbackOrderList.beni<br>…(16) |
| `Debug.todo` | **no** | NONE |
| `Debug.toString` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CallbackOrderList.beni<br>…(19) |
| `Dict.empty` | **no** | NONE |
| `Dict.singleton` | **no** | run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.get` | yes | run/CoreDictRest.beni<br>run/CoreSetRest.beni<br>run/DictRecordKey.beni<br>…(7) |
| `Dict.member` | **no** | run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.size` | yes | run/CoreDictRest.beni<br>run/CoreSetRest.beni<br>run/DictRecordKey.beni<br>…(6) |
| `Dict.isEmpty` | **no** | run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.insert` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CoreDictRest.beni<br>…(11) |
| `Dict.remove` | yes | run/CoreDictRest.beni<br>run/CoreSetRest.beni<br>run/DictRecordKey.beni<br>…(4) |
| `Dict.update` | **no** | run/CoreDictRest.beni |
| `Dict.union` | **no** | run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.intersect` | **no** | run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.diff` | **no** | run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.merge` | yes | run/CallbackOrderDict.beni |
| `Dict.map` | yes | run/CallbackOrderDict.beni |
| `Dict.foldl` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CoreDictRest.beni<br>…(4) |
| `Dict.foldr` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CoreDictRest.beni<br>…(9) |
| `Dict.filter` | yes | run/CallbackOrderDict.beni<br>run/CoreDictRest.beni<br>run/CoreSetRest.beni |
| `Dict.partition` | yes | run/CallbackOrderDict.beni |
| `Dict.keys` | yes | run/CallbackOrderDict.beni<br>run/CoreSetRest.beni<br>run/DictRecordKey.beni<br>…(6) |
| `Dict.values` | yes | run/DictRecordKey.beni<br>run/Dictionaries.beni |
| `Dict.toList` | yes | run/CallbackOrderDict.beni<br>run/CoreDictRest.beni<br>run/DictStructuralEquality.beni |
| `Dict.fromList` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CoreDictRest.beni<br>…(7) |
| `List.cons` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CallbackOrderList.beni<br>…(46) |
| `List.foldl` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CallbackOrderList.beni<br>…(49) |
| `List.foldr` | yes | run/CallbackOrderFoldr.beni<br>run/CallbackOrderList.beni<br>run/CoreListEdges.beni<br>…(7) |
| `List.eq` | yes | run/Comparison.beni<br>run/ConstrainedPartEvidence.beni<br>run/DictStructuralEquality.beni<br>…(7) |
| `List.compare` | yes | run/ListOrdering.beni<br>run/NestedConstrainedListKeys.beni |
| `List.singleton` | **no** | run/CoreListRest.beni |
| `List.repeat` | yes | run/CoreListEdges.beni<br>run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>…(8) |
| `List.range` | yes | run/CallbackOrderList.beni<br>run/CoreListEdges.beni<br>run/ImportedModule.beni<br>…(10) |
| `List.map` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderList.beni<br>run/CallbackOrderString.beni<br>…(39) |
| `List.indexedMap` | yes | run/CallbackOrderList.beni |
| `List.filter` | yes | run/CallbackOrderList.beni<br>run/CallbackOrderString.beni<br>run/CoreStringRest.beni<br>…(5) |
| `List.filterMap` | yes | run/CallbackOrderList.beni<br>run/ListMapFilterDeep.beni |
| `List.length` | yes | run/CallbackOrderList.beni<br>run/CoreBasicsCalls.beni<br>run/CoreStringUnicode.beni<br>…(14) |
| `List.reverse` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CallbackOrderList.beni<br>…(42) |
| `List.member` | yes | run/ListMemberEq.beni |
| `List.all` | yes | run/CallbackOrderList.beni<br>run/CallbackOrderString.beni<br>run/CoreStringRest.beni |
| `List.any` | yes | run/CallbackOrderList.beni<br>run/CallbackOrderString.beni<br>run/CoreStringRest.beni<br>…(4) |
| `List.maximum` | yes | run/CoreListRest.beni<br>run/MaybeResult.beni |
| `List.minimum` | **no** | run/CoreListRest.beni |
| `List.sum` | yes | run/CoreListEdges.beni<br>run/ImportedModule.beni<br>run/IrrefutableParameters.beni<br>…(4) |
| `List.product` | yes | run/CoreListEdges.beni<br>run/ListFold.beni |
| `List.append` | yes | run/CallbackOrderList.beni<br>run/CoreListEdges.beni |
| `List.concat` | yes | run/CallbackOrderList.beni<br>run/CoreListEdges.beni |
| `List.concatMap` | yes | run/CallbackOrderList.beni |
| `List.intersperse` | **no** | run/CoreListRest.beni |
| `List.map2` | yes | run/CallbackOrderList.beni<br>run/CoreBasicsCalls.beni |
| `List.map3` | **no** | run/CoreListRest.beni |
| `List.map4` | **no** | run/CoreListRest.beni |
| `List.map5` | **no** | run/CoreListRest.beni |
| `List.sort` | yes | run/CoreListEdges.beni<br>run/ListFold.beni<br>run/ListOrdering.beni<br>…(6) |
| `List.sortBy` | yes | run/CoreListEdges.beni<br>run/SortByKeyOnce.beni<br>run/Sorting.beni |
| `List.sortWith` | yes | run/CoreListEdges.beni<br>run/ListFold.beni<br>run/ListOrdering.beni<br>…(7) |
| `List.isEmpty` | **no** | run/CoreListRest.beni |
| `List.head` | yes | run/MaybeResult.beni<br>run/Question.beni |
| `List.tail` | **no** | run/CoreListRest.beni |
| `List.take` | yes | run/CoreListEdges.beni<br>run/LibraryArgumentOrder.beni<br>run/ListFold.beni<br>…(4) |
| `List.drop` | yes | run/CoreListEdges.beni<br>run/LibraryArgumentOrder.beni<br>run/ListFold.beni |
| `List.partition` | yes | run/CallbackOrderList.beni<br>run/ListMapFilterDeep.beni |
| `List.unzip` | **no** | run/CoreListRest.beni |
| `Maybe.withDefault` | yes | run/CoreMaybeResultRest.beni<br>run/DictRecordKey.beni<br>run/Dictionaries.beni<br>…(7) |
| `Maybe.map` | yes | run/MaybeResult.beni |
| `Maybe.map2` | **no** | run/CoreMaybeResultRest.beni |
| `Maybe.map3` | **no** | run/CoreMaybeResultRest.beni |
| `Maybe.map4` | **no** | run/CoreMaybeResultRest.beni |
| `Maybe.map5` | **no** | run/CoreMaybeResultRest.beni |
| `Maybe.andThen` | **no** | run/CoreMaybeResultRest.beni |
| `Result.withDefault` | yes | run/CoreMaybeResultRest.beni<br>run/MaybeResult.beni |
| `Result.map` | **no** | run/CoreMaybeResultRest.beni |
| `Result.map2` | **no** | run/CoreMaybeResultRest.beni |
| `Result.map3` | **no** | run/CoreMaybeResultRest.beni |
| `Result.map4` | **no** | run/CoreMaybeResultRest.beni |
| `Result.map5` | **no** | run/CoreMaybeResultRest.beni |
| `Result.andThen` | **no** | run/CoreMaybeResultRest.beni |
| `Result.mapError` | **no** | run/CoreMaybeResultRest.beni |
| `Result.toMaybe` | **no** | run/CoreMaybeResultRest.beni |
| `Result.fromMaybe` | yes | run/CoreMaybeResultRest.beni<br>run/ReleaseEverything.beni |
| `Set.empty` | **no** | NONE |
| `Set.singleton` | **no** | run/CoreSetRest.beni |
| `Set.insert` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CoreSetRest.beni<br>…(4) |
| `Set.remove` | **no** | run/CoreSetRest.beni |
| `Set.isEmpty` | **no** | run/CoreSetRest.beni |
| `Set.member` | **no** | run/CoreSetRest.beni |
| `Set.size` | **no** | run/CoreSetRest.beni |
| `Set.union` | **no** | run/CoreSetRest.beni |
| `Set.intersect` | **no** | run/CoreSetRest.beni |
| `Set.diff` | **no** | run/CoreSetRest.beni |
| `Set.toList` | yes | run/CallbackOrderDict.beni<br>run/CoreSetRest.beni<br>run/LibraryArgumentOrder.beni |
| `Set.fromList` | yes | run/CallbackOrderDict.beni<br>run/CallbackOrderFoldr.beni<br>run/CoreSetRest.beni<br>…(4) |
| `Set.map` | yes | run/CallbackOrderDict.beni<br>run/CoreSetRest.beni<br>run/LibraryArgumentOrder.beni |
| `Set.foldl` | yes | run/CallbackOrderFoldr.beni<br>run/CoreSetRest.beni |
| `Set.foldr` | yes | run/CallbackOrderFoldr.beni<br>run/CoreSetRest.beni |
| `Set.filter` | yes | run/CallbackOrderDict.beni<br>run/CoreSetRest.beni |
| `Set.partition` | yes | run/CallbackOrderDict.beni |
| `String.length` | yes | run/CoreSetRest.beni<br>run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>…(8) |
| `String.slice` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/LibraryArgumentOrder.beni<br>…(5) |
| `String.append` | yes | run/CallbackOrderFoldr.beni<br>run/CharOps.beni<br>run/Closures.beni<br>…(35) |
| `String.compare` | yes | run/ConstrainedMutualRecursion.beni<br>run/CoreDictRest.beni<br>run/CoreSetRest.beni<br>…(16) |
| `String.toUpper` | yes | run/CoreStringRest.beni<br>run/ImportedModule.beni<br>run/StringBuilding.beni |
| `String.toLower` | **no** | run/CoreStringRest.beni |
| `String.trim` | yes | run/CoreStringRest.beni<br>run/StringBuilding.beni |
| `String.trimLeft` | **no** | run/CoreStringRest.beni |
| `String.trimRight` | **no** | run/CoreStringRest.beni |
| `String.words` | yes | run/StringOps.beni |
| `String.lines` | yes | run/StringOps.beni |
| `String.split` | yes | run/LibraryArgumentOrder.beni<br>run/StringOps.beni |
| `String.indexes` | yes | run/CoreStringRest.beni<br>run/LibraryArgumentOrder.beni<br>run/StringOps.beni |
| `String.toInt` | yes | run/CoreNumericExtremes.beni<br>run/CoreStringRest.beni<br>run/MaybeResult.beni<br>…(4) |
| `String.fromInt` | yes | run/Arithmetic.beni<br>run/BindPipeRhs.beni<br>run/CallbackOrderDict.beni<br>…(91) |
| `String.toFloat` | yes | run/CoreNumericExtremes.beni<br>run/CoreStringRest.beni<br>run/ReleaseEverything.beni |
| `String.fromFloat` | yes | run/Adt.beni<br>run/Arithmetic.beni<br>run/CoreBasicsMath.beni<br>…(9) |
| `String.fromChar` | yes | run/CallbackOrderFoldr.beni<br>run/CharOps.beni<br>run/CoreStringRest.beni<br>…(7) |
| `String.toList` | yes | run/CallbackOrderFoldr.beni<br>run/CallbackOrderString.beni<br>run/CharOps.beni<br>…(10) |
| `String.fromList` | yes | run/CallbackOrderString.beni<br>run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>…(7) |
| `String.isEmpty` | **no** | run/CoreStringRest.beni |
| `String.reverse` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/StringBuilding.beni |
| `String.repeat` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/DceForeignThroughCore.beni<br>…(5) |
| `String.replace` | yes | run/LibraryArgumentOrder.beni<br>run/StringOps.beni |
| `String.concat` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/DceForeignThroughCore.beni<br>…(7) |
| `String.join` | yes | run/CharOps.beni<br>run/Closures.beni<br>run/CoreBasicsCalls.beni<br>…(34) |
| `String.left` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/LibraryArgumentOrder.beni<br>…(4) |
| `String.right` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/StringOps.beni |
| `String.dropLeft` | yes | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>run/LibraryArgumentOrder.beni |
| `String.dropRight` | **no** | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni |
| `String.contains` | yes | run/CoreStringRest.beni<br>run/LibraryArgumentOrder.beni |
| `String.startsWith` | **no** | run/CoreStringRest.beni |
| `String.endsWith` | **no** | run/CoreStringRest.beni |
| `String.indices` | **no** | run/CoreStringRest.beni |
| `String.cons` | yes | run/CallbackOrderFoldr.beni<br>run/CoreStringRest.beni<br>run/CoreStringUnicode.beni<br>…(4) |
| `String.uncons` | **no** | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni |
| `String.pad` | **no** | run/CoreStringRest.beni<br>run/CoreStringUnicode.beni |
| `String.padLeft` | yes | run/CoreStringRest.beni<br>run/DceForeignThroughCore.beni |
| `String.padRight` | **no** | run/CoreStringRest.beni |
| `String.map` | yes | run/CallbackOrderString.beni<br>run/CoreStringRest.beni<br>run/CoreStringUnicode.beni |
| `String.filter` | yes | run/CallbackOrderString.beni<br>run/CoreStringRest.beni |
| `String.foldl` | yes | run/CallbackOrderFoldr.beni<br>run/CallbackOrderString.beni<br>run/CoreStringRest.beni<br>…(5) |
| `String.foldr` | yes | run/CallbackOrderFoldr.beni<br>run/CoreStringRest.beni |
| `String.any` | yes | run/CallbackOrderString.beni<br>run/CoreStringRest.beni |
| `String.all` | yes | run/CallbackOrderString.beni<br>run/CoreStringRest.beni |
