//! L2: the records that cross layers (`docs/design/ownership-v2.md` §3,
//! §2.7, §2.8, §2.11, §2.12, §6): a use, a demand, an obligation, a supply,
//! a keep edge, a verdict and its cause, the callback proof request and
//! answer of §5, and the pre-pass's facts. Nothing here has behaviour: every
//! table above refers down to these types and never up to each other.
//!
//! `Cause` is in R-6.3's print order and `rules_test` checks it stays so.
//!
//! Obligations kept here: none (data only).

const std = @import("std");
const Ids = @import("Ids.zig");

pub const CellId = Ids.CellId;
pub const NodeId = Ids.NodeId;
pub const PathId = Ids.PathId;
pub const SetId = Ids.SetId;
pub const CondId = Ids.CondId;
pub const LabelId = Ids.LabelId;
pub const RegionId = Ids.RegionId;

/// What a use is (§2.7): a field chain of this frame's own (hoistable), a
/// whole use, or an argument read by a callee at the paths its class names.
pub const UseKind = enum(u8) { field, whole, call };

/// One use `(local, path, point, kind, callee use node)` (§2.7).
pub const Use = struct {
    local: u32,
    path: PathId,
    point: u32,
    kind: UseKind,
    region: RegionId,
    /// `call` only: the callee's `use` node, projected lazily.
    use_node: NodeId,
};

/// The kinds of demand (§2.8).
pub const DemandKind = enum(u8) {
    writer,
    construction,
    append,
    update,
    callsite,
    send,
    once,
    entry,
    consumed,
    focus,

    /// A deep demand reads `reach(base)` and the trie descendants (§2.8).
    pub fn isDeep(k: DemandKind) bool {
        return k == .send or k == .consumed or k == .focus;
    }
};

/// A demand `(point, kind, base, F, operands, pending, deep?)` (§2.8).
pub const Demand = struct {
    point: u32,
    kind: DemandKind,
    base: NodeId,
    /// The written fields, a persistent set of field symbols, or `.none`
    /// for a whole write.
    fields: SetId,
    /// The other operands of the instruction: a run of `NodeId`s.
    operands: Ids.Range,
    /// Pending operands evaluated whose consumer has not run.
    pending: Ids.Range,
};

/// R-6.3's causes in print order; `e`/`a`/`p` is the `Exactness`.
pub const Cause = enum(u8) {
    unknown,
    escaped,
    top_level,
    captured_edit,
    disjoint,
    held_operand,
    later_use,
    alias,
    captured,
    element,
    call,
    supply,
    need,
    limit,
    exclusive,
    once,
    payload,
    read_only,
    level,
};

/// How a verdict was reached (R-6.3): exact sharing, an approximation, or
/// a position rule.
pub const Exactness = enum(u8) { exact, approximate, position };

/// R-0.3: accepted with its ground, pending with a detail, or refused with
/// a cause.
pub const Verdict = union(enum(u8)) {
    accepted: Accepted,
    pending: Pending,
    refused: Refused,

    pub const Accepted = enum(u8) { fresh, call, param, callback_param, once, entry, assumed };
    pub const Pending = struct { point: u32, detail: u32 };
    pub const Refused = struct {
        cause: Cause,
        exactness: Exactness,
        /// The holder named (the one used first, ties to the earlier
        /// binding).
        holder: u32,
        holder_path: PathId,
        later_use: u32,
    };
};

/// A supply (§2.11): the node handed to function parameter `j` as its
/// `k`th argument at `point`.
pub const Supply = struct {
    j: u32,
    k: u32,
    node: NodeId,
    point: u32,
    owned: bool,
    taken: bool,
};

/// A keep edge (§2.11): `keep(j, k, kept path, written path)`.
pub const Keep = struct {
    j: u32,
    k: u32,
    kept_path: PathId,
    written_path: PathId,
    writer: u32,
};

/// A callee's obligation on its caller (§2.11): a `W` at a parameter path,
/// an `E`, an `xreq` atom, or an entry protocol's.
pub const Obligation = struct {
    kind: Kind,
    param: u32,
    path: PathId,
    cond: CondId,

    pub const Kind = enum(u8) { write, escape, xreq, entry };
};

/// `Cond` asks `Calls` to interpret callback labels (§5, *Callback proof
/// interface*): it never calls up; it records a request and waits.
pub const ProofRequest = struct {
    owner: Ids.SummaryAccountId,
    labels: Ids.Range,
    actual_template: NodeId,
    path: PathId,
    input_version: u32,
};

pub const ProofAnswer = struct {
    request: u32,
    /// The instantiated cells at the requested path.
    cells: SetId,
    status: Status,

    pub const Status = enum(u8) { proved, refuted, waiting };
};

/// What the BIR pre-pass answers (§2.12): per declaration its group and
/// whether the group is recursive; per lambda its enclosing frame; alias
/// chains of function values; read counts of private parameterless
/// values; which declarations are a type's `eq`/`compare`; the spread
/// chains `Lower` recorded; the `withDefault (map m f) d` shapes.
pub const Prepass = struct {
    /// `group_of[decl]`: the group index; groups are in dependency order.
    group_of: []const u32,
    /// `order[starts[g]..starts[g + 1]]` are group `g`'s declarations.
    order: []const u32,
    starts: []const u32,
    /// Whether group `g` is recursive: more than one member, or a self edge.
    recursive: []const bool,
    /// Per declaration: `.none`, or the declaration it is a top-level alias
    /// of (`f = g`), chains followed to the end (R-5.5.6).
    alias_of: []const u32,
    /// Per declaration: the number of direct reads of it by this module's
    /// own declarations outside lambdas (R-4.9.3), with the one reader when
    /// exactly one (`reader[d]`, else `none`).
    read_count: []const u32,
    reader: []const u32,
    /// Per declaration: `eq`/`compare` of a type (§2.13.13), else `.none`.
    method_of: []const MethodRole,
    /// Per instruction of the module: for a `lambda`, the instruction of
    /// the enclosing frame — the enclosing `lambda` or `let_def` with
    /// parameters, or `none` for the declaration's own body.
    enclosing_frame: []const u32,
    /// The spread chains (§2.13.2), in source order.
    spreads: []const Spread,
    /// The `withDefault (map m f) d` shapes (§2.13.12), by the outer call.
    joins: []const MaybeJoin,

    pub const none: u32 = Ids.none_int;

    pub const MethodRole = packed struct(u8) {
        eq: bool = false,
        compare: bool = false,
        _pad: u6 = 0,
    };

    /// A spread chain `Lower` recorded: its root call and its items in
    /// source order (§2.13.2). The BIR table this reads does not exist yet
    /// (S2b): the pre-pass publishes an empty list until it does.
    pub const Spread = struct {
        root: u32,
        items: Ids.Range,
    };

    pub const SpreadItem = struct { inst: u32, is_spread: bool };

    /// `Maybe.withDefault (Maybe.map m f) d` or the `Result` twin: the
    /// outer call, the inner call, and the operands.
    pub const MaybeJoin = struct {
        outer: u32,
        inner: u32,
        m: u32,
        f: u32,
        d: u32,
    };
};

comptime {
    Ids.assertRecord(Use);
    Ids.assertRecord(Demand);
    Ids.assertRecord(Supply);
    Ids.assertRecord(Keep);
    Ids.assertRecord(Obligation);
    Ids.assertRecord(ProofRequest);
    Ids.assertRecord(ProofAnswer);
    Ids.assertRecord(Prepass.Spread);
    Ids.assertRecord(Prepass.MaybeJoin);
    std.debug.assert(@sizeOf(Use) == 24);
    std.debug.assert(@sizeOf(Demand) == 32);
}

const testing = std.testing;

test "the causes are R-6.3's nineteen, in print order" {
    try testing.expectEqual(@as(usize, 19), @typeInfo(Cause).@"enum".field_names.len);
    try testing.expectEqual(@as(u8, 0), @backingInt(Cause.unknown));
    try testing.expectEqual(@as(u8, 18), @backingInt(Cause.level));
    try testing.expect(DemandKind.send.isDeep() and !DemandKind.writer.isDeep());
}
