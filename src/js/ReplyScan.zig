//! Iterative reply-mode Wire interpreter, emitted only for a nonempty scan.
//! Keys and constructor layouts are supplied by Lower, after boundary encoding.
const std = @import("std");
const Ir = @import("JsIr.zig");
const N = Ir.Node.Index;
const List = std.ArrayList(N);
const E = std.mem.Allocator.Error;

// ownership pin begin: replyIds
pub fn emit(l: anytype, value: N, root: N, plans: N, brand: N, keys: N, is_view: N, p: u32) E!N {
    var g: Generator(@TypeOf(l.*)) = .{ .l = l, .p = p };
    return g.emit(value, root, plans, brand, keys, is_view);
}

fn Generator(comptime L: type) type {
    return struct {
        l: *L,
        p: u32,
        const G = @This();
        fn s(g: *G, text: []const u8) E!@import("../InternPool.zig").Symbol {
            return g.l.interner.getOrPut(g.l.gpa, text);
        }
        fn lit(g: *G, text: []const u8) E!N {
            return g.l.stringNode(text, g.p);
        }
        fn num(g: *G, text: []const u8) E!N {
            return g.l.numberNode(text, g.p);
        }
        fn at(g: *G, obj: N, key: N) E!N {
            return g.l.add(.index_get, g.p, obj.int(), key.int());
        }
        fn slot(g: *G, obj: N, i: u32) E!N {
            return g.at(obj, try g.num(try std.fmt.allocPrint(g.l.scratch, "{d}", .{i})));
        }
        fn field(g: *G, obj: N, text: []const u8) E!N {
            return g.l.member(obj, try g.s(text), g.p);
        }
        fn global(g: *G, text: []const u8) E!N {
            return g.field(try g.l.add(.global_this, g.p, 0, 0), text);
        }
        fn bin(g: *G, op: Ir.BinaryOp, a: N, b: N) E!N {
            return g.l.binary(op, a, b, g.p);
        }
        fn not(g: *G, a: N) E!N {
            return g.l.unary(.not, a, g.p);
        }
        fn eq(g: *G, a: N, b: N) E!N {
            return g.bin(.strict_eq, a, b);
        }
        fn call(g: *G, f: N, args: []const N) E!N {
            return g.l.call(f, args, g.p);
        }
        fn method(g: *G, obj: N, name: []const u8, args: []const N) E!N {
            return g.call(try g.field(obj, name), args);
        }
        fn expr(g: *G, out: *List, v: N) E!void {
            try out.append(g.l.scratch, try g.l.add(.expr_stmt, g.p, v.int(), 0));
        }
        fn assign(g: *G, out: *List, a: N, b: N) E!void {
            try out.append(g.l.scratch, try g.l.add(.assign_stmt, g.p, a.int(), b.int()));
        }
        fn bind(g: *G, out: *List, hint: []const u8, v: N, mutable: bool) E!N {
            const name = try g.l.fresh(try g.s(hint));
            try out.append(g.l.scratch, try g.l.add(if (mutable) .let_decl else .const_decl, g.p, @backingInt(name), v.int()));
            return g.l.ident(name, g.p);
        }
        fn flow(g: *G, tag: Ir.Node.Tag) E!N {
            return g.l.add(tag, g.p, @backingInt(Ir.NameIndex.none), 0);
        }
        fn iff(g: *G, out: *List, condition: N, body: []const N) E!void {
            const r = try g.l.b.addRange(body);
            const empty = try g.l.b.addRange(&.{});
            const record = try g.l.b.addRecord(Ir.If{ .then_start = r.start, .then_end = r.end, .else_start = empty.start, .else_end = empty.end });
            try out.append(g.l.scratch, try g.l.add(.if_stmt, g.p, condition.int(), @backingInt(record)));
        }
        fn loop(g: *G, out: *List, body: []const N) E!void {
            const r = try g.l.b.addRecord(try g.l.b.addRange(body));
            try out.append(g.l.scratch, try g.l.add(.while_true, g.p, @backingInt(Ir.NameIndex.none), @backingInt(r)));
        }
        fn array(g: *G, items: []const N) E!N {
            return g.l.arrayNode(items, g.p);
        }
        fn new(g: *G, name: []const u8) E!N {
            const ctor = try g.global(name);
            return g.l.add(.new_call, g.p, ctor.int(), @backingInt(try g.l.b.addRecord(try g.l.b.addRange(&.{}))));
        }
        fn push(g: *G, out: *List, stack: N, v: N, node: N) E!void {
            try g.expr(out, try g.method(stack, "push", &.{try g.array(&.{ v, node })}));
        }
        fn dec(g: *G, out: *List, i: N) E!void {
            try g.assign(out, i, try g.bin(.sub, i, try g.num("1")));
        }
        fn emit(g: *G, value: N, root: N, input_plans: N, brand: N, input_keys: N, is_view: N) E!N {
            var body: List = .empty;
            const plans = try g.bind(&body, "$replyPlans", input_plans, false);
            const keys = try g.bind(&body, "$replyBrandKeys", input_keys, false);
            const result = try g.bind(&body, "$replyIds", try g.array(&.{}), false);
            const stack = try g.bind(&body, "$replyPending", try g.array(&.{try g.array(&.{ value, root })}), false);
            const seen = try g.bind(&body, "$replySeen", try g.new("Map"), false);
            var walk: List = .empty;
            const cont = try g.flow(.continue_stmt);
            const stop = try g.flow(.break_stmt);
            try g.iff(&walk, try g.not(try g.field(stack, "length")), &.{stop});
            const item = try g.bind(&walk, "$replyItem", try g.method(stack, "pop", &.{}), false);
            const v = try g.bind(&walk, "$replyValue", try g.slot(item, 0), true);
            const n = try g.bind(&walk, "$replyNode", try g.slot(item, 1), false);
            const null_v = try g.l.nullNode(g.p);
            try g.iff(&walk, try g.bin(.logical_or, try g.eq(v, null_v), try g.bin(.strict_ne, try g.l.unary(.type_of, v, g.p), try g.lit("object"))), &.{cont});
            const kind = try g.bind(&walk, "$replyKind", try g.num("5"), true);
            const edges = try g.bind(&walk, "$replyEdges", try g.array(&.{}), true);
            var planned: List = .empty;
            const plan = try g.bind(&planned, "$replyPlan", try g.at(plans, n), false);
            try g.iff(&planned, try g.eq(plan, try g.num("0")), &.{cont});
            try g.assign(&planned, kind, try g.slot(plan, 0));
            try g.assign(&planned, edges, try g.slot(plan, 1));
            try g.iff(&walk, try g.bin(.ge, n, try g.num("0")), planned.items);
            // A statically nominal Reply uses the selected boxing, then stops.
            var unwrap: List = .empty;
            try g.assign(&unwrap, v, try g.field(v, "a"));
            var reply: List = .empty;
            try g.iff(&reply, try g.not(edges), unwrap.items);
            try g.iff(&walk, try g.eq(kind, try g.num("7")), reply.items);
            const visited = try g.bind(&walk, "$replyVisited", try g.method(seen, "get", &.{v}), true);
            var first: List = .empty;
            try g.assign(&first, visited, try g.new("Set"));
            try g.expr(&first, try g.method(seen, "set", &.{ v, visited }));
            try g.iff(&walk, try g.not(visited), first.items);
            try g.iff(&walk, try g.method(visited, "has", &.{n}), &.{cont});
            try g.expr(&walk, try g.method(visited, "add", &.{n}));
            const is_array = try g.bind(&walk, "$replyArray", try g.method(try g.global("Array"), "isArray", &.{v}), false);
            const view = try g.bind(&walk, "$replyView", try g.call(is_view, &.{v}), false);
            const trie = try g.bind(&walk, "$replyTrie", try g.eq(try g.l.unary(.type_of, try g.field(v, "$plain"), g.p), try g.lit("function")), false);
            const proto = try g.bind(&walk, "$replyPrototype", try g.method(try g.global("Object"), "getPrototypeOf", &.{v}), false);
            const plain = try g.bin(.logical_or, try g.eq(proto, null_v), try g.eq(proto, try g.field(try g.global("Object"), "prototype")));
            const plain_array = try g.bin(.logical_and, is_array, try g.eq(proto, try g.field(try g.global("Array"), "prototype")));
            try g.iff(&walk, try g.not(try g.bin(.logical_or, plain_array, try g.bin(.logical_or, view, try g.bin(.logical_or, trie, plain)))), &.{cont});
            var branded: List = .empty;
            var local: List = .empty;
            try g.expr(&local, try g.method(result, "push", &.{try g.at(v, try g.slot(keys, 1))}));
            try g.iff(&branded, try g.eq(try g.at(v, try g.slot(keys, 2)), try g.l.add(.true_lit, g.p, 0, 0)), local.items);
            try branded.append(g.l.scratch, cont);
            const marker = try g.bind(&walk, "$replyMarker", try g.method(try g.global("Object"), "getOwnPropertyDescriptor", &.{ v, try g.slot(keys, 0) }), false);
            try g.iff(&walk, try g.bin(.logical_and, marker, try g.eq(try g.field(marker, "value"), brand)), branded.items);
            try g.iff(&walk, try g.eq(kind, try g.num("7")), &.{cont});
            // A release-unboxed one-field constructor is an alias of its child.
            var alias: List = .empty;
            try g.push(&alias, stack, v, edges);
            try alias.append(g.l.scratch, cont);
            try g.iff(&walk, try g.eq(kind, try g.num("9")), alias.items);
            var ref_body: List = .empty;
            try g.push(&ref_body, stack, try g.field(v, "v"), try g.slot(try g.slot(edges, 0), 1));
            try ref_body.append(g.l.scratch, cont);
            try g.iff(&walk, try g.eq(kind, try g.num("8")), ref_body.items);
            // Known lists and dynamically recognised arrays/views visit active elements.
            var items: List = .empty;
            const base = try g.bind(&items, "$replyBase", v, true);
            const offset = try g.bind(&items, "$replyOffset", try g.num("0"), true);
            var sliced: List = .empty;
            try g.assign(&sliced, base, try g.field(v, "b"));
            try g.assign(&sliced, offset, try g.field(v, "o"));
            try g.iff(&items, view, sliced.items);
            var materialized: List = .empty;
            try g.assign(&materialized, base, try g.method(v, "$plain", &.{}));
            try g.iff(&items, trie, materialized.items);
            const child = try g.bind(&items, "$replyChild", try g.num("-1"), true);
            var typed_list: List = .empty;
            try g.assign(&typed_list, child, try g.slot(try g.slot(edges, 0), 1));
            try g.iff(&items, try g.eq(kind, try g.num("1")), typed_list.items);
            const i = try g.bind(&items, "$replyIndex", try g.field(v, "length"), true);
            var elements: List = .empty;
            try g.iff(&elements, try g.eq(i, try g.num("0")), &.{stop});
            try g.dec(&elements, i);
            try g.push(&elements, stack, try g.at(base, try g.bin(.add, offset, i)), child);
            try g.loop(&items, elements.items);
            try items.append(g.l.scratch, cont);
            try g.iff(&walk, try g.bin(.logical_or, try g.eq(kind, try g.num("1")), try g.bin(.logical_or, is_array, try g.bin(.logical_or, view, trie))), items.items);
            // Tagged unions select just their active payload tuple.
            var tagged: List = .empty;
            const ti = try g.bind(&tagged, "$replyVariant", try g.field(edges, "length"), true);
            var variants: List = .empty;
            try g.iff(&variants, try g.eq(ti, try g.num("0")), &.{stop});
            try g.dec(&variants, ti);
            const edge = try g.bind(&variants, "$replyEdge", try g.at(edges, ti), false);
            var active: List = .empty;
            try g.push(&active, stack, v, try g.slot(edge, 1));
            try active.append(g.l.scratch, stop);
            try g.iff(&variants, try g.eq(try g.field(v, "$"), try g.slot(edge, 0)), active.items);
            try g.loop(&tagged, variants.items);
            try tagged.append(g.l.scratch, cont);
            try g.iff(&walk, try g.eq(kind, try g.num("4")), tagged.items);
            // Closed products use only planned fields. Generic/open rows use own keys,
            // replacing the dynamic default with known field plans where available.
            var closed: List = .empty;
            const ci = try g.bind(&closed, "$replyField", try g.field(edges, "length"), true);
            var fields: List = .empty;
            try g.iff(&fields, try g.eq(ci, try g.num("0")), &.{stop});
            try g.dec(&fields, ci);
            const ce = try g.bind(&fields, "$replyFieldPlan", try g.at(edges, ci), false);
            try g.push(&fields, stack, try g.at(v, try g.slot(ce, 0)), try g.slot(ce, 1));
            try g.loop(&closed, fields.items);
            try closed.append(g.l.scratch, cont);
            try g.iff(&walk, try g.bin(.logical_or, try g.eq(kind, try g.num("2")), try g.eq(kind, try g.num("3"))), closed.items);
            const names = try g.bind(&walk, "$replyKeys", try g.method(try g.global("Object"), "keys", &.{v}), false);
            const ki = try g.bind(&walk, "$replyKeyIndex", try g.field(names, "length"), true);
            var unknown: List = .empty;
            try g.iff(&unknown, try g.eq(ki, try g.num("0")), &.{stop});
            try g.dec(&unknown, ki);
            const key = try g.bind(&unknown, "$replyKey", try g.at(names, ki), false);
            const kn = try g.bind(&unknown, "$replyKeyNode", try g.num("-1"), true);
            const ei = try g.bind(&unknown, "$replyKnown", try g.field(edges, "length"), true);
            var known: List = .empty;
            try g.iff(&known, try g.eq(ei, try g.num("0")), &.{stop});
            try g.dec(&known, ei);
            const ke = try g.bind(&known, "$replyKnownPlan", try g.at(edges, ei), false);
            var found: List = .empty;
            try g.assign(&found, kn, try g.slot(ke, 1));
            try found.append(g.l.scratch, stop);
            try g.iff(&known, try g.eq(key, try g.slot(ke, 0)), found.items);
            try g.loop(&unknown, known.items);
            const descriptor = try g.bind(&unknown, "$replyDescriptor", try g.method(try g.global("Object"), "getOwnPropertyDescriptor", &.{ v, key }), false);
            var data: List = .empty;
            try g.push(&data, stack, try g.field(descriptor, "value"), kn);
            try g.iff(&unknown, try g.method(try g.global("Object"), "hasOwn", &.{ descriptor, try g.lit("value") }), data.items);
            try g.loop(&walk, unknown.items);
            try g.loop(&body, walk.items);
            try body.append(g.l.scratch, try g.l.returnStmt(result, g.p));
            // An IIFE keeps all scanner state local to this evaluation.
            return g.call(try g.l.arrowOf(&.{}, body.items, g.p), &.{});
        }
    };
}

// ownership pin end: replyIds
