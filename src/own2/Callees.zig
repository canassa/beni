//! L12: what a call runs and what a function reference is
//! (`docs/design/ownership-v2.md` §2.11.1, §2.11.4), split from `Groups`:
//! the callee of a call or a method call, the code of a function used as a
//! value, the codes of a dispatch site's evidence, and the one reading of a
//! published contract as a call's (R-5.5.6). `mod` is a `Groups.Module`.
//!
//! Obligations kept here: O1 (a value this cannot name stays unknown code).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Rows = @import("Rows.zig");
const Prepass = @import("Prepass.zig");
const Walk = @import("Walk.zig");

const PlaceId = Ids.PlaceId;
const none: u32 = Ids.none_int;

/// What declaration `di` of module `m` publishes for a call of `arity`
/// arguments, or null. A value with no parameters publishes what its body
/// answers, which is never what a call of it does: a call of it runs the
/// lambda its body is, published as its called contract at `ε`, when it
/// has one of that arity (§2.11.1).
fn importedCall(mod: anytype, m: u32, di: u32, arity: u32) !?u32 {
    const c = (try mod.importedContract(m, di)) orelse return null;
    if (mod.contracts.head(c).arity == arity) return c;
    if (mod.contracts.head(c).arity != 0) return null;
    const l = mod.contracts.calledOf(c, Slots.root) orelse return null;
    return if (mod.contracts.head(l).arity == arity) l else null;
}

/// What the alias chain `t0` … `t` publishes for a call of `arity`
/// arguments: its end's, or a name's on the way (R-5.5.6). A private end
/// publishes nothing, and its alias publishes its contract.
fn publishedCall(mod: anytype, t0: [2]u32, t: [2]u32, arity: u32) !?u32 {
    if (t[0] != mod.in.module) if (try importedCall(mod, t[0], t[1], arity)) |c| return c;
    var n = t0;
    var hops: usize = 64;
    while (hops > 0 and !std.mem.eql(u32, &n, &t)) : (hops -= 1) {
        if (n[0] != mod.in.module) if (try importedCall(mod, n[0], n[1], arity)) |c| return c;
        n = Prepass.aliasStep(mod.in.birs, mod.in.provenance, n) orelse break;
    }
    return null;
}

/// The contract of the declaration alias chain `t0` … `t` names (another
/// module's, or this one's when worded) over a use's places, or null.
fn declContract(mod: anytype, t0: [2]u32, t: [2]u32, params: []const PlaceId, result: PlaceId) !?u32 {
    const owner = mod.in.birs[t[0]];
    const decl = owner.decls[t[1]];
    if (owner.ownSlotsV2(decl).len != 0) return try mod.wordedContract(t[0], t[1], params, result);
    // A `foreign` publishes nothing an importer applies: its words, or none (§2.10).
    if (decl.kind == .foreign_value) return try mod.pessimisticOf(@intCast(params.len), true);
    return publishedCall(mod, t0, t, @intCast(params.len));
}

/// The contract of a call of declaration `t` that has none: pessimistic,
/// and, for a value with no parameters, its result `host` (§2.11.1).
fn noContract(mod: anytype, t: [2]u32, arity: u32) !u32 {
    return mod.pessimisticOf(arity, mod.in.birs[t[0]].decls[t[1]].params == 0);
}

/// PROTOTYPE: the contract the arms of a value's body join to, when each arm is a capture-free
/// lambda, constructor, local function or a function declaration.
pub fn armContracts(mod: anytype, rs: u32, inst: u32, acc: *u32, n: *u32, arena: std.mem.Allocator, account: anytype) !bool {
    const bir = mod.in.bir;
    const tag = bir.instTag(@fromBackingInt(inst));
    const d = bir.instData(@fromBackingInt(inst));
    var c: u32 = none;
    switch (tag) {
        .branch => return armContracts(mod, rs, d.rhs, acc, n, arena, account),
        .let => {
            const stmts = bir.extraSlice(bir.subRange(@fromBackingInt(d.lhs)), Bir.Inst.Index);
            for (stmts) |s| if (bir.instTag(s) != .let_def) return false;
            return armContracts(mod, rs, d.rhs, acc, n, arena, account);
        },
        .case => {
            const branches = bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index);
            for (branches) |b| if (!try armContracts(mod, rs, b.int(), acc, n, arena, account)) return false;
            return true;
        },
        .lambda, .ctor, .ext_ctor, .local => {
            const code = if (tag == .local) (localFunctionAny(mod, rs, inst) orelse return false) else (mod.code_of_inst.get(.{inst}) orelse return false);
            const k = mod.codes.items[code];
            if (k.captures.len != 0) return false;
            c = k.contract;
        },
        .top, .ext_value => {
            const t = mod.aliasTarget(mod.declOf(inst) orelse return false);
            if (t[0] != mod.in.module) return false;
            if (t[1] >= mod.body_code.len or mod.body_code[t[1]] == none) return false;
            if (mod.in.bir.decls[t[1]].params == 0) {
                const lc = mod.lambdaBody(t[1]) orelse return false;
                c = mod.codes.items[lc].contract;
            } else c = mod.codes.items[mod.body_code[t[1]]].contract;
        },
        else => return false,
    }
    if (c == none) return false;
    acc.* = if (acc.* == none) c else try mod.contracts.join(mod.gpa, arena, account, &mod.slots, acc.*, c);
    n.* += 1;
    return true;
}

fn localFunctionAny(mod: anytype, base: u32, ref: u32) ?u32 {
    const bir = mod.in.bir;
    const l = bir.instData(@fromBackingInt(ref)).lhs;
    const b = bir.locals[base + l].inst.int();
    if (bir.instTag(@fromBackingInt(b)) != .let_def) return null;
    return mod.code_of_inst.get(.{b});
}

/// The local function a `.local` reference names, as its code.
fn localFunction(mod: anytype, ref: u32) ?u32 {
    const bir = mod.in.bir;
    if (bir.instTag(@fromBackingInt(ref)) != .local) return null;
    const l = bir.instData(@fromBackingInt(ref)).lhs;
    const binding = bir.locals[mod.cur_locals + l].inst.int();
    if (bir.instTag(@fromBackingInt(binding)) != .let_def) return null;
    return mod.code_of_inst.get(.{binding});
}

pub fn callee(mod: anytype, inst: u32, args: []const u32) !Walk.Callee {
    const M = @TypeOf(mod.*);
    const bir = mod.in.bir;
    var target: ?[2]u32 = null;
    var composed = false;
    if (bir.instTag(@fromBackingInt(inst)) == .call) {
        const head = bir.instData(@fromBackingInt(inst)).lhs;
        if (M.ctorOf(mod, head)) |c| return .{ .ctor = c };
        if (localFunction(mod, head)) |c| return .{ .code = c };
        // `(x.m) a`: the method runs at its own instruction, and what it answers is called here.
        if (bir.instTag(@fromBackingInt(head)) != .method_call) target = mod.declOf(head);
    } else if (mod.in.dispatch) |dt| if (dt.siteOf(@fromBackingInt(inst))) |site| if (site.callee.unwrap()) |ti| {
        switch (dt.term(ti)) {
            .top => |u| target = .{ mod.in.module, u.decl.int() },
            .ext => |u| if (mod.in.provenance.len > u.module.int()) if (mod.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| {
                target = .{ u.module.int(), d.int() };
            },
            // A record field of function type: its value, called (§2.11.5).
            .field => return .field,
            .param, .codec => {},
            else => composed = true,
        }
    };
    // Every argument and the result cross: nothing to track.
    var harmless = !Slots.holdsAny(&mod.places, try mod.places.rootPath(mod.gpa, try M.placeOfInst(mod, inst)));
    for (args) |x| harmless = harmless and !Slots.holdsAny(&mod.places, try mod.places.rootPath(mod.gpa, try M.placeOfInst(mod, x)));
    // A function value is never harmless: its code may write what its
    // closure holds, a label of the frame (§2.11.3).
    if (harmless and (target != null or composed)) return .harmless;
    var ps: std.ArrayList(PlaceId) = .empty;
    defer ps.deinit(mod.gpa);
    for (args) |x| try ps.append(mod.gpa, try M.placeOfInst(mod, x));
    const result = try M.placeOfInst(mod, inst);
    if (target) |t0| {
        const t = mod.aliasTarget(t0);
        if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none) {
            if (mod.in.bir.decls[t[1]].params == 0 and args.len != 0) {
                if (mod.lambdaBody(t[1])) |c| return .{ .code = c };
                if (mod.contracts.calledOf(mod.codes.items[mod.body_code[t[1]]].contract, Slots.root)) |l| if (mod.contracts.head(l).arity == args.len) return .{ .contract = l };
                return .{ .contract = try noContract(mod, t, @intCast(args.len)) };
            }
            // A container's comparison in core is its components'.
            if (!(mod.in.isCore(t[0]) and bir.instTag(@fromBackingInt(inst)) == .method_call and composedOrigin(bir, inst))) return .{ .code = mod.body_code[t[1]] };
        }
        if (try declContract(mod, t0, t, ps.items, result)) |c| return .{ .contract = c };
        if (bir.instTag(@fromBackingInt(inst)) == .method_call and mod.in.isCore(t[0]) and composedOrigin(bir, inst)) composed = true;
        if (!composed) return .{ .contract = try noContract(mod, t, @intCast(args.len)) };
    }
    if (composed) {
        var arena: std.heap.ArenaAllocator = .init(mod.gpa);
        defer arena.deinit();
        return .{ .contract = try Rows.comparison(mod.rowsEnv(arena.allocator()), @intCast(args.len)) };
    }
    if (bir.instTag(@fromBackingInt(inst)) == .method_call) return .{ .contract = try mod.pessimisticOf(@intCast(args.len), false) };
    return .value;
}

fn composedOrigin(bir: *const Bir, inst: u32) bool {
    const m = bir.extraData(@fromBackingInt(@intCast(bir.instData(@fromBackingInt(inst)).rhs)), Bir.MethodCall);
    return m.origin != .none;
}

/// A function reference used as a value: its code (§2.11.4).
pub fn funcRef(mod: anytype, inst: u32) !?u32 {
    const M = @TypeOf(mod.*);
    const bir = mod.in.bir;
    if (mod.code_of_inst.get(.{inst})) |c| return c;
    const tag = bir.instTag(@fromBackingInt(inst));
    var ps: std.ArrayList(PlaceId) = .empty;
    defer ps.deinit(mod.gpa);
    const result = (try mod.instFnPlaces(inst, &ps)) orelse return null;
    var arena: std.heap.ArenaAllocator = .init(mod.gpa);
    defer arena.deinit();
    var contract: u32 = none;
    switch (tag) {
        .ctor, .ext_ctor => {
            const c = M.ctorOf(mod, inst) orelse return null;
            var rp: std.ArrayList(Rows.Param) = .empty;
            defer rp.deinit(mod.gpa);
            var ranks: std.ArrayList(u32) = .empty;
            defer ranks.deinit(mod.gpa);
            for (ps.items, 0..) |p, n| {
                try rp.append(mod.gpa, .{ .place = p });
                if (M.ctorField(mod, inst, @intCast(n))) |r| try ranks.append(mod.gpa, r);
            }
            contract = try Rows.ctor(mod.rowsEnv(arena.allocator()), .{ .params = rp.items, .result = result }, c[0], ranks.items);
        },
        // A member answers what its `via` conversions answer (a top-level
        // list, say), and a constructor holds its arguments: neither is
        // fresh, so neither has a row here (§2.13.10).
        .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor => contract = try mod.pessimisticOf(@intCast(ps.items.len), false),
        .top, .ext_value => {
            const t0 = mod.declOf(inst) orelse return null;
            const t = mod.aliasTarget(t0);
            if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none and (ps.items.len == 0 or mod.in.bir.decls[t[1]].params != 0)) {
                try mod.code_of_inst.put(mod.gpa, .{inst}, mod.body_code[t[1]]);
                return mod.body_code[t[1]];
            }
            if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none) if (mod.lambdaBody(t[1])) |c| return c;
            if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none) if (mod.contracts.calledOf(mod.codes.items[mod.body_code[t[1]]].contract, Slots.root)) |l| {
                if (mod.contracts.head(l).arity == ps.items.len) contract = l;
            };
            if (contract == none) contract = (try declContract(mod, t0, t, ps.items, result)) orelse try noContract(mod, t, @intCast(ps.items.len));
        },
        else => return null,
    }
    const id: u32 = @intCast(mod.codes.items.len);
    const pstart: u32 = @intCast(mod.code_places.items.len);
    try mod.code_places.appendSlice(mod.gpa, ps.items);
    try mod.codes.append(mod.gpa, .{ .kind = .ref, .inst = inst, .params = .{ .start = pstart, .len = @intCast(ps.items.len) }, .own = @intCast(ps.items.len), .result = result, .contract = contract });
    try mod.code_of_inst.put(mod.gpa, .{inst}, id);
    return id;
}

/// The codes of the declarations a dispatch site at `inst` passes as
/// evidence, every term however deep, each once (§2.11.4: a function
/// value handed to code the checker does not see).
pub fn evidenceCodes(mod: anytype, inst: u32, out: *std.ArrayList(u32)) !void {
    const dt = mod.in.dispatch orelse return;
    const site = dt.siteOf(@fromBackingInt(inst)) orelse return;
    var todo: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer todo.deinit(mod.gpa);
    try todo.appendSlice(mod.gpa, dt.argsAt(site.evidence));
    var seen: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer seen.deinit(mod.gpa);
    while (todo.pop()) |ti| {
        if (std.mem.indexOfScalar(Dispatch.TermIndex, seen.items, ti) != null) continue;
        try seen.append(mod.gpa, ti);
        try todo.appendSlice(mod.gpa, dt.argsOfTerm(ti));
        const t0: [2]u32 = switch (dt.term(ti)) {
            .top => |u| .{ mod.in.module, u.decl.int() },
            .ext => |u| if (mod.in.provenance.len > u.module.int()) if (mod.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| .{ u.module.int(), d.int() } else continue else continue,
            else => continue,
        };
        // A type's `eq` or `compare` writes nothing in place (R-5.13.1
        // refuses its writes), and a comparison composes it (§2.13.13).
        const name = mod.in.birs[t0[0]].symbol(mod.in.birs[t0[0]].decls[t0[1]].name);
        if (name == InternPool.WellKnown.eq.symbol() or name == InternPool.WellKnown.compare.symbol()) continue;
        const t = mod.aliasTarget(t0);
        if (t[0] == mod.in.module) {
            if (t[1] >= mod.body_code.len or mod.body_code[t[1]] == none) continue;
            const c = if (mod.in.bir.decls[t[1]].params != 0) mod.body_code[t[1]] else mod.lambdaBody(t[1]) orelse continue;
            if (std.mem.indexOfScalar(u32, out.items, c) == null) try out.append(mod.gpa, c);
            continue;
        }
        // Another module's: its published contract (a worded row writes
        // only where its own call site is authorised, never through a
        // function value).
        const owner = mod.in.birs[t[0]];
        if (owner.ownSlotsV2(owner.decls[t[1]]).len != 0) continue;
        const got = try mod.evidence_code.getOrPut(mod.gpa, .{ t[0], t[1] });
        if (!got.found_existing) {
            const contract = (try publishedCall(mod, t0, t, owner.decls[t[1]].params)) orelse none;
            got.value_ptr.* = @intCast(mod.codes.items.len);
            try mod.codes.append(mod.gpa, .{ .kind = .ref, .inst = inst, .own = owner.decls[t[1]].params, .contract = contract });
        }
        if (std.mem.indexOfScalar(u32, out.items, got.value_ptr.*) == null) try out.append(mod.gpa, got.value_ptr.*);
    }
}
