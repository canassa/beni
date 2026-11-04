//! Final release reachability's allocation-only proof (backend.md §9).
//! Mutable factories stay impure in the checker. Only an unread result may
//! disappear, after every executed argument/body operation is proven inert.
const JsIr = @import("JsIr.zig");
const Opt = @import("Opt.zig");
const Spec = @import("Spec.zig");

const Index = JsIr.Node.Index;
const none = Spec.none;

pub const Module = struct {
    ir: *const JsIr,
    plan: *const Opt.Plan,
    globals: []const u32,
};

pub const Function = struct { module: u32, node: Index };

pub const Proof = struct {
    modules: []const Module,
    functions: []const ?Function,

    pub fn inert(p: Proof, module: u32, node: Index) bool {
        var budget: u32 = 4096;
        return p.value(module, node, 0, &budget);
    }

    fn value(p: Proof, module: u32, node: Index, depth: u32, budget: *u32) bool {
        if (budget.* == 0 or depth >= 32) return false;
        budget.* -= 1;
        const m = p.modules[module];
        if (m.plan.replacement(node)) |replacement| return p.value(module, replacement, depth + 1, budget);
        const d = m.ir.data(node);
        switch (m.ir.tag(node)) {
            // Inspect every executed operand after Opt substitutions. An
            // inert-looking name can now stand for an effectful call.
            .ident, .field_name, .number, .string, .template_chunk, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .import_meta_url, .worker_path, .this_lit, .arrow => return true,
            .member => return m.ir.isFieldRead(node) and p.value(module, @fromBackingInt(@intCast(d.lhs)), depth + 1, budget),
            .object => {
                for (m.ir.extraSlice(JsIr.inlineRange(d), Index)) |prop| {
                    if (m.ir.tag(prop) != .property) return false;
                    if (!p.value(module, @fromBackingInt(@intCast(m.ir.data(prop).rhs)), depth + 1, budget)) return false;
                }
                return true;
            },
            .array, .template => {
                for (m.ir.extraSlice(JsIr.inlineRange(d), Index)) |part| {
                    if (!p.value(module, part, depth + 1, budget)) return false;
                }
                return true;
            },
            .call => {
                const callee: Index = @fromBackingInt(@intCast(d.lhs));
                const callee_function = p.target(module, callee, depth + 1) orelse return false;
                for (m.ir.extraSlice(m.ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |arg| {
                    if (!p.value(module, arg, depth + 1, budget)) return false;
                }
                return p.body(callee_function, depth + 1, budget);
            },
            else => return false,
        }
    }

    fn target(p: Proof, module: u32, node: Index, depth: u32) ?Function {
        if (depth >= 32) return null;
        const m = p.modules[module];
        if (m.plan.replacement(node)) |replacement| return p.target(module, replacement, depth + 1);
        const d = m.ir.data(node);
        return switch (m.ir.tag(node)) {
            .arrow => if (d.rhs == JsIr.Node.arrow_plain) .{ .module = module, .node = node } else null,
            .ident => blk: {
                const name: JsIr.NameIndex = @fromBackingInt(@intCast(d.lhs));
                const n = name.unwrap() orelse break :blk null;
                if (n >= m.globals.len) break :blk null;
                const g = m.globals[n];
                break :blk if (g == none or g >= p.functions.len) null else p.functions[g];
            },
            else => null,
        };
    }

    fn body(p: Proof, function: Function, depth: u32, budget: *u32) bool {
        if (budget.* == 0 or depth >= 32) return false;
        budget.* -= 1;
        const m = p.modules[function.module];
        const d = m.ir.data(function.node);
        const record: JsIr.ExtraIndex = switch (m.ir.tag(function.node)) {
            .func_decl => @fromBackingInt(@intCast(d.rhs)),
            .arrow => @fromBackingInt(@intCast(d.lhs)),
            else => return false,
        };
        const statements = m.ir.extraSlice(m.ir.extraData(record, JsIr.Func).body(), Index);
        for (statements) |stmt| {
            if (m.plan.isDropped(stmt)) continue;
            const data = m.ir.data(stmt);
            switch (m.ir.tag(stmt)) {
                .const_decl => {
                    if (!p.value(function.module, @fromBackingInt(@intCast(data.rhs)), depth + 1, budget)) return false;
                },
                .return_stmt => {
                    const result: JsIr.Node.OptionalIndex = @fromBackingInt(@intCast(data.lhs));
                    return if (result.unwrap()) |v| p.value(function.module, v, depth + 1, budget) else true;
                },
                else => return false,
            }
        }
        return true;
    }
};
