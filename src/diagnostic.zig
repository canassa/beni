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

/// 1-based line and column; the column counts bytes from the line start
/// (language.md §2.1). Tabs are forbidden, so byte column is visual column.
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
    // M2a (checker.md §8.1): the module graph and cross-module resolution.
    unknown_module,
    duplicate_module,
    import_cycle,
    unknown_import_name,
    private_name,
    opaque_constructor,
    wrong_type_arity,
    recursive_alias,
    // M2b (checker.md §8.1): inference. `rigid_mismatch` is the case where
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
    // M2c (checker.md §6.6, §8.1): pattern usefulness. Both are reported
    // after a declaration solves cleanly, so the patterns they judge are
    // known to be well typed.
    missing_patterns,
    redundant_pattern,
    // M3a / B1 (boundary.md §4, §5): the platform contract. Every one of
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
    // of §10 are the checker's and land with S3.
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
    /// `boundary.md` §4's fourth check, appended on 2026-09-18 (queue slice
    /// 4, `static-dispatch-spike.md` A.84): a sibling export whose parameter
    /// count is not evidence count + declared arity, or whose parameter list
    /// the scanner may not count.
    foreign_arity_mismatch,
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
        .foreign_bad_shape => "BAD FOREIGN TYPE",
        .foreign_sibling_missing => "MISSING JAVASCRIPT FILE",
        .foreign_export_mismatch => "FOREIGN EXPORT MISMATCH",
        .foreign_unbound_reference => "UNBOUND JAVASCRIPT REFERENCE",
        .foreign_arity_mismatch => "FOREIGN ARITY MISMATCH",
        .missing_main => "MISSING MAIN",
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
    return @intFromEnum(a.code) < @intFromEnum(b.code);
}

/// Sort into emission order. Stable, so equal keys keep production order.
pub fn sort(diagnostics: []Diagnostic) void {
    std.mem.sort(Diagnostic, diagnostics, {}, lessThan);
}

/// 1-based line and byte column of `offset` (frontend.md §3.1: column is
/// `offset - line_starts[line] + 1`). `line_starts` is the tokenizer's table:
/// `line_starts[0] == 0`, one entry per newline, ascending. An offset at or
/// past the end of the file lands on the last line.
pub fn position(line_starts: []const u32, offset: u32) Position {
    std.debug.assert(line_starts.len > 0);
    // Largest `l` with `line_starts[l] <= offset`.
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return .{ .line = @intCast(lo + 1), .col = offset - line_starts[lo] + 1 };
}

test "every code has a non-empty title" {
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const code: Code = @enumFromInt(field.value);
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
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 1 }, position(&starts, 0));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 3 }, position(&starts, 2));
    try std.testing.expectEqualDeep(Position{ .line = 2, .col = 1 }, position(&starts, 3));
    try std.testing.expectEqualDeep(Position{ .line = 3, .col = 1 }, position(&starts, 4));
    try std.testing.expectEqualDeep(Position{ .line = 3, .col = 6 }, position(&starts, 9));
    try std.testing.expectEqualDeep(Position{ .line = 4, .col = 1 }, position(&starts, 10));
    try std.testing.expectEqualDeep(Position{ .line = 4, .col = 91 }, position(&starts, 100));
    try std.testing.expectEqualDeep(Position{ .line = 1, .col = 8 }, position(&.{0}, 7));
}
