//! Read one interface type-term root with caller-supplied quantifiers.

const Allocator = @import("std").mem.Allocator;
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Var = TypeStore.Var;

pub fn instantiateRoot(iface: *const Interface, type_ids: []const TypeStore.TypeId, store: *TypeStore, root: Interface.TermIndex, args: []const Var, rank: u32, scratch: Allocator) Allocator.Error!Var {
    const memo = try scratch.alloc(Var.Optional, iface.terms.len);
    defer scratch.free(memo);
    @memset(memo, .none);
    var r: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .args = args, .memo = memo };
    return r.read(root);
}

const Reader = struct {
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    rank: u32,
    scratch: Allocator,
    args: []const Var,
    memo: []Var.Optional,
    depth: u32 = 0,

    fn read(r: *Reader, index: Interface.TermIndex) Allocator.Error!Var {
        if (index == .none or index.int() >= r.iface.terms.len) return r.store.freshErr(r.rank);
        r.depth += 1;
        defer r.depth -= 1;
        if (r.depth > 512) return r.store.freshErr(r.rank);
        if (r.memo[index.int()].unwrap()) |v| return v;
        const t = r.iface.term(index);
        const v = switch (t.tag) {
            .err => try r.store.freshErr(r.rank),
            .@"var" => if (t.lhs < r.args.len) r.args[t.lhs] else try r.store.freshErr(r.rank),
            .unit => try r.store.fresh(.{ .structure = .unit }, r.rank),
            .empty_record => try r.store.fresh(.{ .structure = .empty_record }, r.rank),
            .func => blk: {
                const xs = try r.range(t.lhs);
                defer r.scratch.free(xs);
                break :blk try r.store.fresh(.{ .structure = .{ .func = .{ .params = try r.store.addVars(xs), .result = try r.read(@enumFromInt(t.rhs)) } } }, r.rank);
            },
            .app => blk: {
                const xs = try r.range(t.rhs);
                defer r.scratch.free(xs);
                break :blk try r.store.fresh(.{ .structure = .{ .app = .{ .type = r.typeId(t.lhs), .args = try r.store.addVars(xs) } } }, r.rank);
            },
            .tuple => blk: {
                const xs = try r.range(t.lhs);
                defer r.scratch.free(xs);
                break :blk try r.store.fresh(.{ .structure = .{ .tuple = try r.store.addVars(xs) } }, r.rank);
            },
            .record => blk: {
                const words = r.iface.range(t.lhs);
                const fields = try r.scratch.alloc(TypeStore.Field, words.len / 2);
                defer r.scratch.free(fields);
                for (fields, 0..) |*f, i| f.* = .{ .name = r.iface.symbol(@enumFromInt(words[i * 2])), .value = try r.read(@enumFromInt(words[i * 2 + 1])) };
                break :blk try r.store.fresh(.{ .structure = .{ .record = .{ .fields = try r.store.addFields(fields), .ext = try r.read(@enumFromInt(t.rhs)) } } }, r.rank);
            },
            .alias => blk: {
                const words = r.iface.range(t.rhs);
                if (words.len == 0) break :blk try r.store.freshErr(r.rank);
                const xs = try r.scratch.alloc(Var, words.len - 1);
                defer r.scratch.free(xs);
                for (xs, 0..) |*x, i| x.* = try r.read(@enumFromInt(words[i]));
                break :blk try r.store.fresh(.{ .alias = .{ .type = r.typeId(t.lhs), .args = try r.store.addVars(xs), .actual = try r.read(@enumFromInt(words[words.len - 1])) } }, r.rank);
            },
        };
        r.memo[index.int()] = v.toOptional();
        return v;
    }
    fn range(r: *Reader, at: u32) Allocator.Error![]Var {
        const words = r.iface.range(at);
        const out = try r.scratch.alloc(Var, words.len);
        for (out, words) |*v, w| v.* = try r.read(@enumFromInt(w));
        return out;
    }
    fn typeId(r: *Reader, at: u32) TypeStore.TypeId {
        return if (at < r.type_ids.len) r.type_ids[at] else .none;
    }
};
