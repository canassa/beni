//! Shared validation of private ordinary Interface term DAGs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Interface = @import("../resolve/Interface.zig");
/// Alias bodies are edges for cycle detection but have their own parameter
/// scope; their variable requirements do not flow into the caller's arguments.
pub fn child(types: *const Interface, node: u32, index: u32, include_body: bool) ?u32 {
    const term = types.terms.get(node);
    switch (term.tag) {
        .func => {
            const args = types.range(term.lhs);
            if (index < args.len) return args[index];
            return if (index == args.len) term.rhs else null;
        },
        .app, .alias => {
            const args = types.range(term.rhs);
            if (index < args.len) return args[index];
            if (include_body and term.tag == .alias and index == args.len) {
                if (term.lhs >= types.type_refs.len) return std.math.maxInt(u32);
                return types.type_refs[term.lhs].body.int();
            }
            return null;
        },
        .tuple => {
            const args = types.range(term.lhs);
            return if (index < args.len) args[index] else null;
        },
        .record => {
            const fields = types.range(term.lhs);
            if (index < fields.len / 2) return fields[@as(usize, index) * 2 + 1];
            return if (index == fields.len / 2) term.rhs else null;
        },
        .@"var", .unit, .empty_record, .err => return null,
    }
}

pub const no_projection = std.math.maxInt(u32);
pub const PathWork = struct { heads: usize = 0, steps: usize = 0, frames: usize = 0 };

pub fn verifyTypes(gpa: Allocator, types: *const Interface) Allocator.Error!bool {
    return verifyTypesWork(gpa, types, null);
}

pub fn verifyTypesWork(gpa: Allocator, types: *const Interface, work: ?*PathWork) Allocator.Error!bool {
    const count = types.terms.len;
    if (count == 0) return types.schemes.len == 0;
    const colors = try gpa.alloc(u8, count);
    defer gpa.free(colors);
    @memset(colors, 0);
    const required = try gpa.alloc(u64, count);
    defer gpa.free(required);
    @memset(required, 0);
    const heads = try gpa.alloc(u32, count);
    defer gpa.free(heads);
    @memset(heads, no_projection);
    const Frame = struct { node: u32, next: u32 = 0 };
    const stack = try gpa.alloc(Frame, count);
    defer gpa.free(stack);
    for (0..count) |start| {
        if (colors[start] != 0) continue;
        var depth: usize = 1;
        stack[0] = .{ .node = @intCast(start) };
        colors[start] = 1;
        while (depth != 0) {
            const frame = &stack[depth - 1];
            if (child(types, frame.node, frame.next, true)) |next| {
                frame.next += 1;
                if (next >= count or colors[next] == 1) return false;
                if (colors[next] == 2) continue;
                colors[next] = 1;
                stack[depth] = .{ .node = next };
                depth += 1;
                continue;
            }
            const term = types.terms.get(frame.node);
            if ((term.tag == .app or term.tag == .alias) and term.lhs >= types.type_refs.len) return false;
            var limit: u64 = if (term.tag == .@"var") @as(u64, term.lhs) + 1 else 0;
            var index: u32 = 0;
            while (child(types, frame.node, index, false)) |next| : (index += 1) {
                if (next >= count) return false;
                limit = @max(limit, required[next]);
            }
            switch (term.tag) {
                .@"var" => heads[frame.node] = term.lhs,
                .alias => {
                    const projection = heads[types.type_refs[term.lhs].body.int()];
                    if (projection != no_projection) {
                        const args = types.range(term.rhs);
                        if (projection >= args.len) return false;
                        heads[frame.node] = heads[args[projection]];
                    }
                },
                else => {},
            }
            if (work) |w| w.heads += 1;
            required[frame.node] = limit;
            colors[frame.node] = 2;
            depth -= 1;
        }
    }
    for (0..count) |node| {
        const term = types.terms.get(node);
        if (term.tag == .alias and required[types.type_refs[term.lhs].body.int()] > types.range(term.rhs).len) return false;
    }
    for (types.schemes) |scheme| {
        if (required[scheme.body.int()] > scheme.quantified_count) return false;
        var root_count: u64 = 1;
        for (0..scheme.quantified_count) |q| {
            root_count += types.quantified(scheme, @intCast(q)).constraints_len;
            if (root_count > @as(u64, types.extra.len) + 1) return false;
        }
        const roots = try gpa.alloc(u32, @intCast(root_count));
        defer gpa.free(roots);
        roots[0] = scheme.body.int();
        var root_index: usize = 1;
        for (0..scheme.quantified_count) |q| {
            const quantifier = types.quantified(scheme, @intCast(q));
            for (0..quantifier.constraints_len) |c| {
                const term = types.quantifiedConstraint(quantifier, @intCast(c)).type;
                if (term == .none or required[term.int()] > scheme.quantified_count) return false;
                roots[root_index] = term.int();
                root_index += 1;
            }
        }
        if (scheme.effects != Interface.no_terms) {
            const words = types.extra[scheme.effects..];
            const len = Interface.EffectBlock.measure(words) orelse return false;
            var sites = (Interface.EffectBlock{ .words = words[0..len] }).sites();
            while (sites.next()) |site| {
                if (site.root >= roots.len) return false;
                if (!try pathValid(gpa, types, heads, roots[site.root], site.steps, work)) return false;
            }
        }
    }
    return true;
}

/// Effect paths retain explicit alias-expansion steps. Frames substitute only
/// the alias body's parameters; ordinary scheme parameters remain scoped vars.
pub fn pathValid(gpa: Allocator, types: *const Interface, heads: []const u32, root: u32, steps: []const u32, work: ?*PathWork) Allocator.Error!bool {
    const AliasFrame = struct { args: u32, outer: ?u32 };
    var frames: std.ArrayList(AliasFrame) = .empty;
    defer frames.deinit(gpa);
    var frame: ?u32 = null;
    var node = root;
    var cursor: usize = 0;
    while (true) {
        if (work) |w| {
            w.steps += 1;
            w.frames = @max(w.frames, frames.items.len);
        }
        if (node >= types.terms.len) return false;
        const term = types.terms.get(node);
        if (term.tag == .@"var") if (frame) |at| {
            const bound = frames.items[at];
            const args = types.range(bound.args);
            if (term.lhs >= args.len) return false;
            node = args[term.lhs];
            frame = bound.outer;
            frames.shrinkRetainingCapacity(if (frame) |outer| @as(usize, outer) + 1 else 0);
            continue;
        };
        // resolved() compresses source alias chains; canonical rows retain
        // their names. Transparent extra layers do not change the path's type.
        if (term.tag == .alias and (cursor == steps.len or Interface.EffectBlock.stepKind(steps[cursor]) != 6)) {
            const projection = heads[types.type_refs[term.lhs].body.int()];
            if (projection != no_projection) {
                const args = types.range(term.rhs);
                if (projection >= args.len) return false;
                node = args[projection];
                continue;
            }
            try frames.append(gpa, .{ .args = term.rhs, .outer = frame });
            frame = @intCast(frames.items.len - 1);
            node = types.type_refs[term.lhs].body.int();
            continue;
        }
        if (cursor == steps.len) return term.tag == .func or term.tag == .app;
        const kind = Interface.EffectBlock.stepKind(steps[cursor]);
        const index = Interface.EffectBlock.stepIndex(steps[cursor]);
        var next: u32 = undefined;
        switch (kind) {
            0 => {
                if (term.tag != .func) return false;
                const args = types.range(term.lhs);
                if (index >= args.len) return false;
                next = args[index];
            },
            1 => {
                if (term.tag != .func or index != 0) return false;
                next = term.rhs;
            },
            2 => {
                if (term.tag != .app) return false;
                const args = types.range(term.rhs);
                if (index >= args.len) return false;
                next = args[index];
            },
            3 => {
                if (term.tag != .tuple) return false;
                const args = types.range(term.lhs);
                if (index >= args.len) return false;
                next = args[index];
            },
            4 => {
                if (term.tag != .record) return false;
                const fields = types.range(term.lhs);
                var found: ?u32 = null;
                var i: usize = 0;
                // SymbolIndex positions need not be unique: the writer appends
                // each occurrence. Compare the interned field names themselves.
                if (index >= types.symbols.len) return false;
                while (i < fields.len) : (i += 2) if (types.symbols[fields[i]] == types.symbols[index]) {
                    found = fields[i + 1];
                    break;
                };
                next = found orelse return false;
            },
            5 => {
                if (term.tag != .record or index != 0) return false;
                next = term.rhs;
            },
            6 => {
                if (term.tag != .alias or index != 0 or term.lhs >= types.type_refs.len) return false;
                try frames.append(gpa, .{ .args = term.rhs, .outer = frame });
                frame = @intCast(frames.items.len - 1);
                node = types.type_refs[term.lhs].body.int();
                cursor += 1;
                continue;
            },
            else => return false,
        }
        node = next;
        cursor += 1;
    }
}
