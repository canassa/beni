//! Actual ordinary checked-source boundary of the private realm builder.
const std = @import("std");
const Session = @import("../Session.zig");
const Build = @import("RealmBuild.zig");
const Realms = @import("Realms.zig");
const Graph = @import("../resolve/Graph.zig");
const testing = std.testing;
const gpa = testing.allocator;
const Fixture = struct {
    session: Session,
    diagnostics: std.Io.Writer.Allocating,
    fn init(source: [:0]const u8) !Fixture {
        return initWith(source, false);
    }
    fn initWith(source: [:0]const u8, generated_native: bool) !Fixture {
        return initMode(source, if (generated_native) .generated else .none);
    }
    fn initMode(source: [:0]const u8, native_mode: enum { none, generated, ordinary }) !Fixture {
        var f: Fixture = .{ .session = try Session.init(gpa, testing.io, .{ .jobs = 1, .native_realms = true, .diagnostics = .json }), .diagnostics = .init(gpa) };
        errdefer f.deinit();
        if (native_mode != .none) {
            const native = @import("../native/Source.zig");
            try f.session.store.addEmbedded(gpa, "core/String.beni", 5, .core, "pub equatable foreign type String\n");
            // The hermetic builder boundary supplies the canonical generated
            // module, then uses the full ordinary checker and registry install.
            // The full packaged CLI source-builder route is tested separately.
            if (native_mode == .generated) {
                try f.session.store.addGenerated(gpa, "core/Browser/Host/TextEncoder.beni", 5, .core, native.source, .text_encoder_v1);
            } else {
                try f.session.store.addEmbedded(gpa, "core/Browser/Host/TextEncoder.beni", 5, .core, native.source);
            }
        }
        try f.session.store.addEmbedded(gpa, "Helper.beni", 0, .app,
            \\pub type Marker = Marker
            \\
            \\
            \\pub work : ⊤ → ⊤
            \\work x = x
            \\
        );
        try f.session.store.addEmbedded(gpa, "Main.beni", 0, .app, source);
        const result = try f.session.run(&.{}, Session.check_phases, &f.diagnostics.writer);
        if (result.errors != 0) std.debug.print("{s}\n", .{f.diagnostics.written()});
        try testing.expectEqual(@as(u32, 0), result.errors);
        try testing.expectEqualStrings("", f.diagnostics.written());
        return f;
    }
    fn deinit(f: *Fixture) void {
        f.session.deinit();
        f.diagnostics.deinit();
    }
    fn input(f: *const Fixture) Build.Input {
        return .{ .graph = &f.session.graph, .artifacts = &f.session.artifacts, .interfaces = f.session.resolution.interfaces, .provenance = f.session.resolution.provenance, .dispatch = f.session.checked.dispatch };
    }
    fn q(f: *const Fixture, module: []const u8, name: []const u8) !Build.QualifiedDecl {
        const m = f.session.graph.lookup(.app, f.session.interner.find(module).?) orelse return error.MissingModule;
        const bir = f.session.artifacts.bir(f.session.graph.moduleFile(m));
        for (bir.decls, 0..) |d, i| if (std.mem.eql(u8, name, f.session.interner.slice(bir.symbol(d.name)))) return .{ .module = m, .declaration = @intCast(i) };
        return error.MissingDeclaration;
    }
    fn exec(f: *const Fixture, out: *const Build.Output, name: []const u8) !Build.ExecId {
        const id = try out.callableAt(try f.q("Main", name));
        try testing.expect(id != .none);
        return id;
    }
};
fn privateSeed(out: *Build.Output, exec: Build.ExecId, mask: u8) !void {
    try out.seeds.append(gpa, .{ .target = exec, .allowed = mask, .binding_digest = @splat(mask), .origin = .private_test });
}
fn fact(result: *const Realms.Result, id: Build.ExecId) Realms.Fact {
    return result.facts.get(@backingInt(id));
}

test "realm builder actual aliases imported provenance and same signature calls stay independent" {
    var f = try Fixture.init(
        \\import Helper
        \\
        \\
        \\pub left : ⊤ → ⊤
        \\left x = x
        \\
        \\
        \\pub right : ⊤ → ⊤
        \\right x = x
        \\
        \\
        \\forwarding = left
        \\
        \\
        \\pub run : ⊤ → ⊤
        \\run x = forwarding x
        \\
        \\
        \\pub imported : ⊤ → ⊤
        \\imported x = Helper.work x
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    const left = try f.exec(&out, "left");
    const right = try f.exec(&out, "right");
    try testing.expect(left != right);
    try testing.expectEqual(left, try out.callableAt(try f.q("Main", "forwarding")));
    try testing.expect((try out.initializerOf(try f.q("Main", "forwarding"))) != .none);
    try testing.expectEqual(Build.ExecId.none, try out.initializerOf(try f.q("Main", "left")));
    const imported = try out.callableAt(try f.q("Helper", "work"));
    try testing.expectEqual(@as(u32, 1), (try f.q("Helper", "work")).declaration);
    try privateSeed(&out, left, 1);
    try privateSeed(&out, right, 2);
    try privateSeed(&out, imported, 4);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 1 }, fact(&result, try f.exec(&out, "run")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 2, .seed = 1 }, fact(&result, right));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 4 }, fact(&result, try f.exec(&out, "imported")));
    try testing.expectEqual(@as(u64, 2), out.work.calls);
    try testing.expectEqual(@as(u64, 2), out.work.edges);
    try testing.expectEqual(@as(u64, 0), out.work.residuals);
    try testing.expectEqual(out.work.ports, out.work.value.ports);
}

test "realm builder known returned functions separate initializer execution and formal captures" {
    var f = try Fixture.init(
        \\pub leaf : ⊤ → ⊤
        \\leaf x = x
        \\
        \\
        \\pub make : ⊤ → (⊤ → ⊤)
        \\make x = λy → leaf y
        \\
        \\
        \\pub returned : ⊤ → ⊤
        \\returned x = (make x) x
        \\
        \\
        \\pub retained : ⊤ → ⊤
        \\retained = make ⊤
        \\
        \\
        \\pub captured : (⊤ → ⊤) → (⊤ → ⊤)
        \\captured callback = λx → callback x
        \\
        \\
        \\pub useCaptured : (⊤ → ⊤) → ⊤
        \\useCaptured callback = (captured callback) ⊤
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    const leaf = try f.exec(&out, "leaf");
    const retained = try f.exec(&out, "retained");
    const initializer = try out.initializerOf(try f.q("Main", "retained"));
    try testing.expect(initializer != .none and initializer != retained);
    try privateSeed(&out, leaf, 2);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 2 }, fact(&result, try f.exec(&out, "returned")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31 }, fact(&result, initializer));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 2 }, fact(&result, retained));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31, .incomplete = true }, fact(&result, try f.exec(&out, "useCaptured")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31 }, fact(&result, try f.exec(&out, "captured")));
}

test "realm builder closed field selection keeps siblings separate but retains strict initializers" {
    var f = try Fixture.init(
        \\pub left : ⊤ → ⊤
        \\left x = x
        \\
        \\
        \\pub right : ⊤ → ⊤
        \\right x = x
        \\
        \\
        \\pair = { good = left, bad = right }
        \\
        \\
        \\pub selected : ⊤ → ⊤
        \\selected x = pair.good x
        \\
        \\
        \\pub strict : ⊤ → ⊤
        \\strict x = { good = left, bad = right x }.good x
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    try privateSeed(&out, try f.exec(&out, "left"), 1);
    try privateSeed(&out, try f.exec(&out, "right"), 2);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 1 }, fact(&result, try f.exec(&out, "selected")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 0 }, fact(&result, try f.exec(&out, "strict")));
    try testing.expectEqual(@as(u64, 4), out.work.value.fields);
    try testing.expect(out.work.value.field_steps <= 64 * out.work.value.fields + 33 * out.work.value.field_queries);
}

test "realm builder static local capture and tuple projection preserve actual callable identities" {
    var f = try Fixture.init(
        \\pub leaf : ⊤ → ⊤
        \\leaf x = x
        \\
        \\
        \\pub make : ⊤ → (⊤ → ⊤)
        \\make x =
        \\    chosen = leaf
        \\    λy → chosen y
        \\
        \\
        \\pub call : ⊤ → ⊤
        \\call x =
        \\    pair = ( make x, leaf )
        \\    pair.0 x
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    try privateSeed(&out, try f.exec(&out, "leaf"), 8);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 8 }, fact(&result, try f.exec(&out, "call")));
    try testing.expectEqual(@as(u64, 0), out.work.residuals);
}

test "realm builder execution recursion is finite while recursive returned origins remain unresolved" {
    var f = try Fixture.init(
        \\pub recursion : ⊤ → ⊤
        \\recursion x = recursion x
        \\
        \\
        \\pub returned : ⊤ → (⊤ → ⊤)
        \\returned x = returned x
        \\
        \\
        \\pub invoke : ⊤ → ⊤
        \\invoke x = (returned x) x
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31 }, fact(&result, try f.exec(&out, "recursion")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31 }, fact(&result, try f.exec(&out, "returned")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31, .incomplete = true }, fact(&result, try f.exec(&out, "invoke")));
    var cycle = false;
    for (0..out.ports.len) |i| {
        const o = out.ports.get(i).origin;
        if (o.kind == .residual and o.reason == .value_cycle) cycle = true;
    }
    try testing.expect(cycle);
    try testing.expect(out.work.value.dependencies <= 3 * out.work.ports);
}

test "realm builder actual attested native identity stays separate from blocked and retained uses" {
    var f = try Fixture.initWith(
        \\import Browser.Host.TextEncoder as TextEncoder
        \\
        \\
        \\type Flag = Yes | No
        \\
        \\
        \\pub left : ⊤ → TextEncoder.TextEncoder
        \\left x = TextEncoder.new x
        \\
        \\
        \\pub right : ⊤ → TextEncoder.TextEncoder
        \\right x = TextEncoder.new x
        \\
        \\
        \\pub run : ⊤ → TextEncoder.TextEncoder
        \\run x = left x
        \\
        \\
        \\pub retained : ⊤ → TextEncoder.TextEncoder
        \\retained = TextEncoder.new
        \\
        \\
        \\pub blocked : Flag → TextEncoder.TextEncoder
        \\blocked flag =
        \\    case flag of
        \\        Yes → TextEncoder.new ⊤
        \\        No → TextEncoder.new ⊤
        \\
    , true);
    defer f.deinit();
    for ([_][]const u8{ "left", "right" }) |name| {
        const q = try f.q("Main", name);
        const iface = &f.session.resolution.interfaces[q.module.int()];
        const provenance = &f.session.resolution.provenance[q.module.int()];
        var found = false;
        for (iface.values, 0..) |value, vi| {
            if (provenance.valueDecl(vi).?.int() != q.declaration) continue;
            const block = iface.effectBlock(iface.schemes[@backingInt(value.scheme)]) orelse return error.MissingEffect;
            var sites = block.sites();
            while (sites.next()) |site| {
                if (site.root != 0 or site.steps.len != 0) continue;
                try testing.expectEqual(@as(u8, 1), block.class(site.class).rung);
                found = true;
            }
        }
        try testing.expect(found);
    }
    const installed = f.session.native_bindings.text_encoder orelse return error.MissingNativeAttestation;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@import("../native/Source.zig").provenance, &digest, .{});
    const seed: Realms.NativeSeed = .{ .target = .{ .module = installed.module, .declaration = installed.checked.declaration }, .allowed = installed.candidate.realm_mask, .binding_digest = digest };
    var input = f.input();
    input.native_seeds = &.{seed};
    try testing.checkAllAllocationFailures(gpa, struct {
        fn run(a: std.mem.Allocator, original: Build.Input) !void {
            var output = try Build.build(a, original);
            defer output.deinit(a);
            try testing.expectEqual(@as(usize, 1), output.native_values.len);
        }
    }.run, .{input});
    var out = try Build.build(gpa, input);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), out.native_values.len);
    const native = try out.callableAt(seed.target);
    try testing.expectEqualDeep(Build.NativeValue{ .target = seed.target, .binding_digest = digest, .exec = native, .port = (try out.declaration(seed.target)).port }, out.native_values.get(0));
    try testing.expectEqual(@as(u64, 1), out.work.seed_reads);
    try testing.expectEqual(native, try f.exec(&out, "retained"));
    const blocked = try f.exec(&out, "blocked");
    var blocked_calls: usize = 0;
    for (0..out.calls.len) |i| {
        const call = out.calls.get(i);
        if (call.ambient != blocked) continue;
        try testing.expectEqual(native, call.target);
        try testing.expect(call.classification == .residual);
        blocked_calls += 1;
    }
    try testing.expectEqual(@as(usize, 2), blocked_calls);
    for (0..out.edges.len) |i| try testing.expect(out.edges.get(i).caller != blocked);
    for (0..out.uses.len) |i| {
        const use = out.uses.get(i);
        if (use.kind == .retention) {
            try testing.expectEqual(Realms.SiteId.none, use.site);
            try testing.expectEqual(Build.CallId.none, use.call);
        } else if (use.kind == .invocation) {
            try testing.expect(use.call != .none);
            const call = out.calls.get(@backingInt(use.call));
            try testing.expectEqual(call.site, use.site);
        }
    }
    const left = try f.exec(&out, "left");
    const right = try f.exec(&out, "right");
    try privateSeed(&out, left, 1);
    try privateSeed(&out, right, 2);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 1 }, fact(&result, try f.exec(&out, "run")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 2, .seed = 2 }, fact(&result, right));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31, .incomplete = true }, fact(&result, blocked));
}

test "realm builder releases all failed allocations and owns results beyond the source session" {
    var f = try Fixture.init("pub identity : ⊤ → ⊤\nidentity x = x\n\n\npub invoke : ⊤ → ⊤\ninvoke x = { value = identity, other = identity }.value x\n");
    var alive = true;
    defer if (alive) f.deinit();
    const q = try f.q("Main", "invoke");
    for ([_]bool{ false, true }) |receiver_origins| {
        var capture_input = f.input();
        capture_input.receiver_origins = receiver_origins;
        try testing.checkAllAllocationFailures(gpa, struct {
            fn run(a: std.mem.Allocator, input: Build.Input) !void {
                var output = try Build.build(a, input);
                defer output.deinit(a);
                try testing.expectEqual(@as(u64, 1), output.work.calls);
                try testing.expectEqual(if (input.receiver_origins) output.ports.len else 0, output.receiver_aliases.len);
            }
        }.run, .{capture_input});
    }
    var owned_input = f.input();
    owned_input.receiver_origins = true;
    var out = try Build.build(gpa, owned_input);
    defer out.deinit(gpa);
    const exec = try out.callableAt(q);
    f.deinit();
    alive = false;
    try testing.expectEqual(out.ports.len, out.receiver_aliases.len);
    for (out.receiver_aliases) |port| if (port != .none) try testing.expect(@backingInt(port) < out.ports.len);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31 }, fact(&result, exec));
}

test "realm builder original shared fields and alias families have bounded directory and memo work" {
    var source: std.Io.Writer.Allocating = .init(gpa);
    defer source.deinit();
    const w = &source.writer;
    try w.writeAll("pub leaf : ⊤ → ⊤\nleaf x = x\n\n\nbag = { ");
    for (0..64) |i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("field{d} = leaf", .{i});
    }
    try w.writeAll(" }\n\n\n");
    for (0..64) |i| try w.print("pub select{d} : ⊤ → ⊤\nselect{d} x = bag.field{d} x\n\n\n", .{ i, i, i });
    const bytes = try gpa.dupeSentinel(u8, source.written(), 0);
    defer gpa.free(bytes);
    var f = try Fixture.init(bytes);
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u64, 64), out.work.value.fields);
    try testing.expectEqual(@as(u64, 64), out.work.calls);
    try testing.expectEqual(@as(u64, 64), out.work.edges);
    try testing.expectEqual(@as(u64, 0), out.work.residuals);
    try testing.expectEqual(out.work.ports, out.work.value.ports);
    try testing.expect(out.work.value.dependencies <= 3 * out.work.ports);
    try testing.expect(out.work.value.field_steps <= 64 * out.work.value.fields + 33 * out.work.value.field_queries);
    try privateSeed(&out, try f.exec(&out, "leaf"), 16);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    for (0..64) |i| {
        var name: [32]u8 = undefined;
        const used = try std.fmt.bufPrint(&name, "select{d}", .{i});
        try testing.expectEqualDeep(Realms.Fact{ .allowed = 16 }, fact(&result, try f.exec(&out, used)));
    }
}

test "realm builder unknown aggregate callback escape retains its original port obligation" {
    var f = try Fixture.init(
        \\pub leaf : ⊤ → ⊤
        \\leaf x = x
        \\
        \\
        \\pub escape callback = callback { value = leaf }
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    const exec = try f.exec(&out, "escape");
    var escape_count: usize = 0;
    for (0..out.uses.len) |i| {
        const use = out.uses.get(i);
        if (use.kind != .escape) continue;
        try testing.expectEqual(Realms.ExecId.none, use.native_exec);
        try testing.expectEqual(Build.Values.Kind.record, (try out.origin(use.port)).kind);
        try testing.expect(use.call != .none and use.site != .none);
        const call = out.calls.get(@backingInt(use.call));
        try testing.expectEqual(exec, call.ambient);
        try testing.expect(call.classification == .residual);
        try testing.expectEqual(call.site, use.site);
        escape_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), escape_count);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31, .incomplete = true }, fact(&result, exec));
}

test "realm builder same local binder indices in separate owners do not join captured functions" {
    var f = try Fixture.init(
        \\pub left : ⊤ → ⊤
        \\left x = x
        \\
        \\
        \\pub right : ⊤ → ⊤
        \\right x = x
        \\
        \\
        \\pub makeLeft : ⊤ → (⊤ → ⊤)
        \\makeLeft x =
        \\    chosen = left
        \\    λy → chosen y
        \\
        \\
        \\pub makeRight : ⊤ → (⊤ → ⊤)
        \\makeRight x =
        \\    chosen = right
        \\    λy → chosen y
        \\
        \\
        \\pub runLeft : ⊤ → ⊤
        \\runLeft x = (makeLeft x) x
        \\
        \\
        \\pub runRight : ⊤ → ⊤
        \\runRight x = (makeRight x) x
        \\
    );
    defer f.deinit();
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    try privateSeed(&out, try f.exec(&out, "left"), 1);
    try privateSeed(&out, try f.exec(&out, "right"), 2);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 1 }, fact(&result, try f.exec(&out, "runLeft")));
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 2 }, fact(&result, try f.exec(&out, "runRight")));
}

test "realm builder missing source and wrong seed declaration fail without a partial graph" {
    var f = try Fixture.init("pub identity : ⊤ → ⊤\nidentity x = x\n");
    defer f.deinit();
    const q = try f.q("Main", "identity");
    var input = f.input();
    const seed: Realms.NativeSeed = .{ .target = q, .allowed = 31, .binding_digest = @splat(0) };
    input.native_seeds = &.{seed};
    try testing.expectError(error.InvalidSeed, Build.build(gpa, input));
    input.native_seeds = &.{};
    const source = &f.session.checked.dispatch[q.module.int()].realm_sources;
    source.present = false;
    defer source.present = true;
    try testing.expectError(error.MissingSource, Build.build(gpa, input));
}

test "realm builder identical ordinary native source has no seed authority and calls stay incomplete" {
    var f = try Fixture.initMode(
        \\import Browser.Host.TextEncoder as TextEncoder
        \\
        \\
        \\pub invoke : ⊤ → TextEncoder.TextEncoder
        \\invoke x = TextEncoder.new x
        \\
    , .ordinary);
    defer f.deinit();
    try testing.expectEqualDeep(@import("../native/Bindings.zig").Registry{}, f.session.native_bindings);
    var out = try Build.build(gpa, f.input());
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), out.native_values.len);
    try testing.expectEqual(@as(usize, 0), out.seeds.len);
    try testing.expectEqual(@as(u64, 0), out.work.seed_reads);
    var result = try Realms.solve(gpa, out.input());
    defer result.deinit(gpa);
    try testing.expectEqualDeep(Realms.Fact{ .allowed = 31, .incomplete = true }, fact(&result, try f.exec(&out, "invoke")));
}

test "realm builder native callback escapes are independent of declaration traversal order" {
    const prefix =
        \\import Browser.Host.TextEncoder as TextEncoder
        \\
        \\
        \\pub direct : ⊤ → TextEncoder.TextEncoder
        \\direct ⊤ = TextEncoder.new ⊤
        \\
        \\
    ;
    const caller =
        \\pub caller : ⊤ → TextEncoder.TextEncoder
        \\caller ⊤ = invoke TextEncoder.new
        \\
        \\
    ;
    const invoke =
        \\pub invoke callback = callback ⊤
        \\
        \\
    ;
    for ([_][:0]const u8{ prefix ++ caller ++ invoke, prefix ++ invoke ++ caller }) |source| {
        var f = try Fixture.initWith(source, true);
        defer f.deinit();
        const installed = f.session.native_bindings.text_encoder orelse return error.MissingNativeAttestation;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@import("../native/Source.zig").provenance, &digest, .{});
        const seed: Realms.NativeSeed = .{ .target = .{ .module = installed.module, .declaration = installed.checked.declaration }, .allowed = installed.candidate.realm_mask, .binding_digest = digest };
        var input = f.input();
        input.native_seeds = &.{seed};
        var out = try Build.build(gpa, input);
        defer out.deinit(gpa);
        const native = try out.callableAt(seed.target);
        const direct_exec = try f.exec(&out, "direct");
        const caller_exec = try f.exec(&out, "caller");
        var direct_uses: usize = 0;
        var escaped_uses: usize = 0;
        for (0..out.uses.len) |i| {
            const use = out.uses.get(i);
            if (use.native_exec != native) continue;
            if (use.kind == .invocation) {
                const call = out.calls.get(@backingInt(use.call));
                try testing.expectEqual(direct_exec, call.ambient);
                try testing.expect(call.classification == .direct);
                direct_uses += 1;
            } else if (use.kind == .escape) {
                const call = out.calls.get(@backingInt(use.call));
                try testing.expectEqual(caller_exec, call.ambient);
                try testing.expectEqual(native, @as(Build.ExecId, @fromBackingInt((try out.origin(use.port)).value)));
                escaped_uses += 1;
            }
        }
        try testing.expectEqual(@as(usize, 1), direct_uses);
        try testing.expectEqual(@as(usize, 1), escaped_uses);
        var result = try Realms.solve(gpa, out.input());
        defer result.deinit(gpa);
        try testing.expectEqualDeep(Realms.Fact{ .allowed = 31 }, fact(&result, direct_exec));
        try testing.expectEqualDeep(Realms.Fact{ .allowed = 31, .incomplete = true }, fact(&result, caller_exec));
    }
}

test "native exposure exact Unit contract preserves execution and returned value" {
    const Exposure = @import("../native/Exposure.zig");
    const Bir = @import("../bir/Bir.zig");
    var f = try Fixture.initWith(
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\pub make : ⊤ → Encoder.TextEncoder
        \\make argument = Encoder.new argument
        \\
        \\
        \\pub factory : ⊤ → (⊤ → Encoder.TextEncoder)
        \\factory _ = Encoder.new
        \\
    , true);
    defer f.deinit();
    const installed = f.session.native_bindings.text_encoder orelse return error.MissingNativeAttestation;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@import("../native/Source.zig").provenance, &digest, .{});
    const seed: Realms.NativeSeed = .{ .target = .{ .module = installed.module, .declaration = installed.checked.declaration }, .allowed = installed.candidate.realm_mask, .binding_digest = digest, .contract = .unit_to_native };
    var input = f.input();
    input.native_seeds = &.{seed};
    var out = try Build.build(gpa, input);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), out.contracts.len);
    const witness = out.contracts.get(0);
    try testing.expectEqual(try out.callableAt(seed.target), witness.native_exec);
    const call = out.calls.get(@backingInt(witness.call));
    try testing.expectEqual(try f.exec(&out, "make"), call.ambient);
    var edge_found = false;
    for (0..out.edges.len) |i| {
        const edge = out.edges.get(i);
        if (edge.caller == call.ambient and edge.callee == witness.native_exec) edge_found = true;
    }
    try testing.expect(edge_found);
    for (0..out.uses.len) |i| {
        const use = out.uses.get(i);
        try testing.expect(!(use.kind == .escape and use.port == witness.argument and use.call == witness.call));
    }
    const birs = try gpa.alloc(*const Bir, out.modules.len);
    defer gpa.free(birs);
    for (birs, 0..) |*bir, i| bir.* = f.session.artifacts.bir(f.session.graph.moduleFile(@fromBackingInt(@intCast(i))));
    const Emission = @import("../native/Emission.zig");
    var no_plan: @import("../entry/Plan.zig") = .{};
    defer no_plan.deinit(gpa);
    var no_entries: @import("../entry/CompactGraph.zig") = .{};
    defer no_entries.deinit(gpa);
    const unrelated_live: @import("../js/Reach.zig").Result = .empty;
    try testing.expectError(error.InvalidNativeAuthority, Emission.prepare(gpa, .{
        .registry = &f.session.native_bindings,
        .source = f.input(),
        .selection = .{ .graph = &f.session.graph, .plan = &no_plan, .entries = &no_entries, .selected = try f.q("Main", "make") },
        .live = &unrelated_live,
    }));
    var exposed = try Exposure.solve(gpa, &out, birs, f.session.resolution.interfaces);
    defer exposed.deinit(gpa);
    try testing.expectEqual(Exposure.native, try exposed.exec(call.ambient));
    try testing.expectEqual(Exposure.native, try exposed.exec(try f.exec(&out, "factory")));
    try testing.expectEqual(@as(u8, 0), try exposed.port(witness.result));
    try testing.expect(exposed.work.transitions <= exposed.work.nodes * 2);
    try testing.expect(exposed.work.deliveries <= exposed.work.edges * 2);
    try testing.checkAllAllocationFailures(gpa, struct {
        fn run(a: std.mem.Allocator, built: *const Build.Output, bs: []const *const Bir, interfaces: []const @import("../resolve/Interface.zig")) !void {
            var result = try Exposure.solve(a, built, bs, interfaces);
            defer result.deinit(a);
        }
    }.run, .{ &out, birs, f.session.resolution.interfaces });
}

test "native exposure blocked calls and captured origins never gain Unit discharge" {
    const Exposure = @import("../native/Exposure.zig");
    const Bir = @import("../bir/Bir.zig");
    var f = try Fixture.initWith(
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\pub type Flag = Yes | No
        \\
        \\
        \\pub blocked : Flag → Encoder.TextEncoder
        \\blocked flag =
        \\    case flag of
        \\        Yes → Encoder.new ⊤
        \\        No → Encoder.new ⊤
        \\
        \\
        \\pub capture : ⊤ → (⊤ → Encoder.TextEncoder)
        \\capture argument = λ_ → Encoder.new argument
        \\
    , true);
    defer f.deinit();
    const installed = f.session.native_bindings.text_encoder orelse return error.MissingNativeAttestation;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@import("../native/Source.zig").provenance, &digest, .{});
    var seed: Realms.NativeSeed = .{ .target = .{ .module = installed.module, .declaration = installed.checked.declaration }, .allowed = installed.candidate.realm_mask, .binding_digest = digest, .contract = .unit_to_native };
    var input = f.input();
    input.native_seeds = &.{seed};
    var out = try Build.build(gpa, input);
    defer out.deinit(gpa);
    const blocked = try f.exec(&out, "blocked");
    var blocked_calls: usize = 0;
    for (0..out.calls.len) |i| {
        const call = out.calls.get(i);
        if (call.ambient != blocked) continue;
        try testing.expectEqual(.residual, call.classification);
        for (0..out.contracts.len) |ci| try testing.expect(@backingInt(out.contracts.get(ci).call) != i);
        blocked_calls += 1;
    }
    try testing.expectEqual(@as(usize, 2), blocked_calls);
    const birs = try gpa.alloc(*const Bir, out.modules.len);
    defer gpa.free(birs);
    for (birs, 0..) |*bir, i| bir.* = f.session.artifacts.bir(f.session.graph.moduleFile(@fromBackingInt(@intCast(i))));
    var result = try Exposure.solve(gpa, &out, birs, f.session.resolution.interfaces);
    defer result.deinit(gpa);
    try testing.expect(try result.exec(blocked) & Exposure.unresolved != 0);
    try testing.expect(try result.exec(try f.exec(&out, "capture")) & Exposure.unresolved != 0);
    seed.contract = .unavailable;
    input.native_seeds = &.{seed};
    var untrusted = try Build.build(gpa, input);
    defer untrusted.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), untrusted.contracts.len);
}
