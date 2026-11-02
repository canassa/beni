//! Pinned WebIDL catalogue reader (workers-native-bindings.md). It preserves
//! source spans instead of guessing a beni mapping or native failure adapter.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_source_bytes = 4 * 1024 * 1024;
pub const max_nesting = 128;
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
    pub fn text(s: Span, source: []const u8) []const u8 {
        return source[s.start..s.end];
    }
};
pub const Kind = enum {
    interface,
    callback_interface,
    mixin,
    namespace,
    dictionary,
    enumeration,
    typedef,
    callback,
    includes,
};
pub const Decl = struct {
    file: u32,
    kind: Kind,
    partial: bool,
    name: Span,
    parent: Span = .{},
    attributes: Span,
    source: Span,
    members_start: u32,
    members_end: u32,
};
pub const Member = struct { file: u32, owner: u32, source: Span };
pub const Code = enum { source_too_large, unexpected_token, unterminated_comment, unterminated_string, unbalanced_delimiter, nesting_limit };
pub const Diagnostic = struct { code: Code, file: u32, offset: u32 };
pub const Error = Allocator.Error || error{InvalidIdl};
pub const Table = struct {
    declarations: std.MultiArrayList(Decl) = .empty,
    members: std.MultiArrayList(Member) = .empty,
    diagnostic: ?Diagnostic = null,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.declarations.deinit(gpa);
        t.members.deinit(gpa);
    }

    pub fn append(t: *Table, gpa: Allocator, file: u32, source: []const u8) Error!void {
        if (source.len > max_source_bytes) {
            t.diagnostic = .{ .code = .source_too_large, .file = file, .offset = 0 };
            return error.InvalidIdl;
        }
        var tokens: std.ArrayList(Token) = .empty;
        defer tokens.deinit(gpa);
        var lex: Lexer = .{ .source = source };
        while (true) {
            const token = lex.next() catch |err| {
                t.diagnostic = .{ .code = switch (err) {
                    error.UnterminatedComment => .unterminated_comment,
                    error.UnterminatedString => .unterminated_string,
                }, .file = file, .offset = @intCast(lex.at) };
                return error.InvalidIdl;
            };
            try tokens.append(gpa, token);
            if (token.tag == .eof) break;
        }
        var parser: Parser = .{ .gpa = gpa, .table = t, .source = source, .file = file, .tokens = tokens.items };
        try parser.run();
    }
};

const Token = struct { tag: enum { identifier, string, punctuation, eof }, span: Span };
const Lexer = struct {
    source: []const u8,
    at: usize = 0,

    fn next(l: *Lexer) error{ UnterminatedComment, UnterminatedString }!Token {
        const s = l.source;
        while (l.at < s.len) {
            if (std.ascii.isWhitespace(s[l.at])) {
                l.at += 1;
            } else if (std.mem.startsWith(u8, s[l.at..], "//")) {
                l.at += 2;
                while (l.at < s.len and s[l.at] != '\n') l.at += 1;
            } else if (std.mem.startsWith(u8, s[l.at..], "/*")) {
                l.at += 2;
                const end = std.mem.findPos(u8, s, l.at, "*/") orelse return error.UnterminatedComment;
                l.at = end + 2;
            } else break;
        }
        const start = l.at;
        if (start == s.len) return .{ .tag = .eof, .span = .{ .start = @intCast(start), .end = @intCast(start) } };
        const c = s[start];
        var tag: @FieldType(Token, "tag") = .punctuation;
        if (std.ascii.isAlphabetic(c) or c == '_') {
            tag = .identifier;
            l.at += 1;
            while (l.at < s.len and (std.ascii.isAlphanumeric(s[l.at]) or s[l.at] == '_' or s[l.at] == '-')) l.at += 1;
        } else if (c == '"') {
            tag = .string;
            l.at += 1;
            var ended = false;
            while (l.at < s.len) {
                const ch = s[l.at];
                l.at += 1;
                if (ch == '\\') {
                    if (l.at == s.len) return error.UnterminatedString;
                    l.at += 1;
                } else if (ch == '"') {
                    ended = true;
                    break;
                }
            }
            if (!ended) return error.UnterminatedString;
        } else l.at += 1;
        return .{ .tag = tag, .span = .{ .start = @intCast(start), .end = @intCast(l.at) } };
    }
};

const Parser = struct {
    gpa: Allocator,
    table: *Table,
    source: []const u8,
    file: u32,
    tokens: []const Token,
    at: usize = 0,

    fn fail(p: *Parser, code: Code) Error {
        p.table.diagnostic = .{ .code = code, .file = p.file, .offset = p.current().span.start };
        return error.InvalidIdl;
    }
    fn current(p: *Parser) Token {
        return p.tokens[p.at];
    }
    fn is(p: *Parser, text: []const u8) bool {
        return std.mem.eql(u8, p.current().span.text(p.source), text);
    }
    fn eat(p: *Parser, text: []const u8) bool {
        if (!p.is(text)) return false;
        p.at += 1;
        return true;
    }
    fn expect(p: *Parser, text: []const u8) Error!void {
        if (!p.eat(text)) return p.fail(.unexpected_token);
    }
    fn identifier(p: *Parser) Error!Span {
        if (p.current().tag != .identifier) return p.fail(.unexpected_token);
        const span = p.current().span;
        p.at += 1;
        return span;
    }
    fn attributes(p: *Parser) Error!Span {
        if (!p.is("[")) return .{};
        const start = p.current().span.start;
        _ = try p.balanced("[");
        return .{ .start = start, .end = p.tokens[p.at - 1].span.end };
    }
    // Every delimiter is checked, including braces in dictionary defaults and
    // parentheses inside extended attributes. Quoted strings are single tokens.
    fn balanced(p: *Parser, opening: []const u8) Error!void {
        if (!p.is(opening)) return p.fail(.unexpected_token);
        var stack: [max_nesting]u8 = undefined;
        var depth: usize = 0;
        while (p.current().tag != .eof) {
            const t = p.current();
            if (t.tag == .punctuation) {
                const c = t.span.text(p.source)[0];
                if (closer(c)) |close| {
                    if (depth == stack.len) return p.fail(.nesting_limit);
                    stack[depth] = close;
                    depth += 1;
                } else if (c == ')' or c == ']' or c == '}') {
                    if (depth == 0 or stack[depth - 1] != c) return p.fail(.unbalanced_delimiter);
                    depth -= 1;
                }
            }
            p.at += 1;
            if (depth == 0) return;
        }
        return p.fail(.unbalanced_delimiter);
    }
    fn untilSemicolon(p: *Parser) Error!void {
        while (p.current().tag != .eof) {
            if (p.eat(";")) return;
            if (p.is("(") or p.is("[") or p.is("{")) {
                const opening = p.current().span.text(p.source);
                try p.balanced(opening);
            } else {
                if (p.is(")") or p.is("]") or p.is("}")) return p.fail(.unbalanced_delimiter);
                p.at += 1;
            }
        }
        return p.fail(.unexpected_token);
    }
    fn body(p: *Parser, owner: u32, enumeration: bool) Error!void {
        if (enumeration) {
            try p.balanced("{");
            return;
        }
        try p.expect("{");
        while (!p.is("}")) {
            if (p.current().tag == .eof) return p.fail(.unbalanced_delimiter);
            const start = p.current().span.start;
            try p.untilSemicolon();
            try p.table.members.append(p.gpa, .{ .file = p.file, .owner = owner, .source = .{ .start = start, .end = p.tokens[p.at - 1].span.end } });
        }
        try p.expect("}");
    }
    fn run(p: *Parser) Error!void {
        while (p.current().tag != .eof) {
            const start = p.current().span.start;
            const attrs = try p.attributes();
            const partial = p.eat("partial");
            const callback = p.eat("callback");
            var kind: Kind = undefined;
            var name: Span = undefined;
            var parent: Span = .{};
            var has_body = true;
            if (p.eat("interface")) {
                kind = if (callback) .callback_interface else if (p.eat("mixin")) .mixin else .interface;
                name = try p.identifier();
                if (p.eat(":")) {
                    if (kind != .interface) return p.fail(.unexpected_token);
                    parent = try p.identifier();
                }
            } else if (callback) {
                kind = .callback;
                name = try p.identifier();
                try p.expect("=");
                has_body = false;
            } else if (p.eat("dictionary")) {
                kind = .dictionary;
                name = try p.identifier();
                if (p.eat(":")) parent = try p.identifier();
            } else if (p.eat("namespace")) {
                kind = .namespace;
                name = try p.identifier();
            } else if (p.eat("enum")) {
                kind = .enumeration;
                name = try p.identifier();
            } else if (p.eat("typedef")) {
                kind = .typedef;
                has_body = false;
                const before = p.at;
                try p.untilSemicolon();
                if (p.at < before + 2 or p.tokens[p.at - 2].tag != .identifier) return p.fail(.unexpected_token);
                name = p.tokens[p.at - 2].span;
            } else if (!partial and p.current().tag == .identifier) {
                kind = .includes;
                name = try p.identifier();
                try p.expect("includes");
                parent = try p.identifier();
                has_body = false;
            } else return p.fail(.unexpected_token);
            if (partial and kind != .interface and kind != .mixin and kind != .dictionary and kind != .namespace) return p.fail(.unexpected_token);
            const owner: u32 = @intCast(p.table.declarations.len);
            const members_start: u32 = @intCast(p.table.members.len);
            if (has_body) {
                try p.body(owner, kind == .enumeration);
                try p.expect(";");
            } else if (kind == .includes) {
                try p.expect(";");
            } else if (kind != .typedef) {
                try p.untilSemicolon();
            }
            try p.table.declarations.append(p.gpa, .{ .file = p.file, .kind = kind, .partial = partial, .name = name, .parent = parent, .attributes = attrs, .source = .{ .start = start, .end = p.tokens[p.at - 1].span.end }, .members_start = members_start, .members_end = @intCast(p.table.members.len) });
        }
    }
};

fn closer(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

test "IDL keeps partials, quoted delimiters, includes and full member signatures" {
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);
    const source =
        \\[Exposed=(Window,Worker)] interface Child : Parent {
        \\  undefined call(optional DOMString text = "};\"");
        \\};
        \\partial interface Child { attribute long x; };
        \\Child includes Mix;
        \\dictionary Options { object data = {}; };
        \\enum Name { "a;{}", "b" };
        \\typedef (DOMString or long) NameOrNumber;
        \\callback Done = undefined (long value);
    ;
    try table.append(std.testing.allocator, 0, source);
    try std.testing.expectEqual(@as(usize, 7), table.declarations.len);
    try std.testing.expectEqual(@as(usize, 3), table.members.len);
    try std.testing.expectEqualStrings("Child", table.declarations.get(0).name.text(source));
    try std.testing.expectEqualStrings("Parent", table.declarations.get(0).parent.text(source));
    try std.testing.expectEqualStrings("undefined call(optional DOMString text = \"};\\\"\");", table.members.get(0).source.text(source));
    try std.testing.expectEqual(Kind.includes, table.declarations.get(2).kind);
    try std.testing.expectEqual(Kind.typedef, table.declarations.get(5).kind);
    try std.testing.expectEqual(Kind.callback, table.declarations.get(6).kind);
}

test "IDL rejects mismatched nesting and reports the exact source offset" {
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidIdl, table.append(std.testing.allocator, 3, "interface X { undefined f(]; };"));
    try std.testing.expectEqualDeep(@as(?Diagnostic, .{ .code = .unbalanced_delimiter, .file = 3, .offset = 26 }), table.diagnostic);
}

test "IDL byte parser never traps" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var source: [2048]u8 = undefined;
            const bytes = smith.sliceWithHash(&source, 0x3a219);
            var table: Table = .{};
            defer table.deinit(std.testing.allocator);
            table.append(std.testing.allocator, 0, source[0..bytes]) catch |err| switch (err) {
                error.InvalidIdl => {},
                error.OutOfMemory => return err,
            };
        }
    }.one, .{});
}

/// Parsed values of one top-level extended attribute. Comments and quoted
/// strings use the same lexer as declarations, so they cannot grant exposure.
pub fn attributeNames(gpa: Allocator, source: []const u8, wanted: []const u8) Error![]const []const u8 {
    if (source.len == 0) return &.{};
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    var lexer: Lexer = .{ .source = source };
    while (true) {
        const token = lexer.next() catch return error.InvalidIdl;
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }
    var depth: usize = 0;
    for (tokens.items, 0..) |token, i| {
        const text = token.span.text(source);
        if (token.tag == .punctuation) {
            if (std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "(")) depth += 1;
            if (std.mem.eql(u8, text, "]") or std.mem.eql(u8, text, ")")) depth -|= 1;
        }
        if (depth != 1 or token.tag != .identifier or !std.mem.eql(u8, text, wanted)) continue;
        // An identifier used as another attribute's value is not a key.
        // Comments are absent from this token stream, so a real key follows
        // the opening bracket or an outer comma even when comments intervene.
        if (i == 0) continue;
        const previous = tokens.items[i - 1];
        const previous_text = previous.span.text(source);
        if (previous.tag != .punctuation or
            (!std.mem.eql(u8, previous_text, "[") and !std.mem.eql(u8, previous_text, ","))) continue;
        var at = i + 1;
        if (!std.mem.eql(u8, tokens.items[at].span.text(source), "=")) return error.InvalidIdl;
        at += 1;
        const list = std.mem.eql(u8, tokens.items[at].span.text(source), "(");
        if (list) at += 1;
        var names: std.ArrayList([]const u8) = .empty;
        while (at < tokens.items.len) {
            const value = tokens.items[at];
            const value_text = value.span.text(source);
            if (value.tag != .identifier and !std.mem.eql(u8, value_text, "*")) return error.InvalidIdl;
            try names.append(gpa, value_text);
            at += 1;
            if (!list) return names.toOwnedSlice(gpa);
            const next = tokens.items[at].span.text(source);
            if (std.mem.eql(u8, next, ")")) return names.toOwnedSlice(gpa);
            if (!std.mem.eql(u8, next, ",")) return error.InvalidIdl;
            at += 1;
        }
        return error.InvalidIdl;
    }
    return &.{};
}

test "IDL exposure uses attribute tokens and stops before the next attribute" {
    const gpa = std.testing.allocator;
    const one = try attributeNames(gpa, "[Other=\"Exposed=Worker\", Exposed=Window, SecureContext]", "Exposed");
    defer gpa.free(one);
    try std.testing.expectEqualDeep(&[_][]const u8{"Window"}, one);
    const many = try attributeNames(gpa, "[/* Exposed=Wrong */ Global=(Worker, DedicatedWorker), Exposed=*]", "Global");
    defer gpa.free(many);
    try std.testing.expectEqualDeep(&[_][]const u8{ "Worker", "DedicatedWorker" }, many);
}

test "IDL quoted URL preserves the Sanitizer namespace field" {
    const source =
        \\dictionary SanitizerElementNamespace {
        \\  required DOMString name;
        \\  DOMString? _namespace = "http://www.w3.org/1999/xhtml";
        \\};
    ;
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);
    try table.append(std.testing.allocator, 0, source);
    try std.testing.expectEqual(@as(usize, 2), table.members.len);
    try std.testing.expectEqualStrings("DOMString? _namespace = \"http://www.w3.org/1999/xhtml\";", table.members.get(1).source.text(source));
}

test "IDL exposure names used as another attribute value do not grant a realm" {
    const gpa = std.testing.allocator;
    const names = try attributeNames(gpa, "[Other=Exposed, SecureContext]", "Exposed");
    defer gpa.free(names);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{}), names);
}
