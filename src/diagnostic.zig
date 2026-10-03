//! The public diagnostic schema (docs/design/frontend.md §1.1).
//!
//! This file is the named build module `diagnostic`, imported by both the
//! compiler and the black-box suite. It imports only `std`, so it sits at the
//! bottom of the module graph and can be shared by every root. The JSON form
//! of a diagnostic is this struct serialised field-for-field; the black-box
//! harness parses stderr back into it, which is what makes "assert the whole
//! diagnostic" (.claude/skills/write-tests) a compile-time contract rather
//! than a convention.
//!
//! The sort order the compiler emits in — file path, then start position, then
//! code (frontend.md §1) — lives here too, next to the schema, so the tests
//! sort their expectations with the same comparator the compiler uses.

const std = @import("std");

pub const Severity = enum { @"error", warning };

/// 1-based line and column; the column counts code points from the line
/// start (language.md §12.7, *columns*), so a symbol is one column.
pub const Position = struct {
    line: u32,
    col: u32,

    pub fn order(a: Position, b: Position) std.math.Order {
        const by_line = std.math.order(a.line, b.line);
        if (by_line != .eq) return by_line;
        return std.math.order(a.col, b.col);
    }
};

/// `end` is exclusive, on the same line as `start` or later.
pub const Span = struct {
    file: []const u8,
    start: Position,
    end: Position,
};

pub const Diagnostic = struct {
    code: Code,
    severity: Severity,
    span: Span,
    /// "TAB CHARACTER" — Elm style. Always `title(code)`; carried on the
    /// value so the JSON form is self-describing.
    title: []const u8,
    /// Full prose, may span lines, no trailing newline.
    message: []const u8,
};

/// The stable snake_case catalogue from language.md §10, in the order that
/// document lists them, plus `internal` for compiler failures that must be
/// reported as a diagnostic rather than a crash. New codes are appended to
/// the catalogue there first, then here.
pub const Code = enum {
    invalid_utf8,
    invalid_module_path,
    bare_carriage_return,
    tab_in_source,
    invalid_character,
    invalid_number,
    unterminated_string,
    invalid_escape,
    nested_string_in_interpolation,
    invalid_char_literal,
    doc_comment_unattached,
    module_doc_not_at_top,
    expected_declaration,
    expected_token,
    unexpected_token,
    unclosed_delimiter,
    annotation_without_definition,
    pub_on_definition,
    opaque_not_on_type,
    case_without_branches,
    args_after_question,
    non_associative_chain,
    negation_with_space,
    invalid_tuple_index,
    refutable_let_pattern,
    /// The same rule one scope out, appended on 2026-09-18 (`language.md`
    /// §7): a function or lambda PARAMETER must be irrefutable too. Its own
    /// code rather than `refutable_let_pattern`'s, because that message
    /// names `let` and a parameter is not one.
    refutable_parameter_pattern,
    placeholder_outside_argument,
    multiple_placeholders,
    operator_not_a_function,
    pipe_rhs_not_application,
    bind_rhs_not_application,
    bind_rhs_forward_reference,
    arrow_in_tuple_element,
    nesting_too_deep,
    duplicate_exposed_name,
    duplicate_import,
    duplicate_import_alias,
    import_after_declaration,
    self_import,
    duplicate_declaration,
    duplicate_type,
    duplicate_constructor,
    shadows_import,
    duplicate_field,
    foreign_outside_platform,
    equatable_outside_core,
    equatable_not_first_occurrence,
    unbound_variable,
    unbound_constructor,
    unbound_type,
    unknown_module_alias,
    question_in_lambda,
    question_outside_function,
    shadowing,
    duplicate_pattern_variable,
    duplicate_type_parameter,
    unbound_type_variable,
    // Resolution (checker.md §8.1): the module graph and cross-module resolution.
    unknown_module,
    duplicate_module,
    import_cycle,
    unknown_import_name,
    private_name,
    opaque_constructor,
    wrong_type_arity,
    recursive_alias,
    // Inference (checker.md §8.1). `rigid_mismatch` is the case where
    // one side was an annotation's promise about ALL types, which needs a
    // different hint from an ordinary mismatch; the three arity codes are
    // §8.3's, and with currying gone (`language.md` §6.7) they are what an
    // arity mistake reads as, at the place it was written.
    type_mismatch,
    rigid_mismatch,
    infinite_type,
    kind_mismatch,
    too_few_args,
    too_many_args,
    not_a_function,
    missing_field,
    unknown_field,
    record_not_closed,
    not_equatable,
    not_interpolatable,
    ambiguous_interpolation,
    ambiguous_tuple,
    tuple_index_out_of_range,
    not_a_tuple,
    try_shape,
    // Pattern usefulness (checker.md §6.6, §8.1). Both are reported
    // after a declaration solves cleanly, so the patterns they judge are
    // known to be well typed.
    missing_patterns,
    redundant_pattern,
    // The platform contract (boundary.md §4, §5). Every one of
    // these is about privileged code — a `foreign` declaration and the
    // sibling JavaScript file it binds to — and every one of them is a
    // check Elm does not perform (§4).
    foreign_bad_shape,
    foreign_sibling_missing,
    foreign_export_mismatch,
    foreign_unbound_reference,
    missing_main,
    main_not_program,
    /// A construct the code generator does not compile YET. It is a
    /// diagnostic and not a panic because backend.md §1 ships the language
    /// in two halves and the half that is missing must say so.
    not_implemented,
    internal,
    // The static-dispatch spike (docs/design/static-dispatch-spike.md §10),
    // appended so no existing line moves. These two are lowering's, from the
    // well-formedness rules of a `where` clause (§2.4); the other eight codes
    // of §10 are the checker's.
    where_variable_unbound,
    duplicate_where_constraint,
    /// The eight the CHECKER raises (§6, §10.1-§10.5, §10.8-§10.10).
    unknown_method,
    private_method,
    no_methods_on_shape,
    missing_where_constraint,
    method_constraint_mismatch,
    type_dispatch_needs_annotation,
    /// The one `warning` the branch adds (§10.9), emitted by default and
    /// only for a module of the ROOT package. A warning never changes the
    /// exit code.
    ambiguous_method_receiver,
    constrained_constant,
    /// The cap of §6.4, appended on 2026-09-18 (§10.11, A.83): an
    /// unannotated declaration whose inferred scheme would carry more than
    /// `Solve.Solver.max_inferred_constraints` of them.
    too_many_inferred_constraints,
    /// `boundary.md` §4's fourth check, appended on 2026-09-18
    /// (`static-dispatch-spike.md` A.84): a sibling export whose parameter
    /// count is not evidence count + declared arity, or whose parameter list
    /// the scanner may not count.
    foreign_arity_mismatch,
    /// The third of the exhaustiveness set, appended on 2026-09-18
    /// (`checker.md` §6.6): a `case` whose exhaustiveness the
    /// usefulness analysis could not decide inside `--pattern-budget`.
    /// Silence there was the last exit-0 path to a wrong answer, because
    /// `backend.md` §7's decision tree emits no default arm.
    pattern_budget_exhausted,
    /// `language.md` §7's initialisation rule, appended on 2026-09-18: a
    /// `let` VALUE binding whose right-hand side reads
    /// a value binding of the same `let` written below it — directly, by
    /// naming itself, or by naming a `let` function that reads one. §6's
    /// *Evaluation order* makes written order the rule, so the reference
    /// is a JavaScript temporal dead zone: it was the last exit-0 path
    /// from a `let` to a `ReferenceError`.
    let_forward_reference,
    /// The TOP-LEVEL half of the same rule, appended on 2026-09-18
    /// (`language.md` §7, `checker.md` §6.7): a top-level value
    /// whose initialiser is reachable from itself, directly or through the
    /// functions it names. Top-level constants are emitted in dependency
    /// order (`backend.md` §5), which orders everything except a cycle —
    /// there `emissionOrder` falls back to source order and the program
    /// throws a `ReferenceError` at load with the build exiting 0. It was
    /// the last exit-0 path from a MODULE to a temporal dead zone, as
    /// `let_forward_reference` was from a `let`.
    cyclic_value,
    /// The platform contract again (`boundary.md` §5.3), appended on 2026-09-19: a project
    /// with more than one `main`. It was reported under `missing_main`,
    /// whose title says the opposite of the message underneath it and whose
    /// code routes a tool to the wrong condition. A build is a pair of ONE
    /// entry point and ONE platform, so two `main`s are two builds — a
    /// different edit from the one "MISSING MAIN" asks for.
    duplicate_main,
    /// The release optimiser (`backend.md` §9), appended on 2026-09-19: a
    /// `--release` build in which a `pub`
    /// value of `core/Debug` survives §9's reachability walk. The owner took
    /// Elm's rule that day — `Debug.toString` reflects on the runtime
    /// representation the optimiser must be free to change, and a
    /// `Debug.log` inside a binding nothing reads is dropped whole by item 1
    /// — so that "a release build behaves exactly as the development build
    /// does" holds without exception. The message names the use sites.
    debug_in_release,
    /// The output tree (`backend.md` §2's *The output tree does not depend on
    /// the file system's case sensitivity*), appended on 2026-09-21: two files a build would write whose paths are equal under ASCII
    /// case folding. On APFS and NTFS they are ONE file, the second write
    /// wins, and the build exits 0 having shipped something that throws at
    /// load — which is what `main.mjs` did to every module named `Main`.
    /// Checked over the produced list before the first byte is written, so
    /// a refused build leaves nothing behind.
    output_path_collision,
    /// The other half of the same guarantee (`boundary.md` §5.2): a
    /// platform's `"entry"` key naming a file a module could take. The name
    /// became declarable the same day; a declared name that does not begin
    /// with `_` would let a platform author reintroduce, in data, the defect
    /// the compiler had just been taught to make impossible.
    invalid_entry_file,
    // Schemas (docs/design/schema.md §8), appended in contract order.
    schema_used_as_type,
    schema_used_as_value,
    schema_name_collision,
    unknown_schema_member,
    expected_schema,
    duplicate_schema_key,
    duplicate_schema_tag,
    duplicate_schema_modifier,
    schema_conversion_mismatch,
    /// Static dispatch (`static-dispatch-spike.md` §10.12), appended on
    /// 2026-09-23: a use of a module's own type needs that
    /// module's method, which has no annotation and whose binding group is
    /// checked after the use, so it has no type there yet. It used to be a
    /// silent `err` site or part — `undefined`, or a structural
    /// `Basics.eq` that ignored the method.
    method_needs_annotation,
    /// Appended on 2026-09-25 (`checker-v2.md` §14.2): a
    /// `type`, `type alias`, `foreign type` or `schema` of more than 65 535 parameters.
    /// A type's arity is a `u16` in the interface record, and a saturated
    /// arity would import the type at the wrong width — which is what a `u8`
    /// arity did at 255, and the reason this is an error and not a clamp.
    too_many_type_parameters,
    /// Appended on 2026-09-28 (`backend.md` §2's
    /// *The output directory holds what the last build wrote*): `--out`
    /// holds a `_manifest.txt` that is not beni's record, which the build
    /// would otherwise overwrite, or a symbolic link on the way to a path
    /// the build writes, which it would otherwise write through. Reported
    /// before the first byte is written.
    unknown_output_record,
    // Markup (language.md §11.17), appended in catalogue order: the
    // parser's three, lowering's five, the checker's, a lowering's and a
    // manifest's, then the line the specification review appended.
    unclosed_element,
    mismatched_closing_tag,
    element_as_argument,
    duplicate_attribute,
    spread_on_element,
    spread_not_first,
    invalid_form_children,
    vocabulary_outside_platform,
    no_markup_vocabulary,
    unknown_element,
    unknown_attribute,
    child_not_renderable,
    void_element_with_children,
    invalid_keyed,
    key_not_primitive,
    unkeyed_for,
    raw_markup_attribute,
    markup_restructured,
    unknown_markup_lowering,
    unknown_form_attribute,
    missing_form_attribute,
    markup_type_in_foreign,
    /// Appended the day markup was typed: a quoted attribute name beginning
    /// with `on`, which a page would run as script (`language.md` §11.5).
    untyped_event_attribute,
    /// Appended with the other script sinks' refusals: a quoted attribute
    /// name holding a character that would end it in a page
    /// (`language.md` §11.5).
    invalid_attribute_name,
    /// And beside it: a quoted `srcdoc`, a document the page runs.
    untyped_srcdoc_attribute,
    /// Appended with the first slice of effects: a `foreign` value with no
    /// rung, or with a word that is not one
    /// (transparent-effects-proposal.md §14.1).
    foreign_effect_missing,
    unknown_foreign_effect,
    /// Appended with the `sync` step (transparent-effects-proposal.md §15):
    /// a `sync` that marks no function the platform receives, a function
    /// that may suspend handed where one must not, and a declaration that
    /// is a boundary itself (`main`, a type's `eq` or `compare`) that may.
    misplaced_sync,
    sync_boundary,
    must_not_suspend,
    /// A spike (research 47): `import Js` in a module that is neither
    /// core's nor a platform package's.
    js_outside_platform,
    /// Appended with the list syntax (language.md §6.8): `::` — an
    /// operator, a pattern or `(::)` — left the language, and the message
    /// is the bracket form of what was written; and a list pattern's second
    /// spread.
    cons_removed,
    two_spreads_in_pattern,
    /// Appended with the page shell (backend.md §2, *The page shell*): a
    /// platform's or an app's `"html"` template that cannot be read, or that
    /// never names the entry file with `{{entry}}`.
    invalid_html_shell,
    /// Appended with `λ` (language.md §12.1): a lambda written with the
    /// removed `\`, whose message is the head written `λ`.
    backslash_lambda_removed,
    /// Appended with the names that read right subject first (language.md
    /// §12.4): a use of `modBy`, `remainderBy` or `logBase`, whose
    /// message is the call written with `Int.mod`, `Int.rem` or
    /// `Float.log`; also what `beni fmt --migrate-names` reports a use it
    /// left alone under.
    name_removed,
    /// Appended with the call-style diagnostics (language.md §12.5): a
    /// `warning`, a call of `clamp` or one of seven `String` functions
    /// whose literal subject comes first and whose last argument does not —
    /// the shape of a call written in Elm's order.
    suspicious_argument_order,
    /// Appended with blocks (language.md §12.2): a `let` written with the
    /// removed form, whose message is the block its bindings become; a
    /// block whose last item is a binding rather than its value; and a
    /// statement whose type is not `()` (checker-v2.md §29.1).
    let_removed,
    block_ends_in_binding,
    statement_not_unit,
    /// Appended with the Unicode notation (language.md §12.7–§12.8): an old
    /// ASCII spelling — `->`, `<-`, `/=`, `<=`, `>=`, `|>`, `<|`,
    /// `...` — reported at every occurrence, its message naming the symbol;
    /// and a tuple type written `( a, b )`, whose message is the type
    /// written with `×`.
    ascii_symbol_removed,
    tuple_type_removed,
    /// Appended on 2026-10-02 (`backend.md` §4, *The emitter's imports of
    /// the core-private exports*): a core package — one `--core-root`
    /// names, since the embedded one always holds them — that does not
    /// declare a value the code generator calls on its own: `Basics.eq`,
    /// `String.compare`, or `core/List`'s `unsafeGet`, `view`, `base`,
    /// `offset` and `close`. Reported at the code that needs it, because
    /// the build would otherwise import a name the core does not export
    /// and the program would fail to load.
    core_contract_violation,
    /// Appended on 2026-10-02 with `Js.object` (`boundary.md` §4.2): a call
    /// whose fields are not a list literal of `( "key", value )` pairs, each
    /// key a string literal that is a JavaScript identifier other than
    /// `__proto__`, no key twice. The checker's, at the call.
    invalid_js_object,
    /// Appended on 2026-10-02 with type identities
    /// (`static-dispatch-spike.md` §8.6, checker-v2.md §33): a site that
    /// must pass a type's identity — a key's, to `Hosted.key` through
    /// `Cmd.keyed` or `Sub.listen` — at a type that mentions a variable its
    /// declaration has no requirement on, or a declaration that takes an
    /// identity used as evidence. The checker's, at the site.
    type_identity_unknown,
    /// Appended on 2026-10-02 with `⊤` and `⊥` (language.md §12.10): `()`
    /// in a type, an expression or a pattern (the parser's, from the
    /// enforce step); `Never` naming `Basics`' empty type (lowering's, from
    /// the enforce step); the `then` branch of an `if` without `else` whose
    /// type is not `⊤` (the checker's); and a `_ =` in front of a `⊤`, a
    /// `warning` (the checker's, checker-v2.md §34).
    unit_spelling_removed,
    never_spelling_removed,
    if_without_else_not_unit,
    unit_discarded,
};

/// Every code has exactly one title (frontend.md §1.1). Titles are SHOUTING
/// CASE in Elm's register: they name the problem, not the rule.
pub fn title(code: Code) []const u8 {
    return switch (code) {
        .invalid_utf8 => "INVALID UTF-8",
        .invalid_module_path => "INVALID MODULE PATH",
        .bare_carriage_return => "BARE CARRIAGE RETURN",
        .tab_in_source => "TAB CHARACTER",
        .invalid_character => "INVALID CHARACTER",
        .invalid_number => "INVALID NUMBER",
        .unterminated_string => "UNTERMINATED STRING",
        .invalid_escape => "INVALID ESCAPE",
        .nested_string_in_interpolation => "STRING INSIDE INTERPOLATION",
        .invalid_char_literal => "INVALID CHAR LITERAL",
        .doc_comment_unattached => "UNATTACHED DOC COMMENT",
        .module_doc_not_at_top => "MODULE DOC NOT AT TOP",
        .expected_declaration => "EXPECTED DECLARATION",
        .expected_token => "EXPECTED TOKEN",
        .unexpected_token => "UNEXPECTED TOKEN",
        .unclosed_delimiter => "UNCLOSED DELIMITER",
        .annotation_without_definition => "ANNOTATION WITHOUT DEFINITION",
        .pub_on_definition => "PUB ON DEFINITION",
        .opaque_not_on_type => "OPAQUE NOT ON TYPE",
        .case_without_branches => "CASE WITHOUT BRANCHES",
        .args_after_question => "ARGUMENTS AFTER QUESTION MARK",
        .non_associative_chain => "NON-ASSOCIATIVE OPERATOR CHAIN",
        .negation_with_space => "NEGATION WITH SPACE",
        .invalid_tuple_index => "INVALID TUPLE INDEX",
        .refutable_let_pattern => "REFUTABLE PATTERN",
        .refutable_parameter_pattern => "REFUTABLE PARAMETER",
        .placeholder_outside_argument => "PLACEHOLDER OUTSIDE ARGUMENT",
        .multiple_placeholders => "TWO PLACEHOLDERS",
        .operator_not_a_function => "OPERATOR IS NOT A FUNCTION",
        .pipe_rhs_not_application => "PIPE WITHOUT A CALL",
        .bind_rhs_not_application => "BIND WITHOUT A CALL",
        .arrow_in_tuple_element => "ARROW IN A TUPLE ELEMENT",
        .bind_rhs_forward_reference => "BIND USES A LATER BINDING",
        .let_forward_reference => "LET BINDING USED TOO SOON",
        .cyclic_value => "VALUE DEFINED IN TERMS OF ITSELF",
        .nesting_too_deep => "NESTING TOO DEEP",
        .duplicate_exposed_name => "DUPLICATE EXPOSED NAME",
        .duplicate_import => "DUPLICATE IMPORT",
        .duplicate_import_alias => "DUPLICATE IMPORT ALIAS",
        .import_after_declaration => "IMPORT AFTER DECLARATION",
        .self_import => "SELF IMPORT",
        .duplicate_declaration => "DUPLICATE DECLARATION",
        .duplicate_type => "DUPLICATE TYPE",
        .duplicate_constructor => "DUPLICATE CONSTRUCTOR",
        .shadows_import => "SHADOWS IMPORT",
        .duplicate_field => "DUPLICATE FIELD",
        .foreign_outside_platform => "FOREIGN OUTSIDE PLATFORM",
        .equatable_outside_core => "EQUATABLE OUTSIDE CORE",
        .equatable_not_first_occurrence => "EQUATABLE MARKER REPEATED",
        .unbound_variable => "NAMING ERROR",
        .unbound_constructor => "UNKNOWN CONSTRUCTOR",
        .unbound_type => "UNKNOWN TYPE",
        .unknown_module_alias => "UNKNOWN MODULE",
        .question_in_lambda => "QUESTION MARK IN LAMBDA",
        .question_outside_function => "QUESTION MARK OUTSIDE FUNCTION",
        .shadowing => "SHADOWING",
        .duplicate_pattern_variable => "DUPLICATE PATTERN VARIABLE",
        .duplicate_type_parameter => "DUPLICATE TYPE PARAMETER",
        .unbound_type_variable => "UNBOUND TYPE VARIABLE",
        .unknown_module => "UNKNOWN MODULE",
        .duplicate_module => "DUPLICATE MODULE",
        .import_cycle => "IMPORT CYCLE",
        .unknown_import_name => "UNKNOWN IMPORT NAME",
        .private_name => "PRIVATE NAME",
        .opaque_constructor => "OPAQUE CONSTRUCTOR",
        .wrong_type_arity => "WRONG TYPE ARITY",
        .recursive_alias => "RECURSIVE ALIAS",
        .type_mismatch => "TYPE MISMATCH",
        .rigid_mismatch => "TYPE MISMATCH",
        .infinite_type => "INFINITE TYPE",
        .kind_mismatch => "TYPE MISMATCH",
        .too_few_args => "TOO FEW ARGS",
        .too_many_args => "TOO MANY ARGS",
        .not_a_function => "NOT A FUNCTION",
        .missing_field => "MISSING FIELD",
        .unknown_field => "UNKNOWN FIELD",
        .record_not_closed => "RECORD NOT CLOSED",
        .not_equatable => "NOT EQUATABLE",
        .not_interpolatable => "NOT INTERPOLATABLE",
        .ambiguous_interpolation => "AMBIGUOUS INTERPOLATION",
        .ambiguous_tuple => "AMBIGUOUS TUPLE",
        .tuple_index_out_of_range => "TUPLE INDEX OUT OF RANGE",
        .not_a_tuple => "NOT A TUPLE",
        .try_shape => "BAD QUESTION MARK",
        .missing_patterns => "MISSING PATTERNS",
        .redundant_pattern => "REDUNDANT PATTERN",
        .pattern_budget_exhausted => "CASE TOO BIG TO CHECK",
        .foreign_bad_shape => "BAD FOREIGN TYPE",
        .foreign_sibling_missing => "MISSING JAVASCRIPT FILE",
        .foreign_export_mismatch => "FOREIGN EXPORT MISMATCH",
        .foreign_unbound_reference => "UNBOUND JAVASCRIPT REFERENCE",
        .foreign_arity_mismatch => "FOREIGN ARITY MISMATCH",
        .missing_main => "MISSING MAIN",
        .duplicate_main => "TWO MAINS",
        .main_not_program => "MAIN IS NOT A PROGRAM",
        .where_variable_unbound => "UNKNOWN CONSTRAINED VARIABLE",
        .duplicate_where_constraint => "DUPLICATE CONSTRAINT",
        .unknown_method => "UNKNOWN METHOD",
        .private_method => "PRIVATE METHOD",
        .no_methods_on_shape => "NO METHODS HERE",
        .missing_where_constraint => "MISSING CONSTRAINT",
        .method_constraint_mismatch => "CONFLICTING METHOD TYPES",
        .type_dispatch_needs_annotation => "TYPE DISPATCH NEEDS AN ANNOTATION",
        .ambiguous_method_receiver => "CONSTRAINT IN AN INFERRED INTERFACE",
        .constrained_constant => "CONSTRAINED CONSTANT",
        .too_many_inferred_constraints => "TOO MANY INFERRED CONSTRAINTS",
        .debug_in_release => "DEBUG IN A RELEASE BUILD",
        .output_path_collision => "OUTPUT PATHS COLLIDE",
        .invalid_entry_file => "INVALID ENTRY FILE NAME",
        .schema_used_as_type => "SCHEMA IS NOT A TYPE",
        .schema_used_as_value => "SCHEMA IS NOT A VALUE",
        .schema_name_collision => "AMBIGUOUS SCHEMA NAME",
        .unknown_schema_member => "UNKNOWN SCHEMA MEMBER",
        .expected_schema => "EXPECTED A SCHEMA",
        .duplicate_schema_key => "DUPLICATE EXTERNAL KEY",
        .duplicate_schema_tag => "DUPLICATE SCHEMA TAG",
        .duplicate_schema_modifier => "DUPLICATE SCHEMA MODIFIER",
        .schema_conversion_mismatch => "SCHEMA CONVERSION MISMATCH",
        .method_needs_annotation => "METHOD NEEDS AN ANNOTATION",
        .too_many_type_parameters => "TOO MANY TYPE PARAMETERS",
        .unknown_output_record => "UNKNOWN FILE IN THE OUTPUT DIRECTORY",
        .unclosed_element => "UNCLOSED ELEMENT",
        .mismatched_closing_tag => "MISMATCHED CLOSING TAG",
        .element_as_argument => "MARKUP AS AN ARGUMENT",
        .duplicate_attribute => "DUPLICATE ATTRIBUTE",
        .spread_on_element => "SPREAD ON AN ELEMENT",
        .spread_not_first => "SPREAD NOT FIRST",
        .invalid_form_children => "INVALID CHILDREN",
        .vocabulary_outside_platform => "VOCABULARY OUTSIDE PLATFORM",
        .no_markup_vocabulary => "NO MARKUP VOCABULARY",
        .unknown_element => "UNKNOWN ELEMENT",
        .unknown_attribute => "UNKNOWN ATTRIBUTE",
        .child_not_renderable => "CHILD CANNOT BE RENDERED",
        .void_element_with_children => "VOID ELEMENT WITH CHILDREN",
        .invalid_keyed => "INVALID KEYED",
        .key_not_primitive => "KEY IS NOT PRIMITIVE",
        .unkeyed_for => "UNKEYED FOR",
        .raw_markup_attribute => "RAW MARKUP ATTRIBUTE",
        .markup_restructured => "MARKUP RESTRUCTURED",
        .unknown_markup_lowering => "UNKNOWN MARKUP LOWERING",
        .unknown_form_attribute => "UNKNOWN FORM ATTRIBUTE",
        .missing_form_attribute => "MISSING ATTRIBUTE",
        .markup_type_in_foreign => "MARKUP TYPE IN FOREIGN",
        .untyped_event_attribute => "UNTYPED EVENT ATTRIBUTE",
        .invalid_attribute_name => "INVALID ATTRIBUTE NAME",
        .untyped_srcdoc_attribute => "UNTYPED SRCDOC ATTRIBUTE",
        .foreign_effect_missing => "FOREIGN WITHOUT EFFECT",
        .unknown_foreign_effect => "UNKNOWN FOREIGN EFFECT",
        .misplaced_sync => "MISPLACED SYNC",
        .sync_boundary => "SUSPENDING CALLBACK",
        .must_not_suspend => "MUST NOT SUSPEND",
        .js_outside_platform => "JS OUTSIDE PLATFORM",
        .cons_removed => "REMOVED OPERATOR",
        .two_spreads_in_pattern => "TWO SPREADS IN ONE PATTERN",
        .invalid_html_shell => "INVALID PAGE SHELL",
        .backslash_lambda_removed => "REMOVED LAMBDA SYNTAX",
        .name_removed => "REMOVED NAME",
        .suspicious_argument_order => "SUSPICIOUS ARGUMENT ORDER",
        .ascii_symbol_removed => "REMOVED ASCII SYMBOL",
        .tuple_type_removed => "REMOVED TUPLE TYPE",
        .core_contract_violation => "CORE CONTRACT VIOLATION",
        .invalid_js_object => "INVALID OBJECT FIELDS",
        .type_identity_unknown => "UNKNOWN TYPE IDENTITY",
        .unit_spelling_removed => "REMOVED UNIT SPELLING",
        .never_spelling_removed => "REMOVED NEVER SPELLING",
        .if_without_else_not_unit => "MISSING ELSE",
        .unit_discarded => "UNIT DISCARDED",
        .let_removed => "REMOVED LET SYNTAX",
        .block_ends_in_binding => "BLOCK WITHOUT A VALUE",
        .statement_not_unit => "UNUSED VALUE",
        .not_implemented => "NOT IMPLEMENTED YET",
        .internal => "INTERNAL ERROR",
    };
}

/// The emission order (frontend.md §1): file path, then start position, then
/// code — never worker or completion order. Total on the three keys; two
/// diagnostics equal in all three are kept in the order the compiler produced
/// them, so callers must use a STABLE sort (`sort` below does).
pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    switch (std.mem.order(u8, a.span.file, b.span.file)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (a.span.start.order(b.span.start)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return @backingInt(a.code) < @backingInt(b.code);
}

/// Sort into emission order. Stable, so equal keys keep production order.
pub fn sort(diagnostics: []Diagnostic) void {
    std.mem.sort(Diagnostic, diagnostics, {}, lessThan);
}

/// The code `raw` names, or null when no version of this compiler defines
/// one. A cached diagnostic stores its code as an integer, which is
/// meaningful only for the build the key names — and a value the enum does
/// not define must be a miss rather than an `@enumFromInt` past the end.
pub fn codeFromInt(raw: u16) ?Code {
    const fields = @typeInfo(Code).@"enum".field_names;
    if (raw >= fields.len) return null;
    return @fromBackingInt(@intCast(raw));
}

pub fn severityFromInt(raw: u8) ?Severity {
    const fields = @typeInfo(Severity).@"enum".field_names;
    if (raw >= fields.len) return null;
    return @fromBackingInt(@intCast(raw));
}

/// 1-based line and column of `offset` in `source` (frontend.md §3.1). A
/// column counts code points from the line start, not bytes (language.md
/// §12.7, *columns*), so `→` or `λ` is one column, as an editor shows it.
/// `line_starts` is the tokenizer's table: `line_starts[0] == 0`, one entry
/// per newline, ascending. An offset at or past the end of the file lands
/// on the last line, one column per byte past the end.
pub fn position(line_starts: []const u32, source: []const u8, offset: u32) Position {
    const l = lineIndex(line_starts, offset);
    return .{ .line = @intCast(l + 1), .col = column(source, line_starts[l], offset) };
}

/// 1-based line of `offset`: `position`'s line, for a caller that needs no
/// column and so no source.
pub fn lineOf(line_starts: []const u32, offset: u32) u32 {
    return @intCast(lineIndex(line_starts, offset) + 1);
}

/// 0-based index of the line holding `offset`: the largest `l` with
/// `line_starts[l] <= offset`.
fn lineIndex(line_starts: []const u32, offset: u32) usize {
    std.debug.assert(line_starts.len > 0);
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return lo;
}

/// 1-based column of `offset` on the line that begins at `line_start`:
/// one more than the code points between them. Bytes past the end of
/// `source` count one each.
pub fn column(source: []const u8, line_start: u32, offset: u32) u32 {
    const end = @min(offset, source.len);
    const start = @min(line_start, end);
    return codePoints(source[start..end]) + (offset - @max(end, line_start)) + 1;
}

/// The code points in `bytes`: a well-formed UTF-8 sequence counts one,
/// and every byte of an ill-formed one counts one on its own, as an editor
/// shows each as a replacement character.
pub fn codePoints(bytes: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (n += 1) i += codePointLength(bytes, i);
    return n;
}

/// The byte offset in `bytes` of its code point number `n` (0-based, as
/// `codePoints` counts them), or `bytes.len` when it has fewer.
pub fn codePointOffset(bytes: []const u8, n: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < bytes.len and seen < n) : (seen += 1) i += codePointLength(bytes, i);
    return @min(i, bytes.len);
}

/// The length of the code point at `bytes[i]`: its sequence's when that is
/// well-formed, else 1.
fn codePointLength(bytes: []const u8, i: usize) usize {
    if (bytes[i] < 0x80) return 1;
    const len: usize = switch (bytes[i]) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return 1,
    };
    if (i + len > bytes.len) return 1;
    for (bytes[i + 1 .. i + len]) |b| if (b & 0xC0 != 0x80) return 1;
    return len;
}

test "codePoints: a sequence counts one, a stray byte one of its own" {
    try std.testing.expectEqual(@as(u32, 0), codePoints(""));
    try std.testing.expectEqual(@as(u32, 3), codePoints("a→b"));
    try std.testing.expectEqual(@as(u32, 2), codePoints("λ×"));
    try std.testing.expectEqual(@as(u32, 1), codePoints("😀"));
    // A continuation byte with no lead, a lead cut short, and 0xFF.
    try std.testing.expectEqual(@as(u32, 3), codePoints("\x80\xE2\x86"));
    try std.testing.expectEqual(@as(u32, 2), codePoints("\xFFa"));
}

test "every code has a non-empty title" {
    inline for (@typeInfo(Code).@"enum".field_values) |field_value| {
        const code: Code = @fromBackingInt(@intCast(field_value));
        try std.testing.expect(title(code).len > 0);
    }
}

test "sort orders by file, then start, then code, and is stable" {
    var diags = [_]Diagnostic{
        .{ .code = .shadowing, .severity = .@"error", .span = .{ .file = "b.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 2 } }, .title = "", .message = "3" },
        .{ .code = .tab_in_source, .severity = .@"error", .span = .{ .file = "a.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 6 } }, .title = "", .message = "2" },
        .{ .code = .tab_in_source, .severity = .@"error", .span = .{ .file = "a.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 6 } }, .title = "", .message = "2-again" },
        .{ .code = .invalid_utf8, .severity = .@"error", .span = .{ .file = "a.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 6 } }, .title = "", .message = "1" },
        .{ .code = .invalid_utf8, .severity = .@"error", .span = .{ .file = "a.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 10 } }, .title = "", .message = "0" },
    };
    sort(&diags);
    const expected = [_][]const u8{ "0", "1", "2", "2-again", "3" };
    for (expected, diags) |want, got| try std.testing.expectEqualStrings(want, got.message);
}

test "JSON round trip preserves the whole struct" {
    const original = Diagnostic{
        .code = .invalid_module_path,
        .severity = .@"error",
        .span = .{ .file = "src/bad-name.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = title(.invalid_module_path),
        .message = "quote \" backslash \\ newline \n tab \t done",
    };
    const gpa = std.testing.allocator;
    const text = try std.json.Stringify.valueAlloc(gpa, original, .{});
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(Diagnostic, gpa, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(original, parsed.value);
}

test "position: binary search over the line table, including the last line" {
    const starts = [_]u32{ 0, 3, 4, 10 };
    const source = "ab\n\nabcde\n";
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 1 }, position(&starts, source, 0));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 3 }, position(&starts, source, 2));
    try std.testing.expectEqualDeep(Position{ .line = 2, .col = 1 }, position(&starts, source, 3));
    try std.testing.expectEqualDeep(Position{ .line = 3, .col = 1 }, position(&starts, source, 4));
    try std.testing.expectEqualDeep(Position{ .line = 3, .col = 6 }, position(&starts, source, 9));
    try std.testing.expectEqualDeep(Position{ .line = 4, .col = 1 }, position(&starts, source, 10));
    try std.testing.expectEqualDeep(Position{ .line = 4, .col = 91 }, position(&starts, source, 100));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 8 }, position(&.{0}, "", 7));
}

test "position: a column counts code points, not bytes" {
    // language.md §12.7, *columns*: `λ` is two bytes and `→` three, one
    // column each, so `x` after `λa → ` is at column 6.
    const source = "λa → x\nb";
    const starts = [_]u32{ 0, 10 };
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 2 }, position(&starts, source, 2));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 4 }, position(&starts, source, 4));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 6 }, position(&starts, source, 8));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 7 }, position(&starts, source, 9));
    try std.testing.expectEqualDeep(Position{ .line = 2, .col = 1 }, position(&starts, source, 10));
    try std.testing.expectEqual(@as(u32, 2), lineOf(&starts, 10));
}
