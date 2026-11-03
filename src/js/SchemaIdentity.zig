//! Exact Any identities for generated schema producers. Variable seats are
//! the supplied schema arguments' encoded/type identities, interleaved. The
//! text grammar is Identity.zig's; alias bodies bind their own argument seats.
const std = @import("std");
const Lowerer = @import("Lower.zig").Lowerer;
const Plan = @import("../check/SchemaPlan.zig");
const Interface = @import("../resolve/Interface.zig");
const JsIr = @import("JsIr.zig");
const Node = JsIr.Node;
const Error = std.mem.Allocator.Error;

pub fn expression(l: *Lowerer, plan: *const Plan, root: Interface.TermIndex, parameters: []const Node.Index, pos: u32) Error!?Node.Index {
    var writer: Writer = .{ .l = l, .plan = plan, .pos = pos };
    return writer.typeOf(root, parameters, 0);
}

const Writer = struct {
    l: *Lowerer,
    plan: *const Plan,
    pos: u32,
    visited: u32 = 0,

    fn literal(w: *Writer, bytes: []const u8) Error!Node.Index {
        return w.l.identityString(bytes, w.pos);
    }
    fn append(w: *Writer, left: Node.Index, right: Node.Index) Error!Node.Index {
        return w.l.binary(.add, left, right, w.pos);
    }
    fn text(w: *Writer, symbol: Interface.SymbolIndex) ?[]const u8 {
        if (@backingInt(symbol) >= w.plan.symbols.len) return null;
        return w.l.text(w.plan.symbols[@backingInt(symbol)]);
    }
    fn range(w: *Writer, index: u32) ?[]const u32 {
        if (index >= w.plan.type_extra.len) return null;
        const n = w.plan.type_extra[index];
        if (n > w.plan.type_extra.len - index - 1) return null;
        return w.plan.type_extra[index + 1 ..][0..n];
    }
    fn list(w: *Writer, words: []const u32, parameters: []const Node.Index, depth: u32) Error!?Node.Index {
        var out = try w.literal("");
        for (words, 0..) |word, i| {
            if (i != 0) out = try w.append(out, try w.literal(","));
            const child = try w.typeOf(@fromBackingInt(word), parameters, depth + 1) orelse return null;
            out = try w.append(out, child);
        }
        return out;
    }
    const Field = struct { name: []const u8, term: Interface.TermIndex, parameters: []const Node.Index };
    const Tail = struct { term: Interface.TermIndex, parameters: []const Node.Index };
    fn rowFields(w: *Writer, root: Interface.TermIndex, parameters: []const Node.Index, depth: u32, fields: *std.ArrayList(Field)) Error!?Tail {
        if (root == .none or root.int() >= w.plan.terms.len or depth > 400) return null;
        const row = w.plan.terms.get(root.int());
        switch (row.tag) {
            .record => {
                const words = w.range(row.lhs) orelse return null;
                if (words.len % 2 != 0) return null;
                var i: usize = 0;
                while (i < words.len) : (i += 2) try fields.append(w.l.scratch, .{
                    .name = w.text(@fromBackingInt(words[i])) orelse return null,
                    .term = @fromBackingInt(words[i + 1]),
                    .parameters = parameters,
                });
                return w.rowFields(@fromBackingInt(row.rhs), parameters, depth + 1, fields);
            },
            .alias => {
                if (row.lhs >= w.plan.type_refs.len) return null;
                const words = w.range(row.rhs) orelse return null;
                const args = try w.l.scratch.alloc(Node.Index, words.len);
                for (words, args) |word, *arg| arg.* = try w.typeOf(@fromBackingInt(word), parameters, depth + 1) orelse return null;
                return w.rowFields(w.plan.type_refs[row.lhs].body, args, depth + 1, fields);
            },
            else => return .{ .term = root, .parameters = parameters },
        }
    }
    fn record(w: *Writer, root: Interface.TermIndex, parameters: []const Node.Index, depth: u32) Error!?Node.Index {
        var fields: std.ArrayList(Field) = .empty;
        const tail = try w.rowFields(root, parameters, depth, &fields) orelse return null;
        std.mem.sort(Field, fields.items, {}, struct {
            fn lessThan(_: void, a: Field, b: Field) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        var out = try w.literal("{");
        for (fields.items, 0..) |field, i| {
            if (i != 0) out = try w.append(out, try w.literal(","));
            out = try w.append(out, try w.literal(field.name));
            out = try w.append(out, try w.literal("="));
            out = try w.append(out, try w.typeOf(field.term, field.parameters, depth + 1) orelse return null);
        }
        if (w.plan.terms.get(tail.term.int()).tag != .empty_record) {
            out = try w.append(out, try w.literal("|"));
            out = try w.append(out, try w.typeOf(tail.term, tail.parameters, depth + 1) orelse return null);
        }
        return try w.append(out, try w.literal("}"));
    }
    fn typeOf(w: *Writer, root: Interface.TermIndex, parameters: []const Node.Index, depth: u32) Error!?Node.Index {
        if (root == .none or root.int() >= w.plan.terms.len or depth > 400) return null;
        w.visited += 1;
        if (w.visited > @import("../check/Identity.zig").max_parts) return null;
        const row = w.plan.terms.get(root.int());
        return switch (row.tag) {
            .err => null,
            .@"var" => if (row.lhs < parameters.len) parameters[row.lhs] else null,
            .unit => try w.literal("()"),
            .empty_record => try w.literal("{}"),
            .alias => alias: {
                if (row.lhs >= w.plan.type_refs.len) break :alias null;
                const ref = w.plan.type_refs[row.lhs];
                const words = w.range(row.rhs) orelse break :alias null;
                const args = try w.l.scratch.alloc(Node.Index, words.len);
                for (words, args) |word, *arg| arg.* = try w.typeOf(@fromBackingInt(word), parameters, depth + 1) orelse break :alias null;
                break :alias try w.typeOf(ref.body, args, depth + 1);
            },
            .app => app: {
                if (row.lhs >= w.plan.type_refs.len) break :app null;
                const ref = w.plan.type_refs[row.lhs];
                const module = w.text(ref.module) orelse break :app null;
                const name = w.text(ref.name) orelse break :app null;
                const prefix: []const u8 = switch (ref.package) {
                    .app => "",
                    .core => "core:",
                    .platform => "platform:",
                };
                const base = try std.fmt.allocPrint(w.l.scratch, "{s}{s}.{s}", .{ prefix, module, name });
                var out = try w.literal(base);
                const words = w.range(row.rhs) orelse break :app null;
                if (words.len != 0) {
                    out = try w.append(out, try w.literal("("));
                    out = try w.append(out, try w.list(words, parameters, depth) orelse break :app null);
                    out = try w.append(out, try w.literal(")"));
                }
                break :app out;
            },
            .func => func: {
                const words = w.range(row.lhs) orelse break :func null;
                const inputs = try w.list(words, parameters, depth) orelse break :func null;
                const output = try w.typeOf(@fromBackingInt(row.rhs), parameters, depth + 1) orelse break :func null;
                var out = try w.append(try w.literal("("), inputs);
                out = try w.append(out, try w.literal("->"));
                out = try w.append(out, output);
                break :func try w.append(out, try w.literal(")"));
            },
            .tuple => tuple: {
                const words = w.range(row.lhs) orelse break :tuple null;
                const items = try w.list(words, parameters, depth) orelse break :tuple null;
                break :tuple try w.append(try w.append(try w.literal("("), items), try w.literal(")"));
            },
            .record => try w.record(root, parameters, depth),
        };
    }
};
