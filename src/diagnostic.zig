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
    nesting_too_deep,
    duplicate_import,
    duplicate_import_alias,
    import_after_declaration,
    self_import,
    duplicate_declaration,
    duplicate_type,
    duplicate_constructor,
    shadows_import,
    duplicate_field,
    foreign_outside_core,
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
    internal,
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
        .nesting_too_deep => "NESTING TOO DEEP",
        .duplicate_import => "DUPLICATE IMPORT",
        .duplicate_import_alias => "DUPLICATE IMPORT ALIAS",
        .import_after_declaration => "IMPORT AFTER DECLARATION",
        .self_import => "SELF IMPORT",
        .duplicate_declaration => "DUPLICATE DECLARATION",
        .duplicate_type => "DUPLICATE TYPE",
        .duplicate_constructor => "DUPLICATE CONSTRUCTOR",
        .shadows_import => "SHADOWS IMPORT",
        .duplicate_field => "DUPLICATE FIELD",
        .foreign_outside_core => "FOREIGN OUTSIDE CORE",
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
