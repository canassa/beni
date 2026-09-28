//! Just enough of an x86-64 instruction decoder for `tests/coverage.zig` to
//! build a control-flow graph: every instruction's length, and what the few
//! that matter do — branches, calls, returns, traps, jumps through a table,
//! and the loads that put a coverage guard's address in the first argument
//! register.
//!
//! It decodes the 64-bit mode encodings a compiler emits: legacy prefixes,
//! REX, the one-byte, `0F`, `0F 38` and `0F 3A` maps, VEX and EVEX. An
//! encoding outside those (AMD's XOP, or a byte that is no instruction in
//! 64-bit mode) is `error.Unsupported`, and the caller stops trusting the
//! function it was in.

const std = @import("std");

/// The opcode map an instruction's opcode byte is read from. VEX and EVEX
/// name the same maps by number.
pub const Map = enum(u8) {
    one = 0,
    @"0f" = 1,
    @"0f38" = 2,
    @"0f3a" = 3,
    /// EVEX maps 5 and 6 (half-precision); nothing here reads them.
    evex5 = 5,
    evex6 = 6,
};

/// One decoded instruction: its length and the fields the classifiers below
/// read.
pub const Instruction = struct {
    len: u8,
    map: Map,
    opcode: u8,
    /// The REX prefix, or the REX bits a VEX or EVEX prefix carries (W, R,
    /// X, B in the usual positions, uninverted); 0 when there is none.
    rex: u8 = 0,
    /// Whether a `66` operand-size prefix was present.
    operand_16: bool = false,
    modrm: ?u8 = null,
    sib: ?u8 = null,
    disp: i32 = 0,
    imm: i64 = 0,

    fn modField(i: Instruction) u2 {
        return @intCast(i.modrm.? >> 6);
    }

    /// ModRM's `reg` field, without the REX extension: the opcode
    /// extension of a group instruction.
    fn regField(i: Instruction) u3 {
        return @intCast((i.modrm.? >> 3) & 7);
    }

    fn rmField(i: Instruction) u3 {
        return @intCast(i.modrm.? & 7);
    }

    fn rexW(i: Instruction) bool {
        return i.rex & 8 != 0;
    }

    fn rexR(i: Instruction) u4 {
        return if (i.rex & 4 != 0) 8 else 0;
    }

    fn rexB(i: Instruction) u4 {
        return if (i.rex & 1 != 0) 8 else 0;
    }

    /// The memory operand's 32-bit displacement when it is an absolute
    /// address plus registers — `[disp32 + index*s]` or `[disp32 + reg]`,
    /// the forms a jump table is read with — and not relative to `rip`.
    fn absoluteDisplacement(i: Instruction) ?u64 {
        const mod = i.modField();
        if (mod == 3) return null;
        const wide = mod == 2 or (mod == 0 and i.sib != null and i.sib.? & 7 == 5);
        if (!wide) return null;
        return @bitCast(@as(i64, i.disp));
    }

    /// Whether the memory operand is `[rip + disp32]`.
    fn ripRelative(i: Instruction) bool {
        return i.modField() == 0 and i.rmField() == 5;
    }
};

pub const Error = error{
    /// The bytes end inside the instruction.
    Truncated,
    /// Not an encoding this decoder knows.
    Unsupported,
};

/// The longest an x86 instruction may be.
pub const max_len = 15;

/// Decode the instruction at the start of `code`.
pub fn decode(code: []const u8) Error!Instruction {
    var r: Reader = .{ .code = code[0..@min(code.len, max_len)] };
    var operand_16 = false;
    var address_32 = false;
    var byte = try r.next();
    // Legacy prefixes, in any order.
    while (true) : (byte = try r.next()) {
        switch (byte) {
            0x66 => operand_16 = true,
            0x67 => address_32 = true,
            0xf0, 0xf2, 0xf3, 0x2e, 0x36, 0x3e, 0x26, 0x64, 0x65 => {},
            else => break,
        }
    }
    var inst: Instruction = .{ .len = 0, .map = .one, .opcode = 0, .operand_16 = operand_16 };
    // REX, which must come last.
    if (byte & 0xf0 == 0x40) {
        inst.rex = byte;
        byte = try r.next();
    }
    var imm_len: u8 = 0;
    switch (byte) {
        0xc5 => {
            const p0 = try r.next();
            inst.rex = if (p0 & 0x80 == 0) 4 else 0;
            inst.map = .@"0f";
            inst.opcode = try r.next();
            // `vzeroupper` and `vzeroall` are the only VEX instructions
            // without a ModRM byte.
            if (inst.opcode != 0x77) try readModrm(&r, &inst);
            imm_len = vexImmediate(inst.map, inst.opcode);
        },
        0xc4 => {
            const p0 = try r.next();
            const p1 = try r.next();
            inst.rex = vexRex(p0, p1);
            inst.map = try vexMap(p0 & 0x1f);
            inst.opcode = try r.next();
            if (!(inst.map == .@"0f" and inst.opcode == 0x77)) try readModrm(&r, &inst);
            imm_len = vexImmediate(inst.map, inst.opcode);
        },
        0x62 => {
            const p0 = try r.next();
            const p1 = try r.next();
            _ = try r.next();
            inst.rex = vexRex(p0, p1);
            inst.map = try vexMap(p0 & 0x07);
            inst.opcode = try r.next();
            try readModrm(&r, &inst);
            imm_len = vexImmediate(inst.map, inst.opcode);
        },
        0x8f => {
            // `8F /0` is `pop r/m`; with a map number of 8 or more in the
            // next byte's low bits it is an XOP prefix instead.
            if ((try r.peek()) & 0x1f >= 8) return error.Unsupported;
            inst.opcode = byte;
            try readModrm(&r, &inst);
        },
        0x0f => {
            const second = try r.next();
            switch (second) {
                0x38 => {
                    inst.map = .@"0f38";
                    inst.opcode = try r.next();
                    try readModrm(&r, &inst);
                },
                0x3a => {
                    inst.map = .@"0f3a";
                    inst.opcode = try r.next();
                    try readModrm(&r, &inst);
                    imm_len = 1;
                },
                else => {
                    inst.map = .@"0f";
                    inst.opcode = second;
                    if (!hasModrm0f(second)) return error.Unsupported;
                    if (modrm0f[second] == 1) try readModrm(&r, &inst);
                    imm_len = immediate0f(inst);
                },
            }
        },
        else => {
            inst.opcode = byte;
            const kind = modrm1[byte];
            if (kind == 2) return error.Unsupported;
            if (kind == 1) try readModrm(&r, &inst);
            imm_len = immediate1(inst, address_32);
        },
    }
    inst.imm = try r.signed(imm_len);
    inst.len = r.at;
    return inst;
}

/// What an instruction does to the flow of control.
pub const Flow = union(enum) {
    /// Falls through to the next instruction; a `call` is one of these.
    next,
    /// A conditional branch to the address, or on to the next instruction.
    branch: u64,
    /// An unconditional jump to the address.
    jump: u64,
    /// An unconditional jump through memory or a register: a switch's jump
    /// table, or a tail call through a pointer.
    jump_indirect,
    /// A return: control leaves the function.
    ret,
    /// A trap (`ud2`, `int3`, `hlt`): control goes nowhere.
    trap,
};

/// How `inst`, at `address`, moves control.
pub fn flow(inst: Instruction, address: u64) Flow {
    const next = address +% inst.len;
    const target = next +% @as(u64, @bitCast(inst.imm));
    switch (inst.map) {
        .one => switch (inst.opcode) {
            0x70...0x7f, 0xe0...0xe3 => return .{ .branch = target },
            0xeb, 0xe9 => return .{ .jump = target },
            0xc2, 0xc3, 0xca, 0xcb, 0xcf => return .ret,
            0xcc, 0xf4 => return .trap,
            0xff => switch (inst.regField()) {
                4, 5 => return .jump_indirect,
                else => return .next,
            },
            else => return .next,
        },
        .@"0f" => switch (inst.opcode) {
            0x80...0x8f => return .{ .branch = target },
            0x0b, 0xb9, 0xff => return .trap,
            else => return .next,
        },
        else => return .next,
    }
}

/// The target of a direct `call rel32` at `address`, or null.
pub fn callTarget(inst: Instruction, address: u64) ?u64 {
    if (inst.map != .one or inst.opcode != 0xe8) return null;
    return address +% inst.len +% @as(u64, @bitCast(inst.imm));
}

/// The value `inst`, at `address`, puts in `rdi` when it is one of the
/// forms a compiler loads a constant address with: `mov edi, imm32`,
/// `mov rdi, imm64`, `mov rdi, simm32` and `lea rdi, [rip + disp32]`. Null
/// for anything else, including other writes to `rdi`.
pub fn rdiConstant(inst: Instruction, address: u64) ?u64 {
    if (inst.map != .one) return null;
    switch (inst.opcode) {
        0xbf => if (inst.rexB() == 0) {
            // A 32-bit move zero-extends; with REX.W the immediate is 64
            // bits wide.
            return if (inst.rexW()) @bitCast(inst.imm) else @as(u32, @truncate(@as(u64, @bitCast(inst.imm))));
        },
        0xc7 => if (inst.modField() == 3 and inst.regField() == 0 and inst.rmField() == 7 and inst.rexB() == 0) {
            return if (inst.rexW()) @bitCast(inst.imm) else @as(u32, @truncate(@as(u64, @bitCast(inst.imm))));
        },
        0x8d => if (inst.modField() == 0 and inst.rmField() == 5 and inst.regField() == 7 and inst.rexR() == 0 and inst.rexW()) {
            return address +% inst.len +% @as(u64, @bitCast(@as(i64, inst.disp)));
        },
        else => {},
    }
    return null;
}

/// Where an indirect `jmp` takes its target from.
pub const IndirectJump = union(enum) {
    /// A register: a jump through a table loaded before it, or a tail call
    /// through a function pointer.
    register: u4,
    /// Memory at an absolute address plus registers: a jump table there.
    table: u64,
    /// A slot at `[rip + disp32]`: a tail call through the global offset
    /// table.
    rip_slot,
    /// Any other memory operand, a pointer read out of a structure.
    other,
};

/// For an indirect `jmp`, where its target comes from; null for anything
/// else.
pub fn indirectJump(inst: Instruction) ?IndirectJump {
    if (inst.map != .one or inst.opcode != 0xff or inst.regField() != 4) return null;
    if (inst.modField() == 3) return .{ .register = @as(u4, inst.rmField()) | inst.rexB() };
    if (inst.ripRelative()) return .rip_slot;
    if (inst.absoluteDisplacement()) |table| return .{ .table = table };
    return .other;
}

/// For `mov reg64, [disp32 + ...]`, the register loaded and the absolute
/// address read from: the load before a `jmp reg` through a jump table.
pub fn tableLoad(inst: Instruction) ?struct { register: u4, table: u64 } {
    if (inst.map != .one or inst.opcode != 0x8b or !inst.rexW()) return null;
    const table = inst.absoluteDisplacement() orelse return null;
    return .{ .register = @as(u4, inst.regField()) | inst.rexR(), .table = table };
}

/// The register an instruction writes as its ModRM `reg` operand or its
/// opcode's register, for the few forms `tableLoad`'s caller has to see
/// past; null when it writes no general register this way or is not
/// understood. Conservative use only: a caller that needs to know a
/// register was NOT written must not rely on it.
pub fn writesRegister(inst: Instruction) ?u4 {
    if (inst.map != .one) return null;
    return switch (inst.opcode) {
        0x8b, 0x8d, 0x63 => @as(u4, inst.regField()) | inst.rexR(),
        0xb8...0xbf => @as(u4, @intCast(inst.opcode & 7)) | inst.rexB(),
        else => null,
    };
}

const Reader = struct {
    code: []const u8,
    at: u8 = 0,

    fn next(r: *Reader) Error!u8 {
        if (r.at >= r.code.len) return error.Truncated;
        defer r.at += 1;
        return r.code[r.at];
    }

    fn peek(r: *Reader) Error!u8 {
        if (r.at >= r.code.len) return error.Truncated;
        return r.code[r.at];
    }

    /// A little-endian signed integer of `len` bytes, sign-extended.
    fn signed(r: *Reader, len: u8) Error!i64 {
        if (r.code.len - r.at < len) return error.Truncated;
        const bytes = r.code[r.at..][0..len];
        r.at += len;
        return switch (len) {
            0 => 0,
            1 => @as(i8, @bitCast(bytes[0])),
            2 => std.mem.readInt(i16, bytes[0..2], .little),
            3 => std.mem.readInt(u16, bytes[0..2], .little), // `enter`: never read as a value
            4 => std.mem.readInt(i32, bytes[0..4], .little),
            8 => std.mem.readInt(i64, bytes[0..8], .little),
            else => unreachable,
        };
    }
};

fn readModrm(r: *Reader, inst: *Instruction) Error!void {
    const modrm = try r.next();
    inst.modrm = modrm;
    const mod = modrm >> 6;
    const rm = modrm & 7;
    if (mod == 3) return;
    var base = rm;
    if (rm == 4) {
        const sib = try r.next();
        inst.sib = sib;
        base = sib & 7;
    }
    const disp_len: u8 = switch (mod) {
        0 => if (rm == 5 or (rm == 4 and base == 5)) 4 else 0,
        1 => 1,
        2 => 4,
        else => unreachable,
    };
    inst.disp = @intCast(try r.signed(disp_len));
}

/// The REX bits of a three-byte VEX or an EVEX prefix, whose R, X and B are
/// stored inverted.
fn vexRex(p0: u8, p1: u8) u8 {
    var rex: u8 = 0;
    if (p0 & 0x80 == 0) rex |= 4;
    if (p0 & 0x40 == 0) rex |= 2;
    if (p0 & 0x20 == 0) rex |= 1;
    if (p1 & 0x80 != 0) rex |= 8;
    return rex;
}

fn vexMap(number: u8) Error!Map {
    return switch (number) {
        1 => .@"0f",
        2 => .@"0f38",
        3 => .@"0f3a",
        5 => .evex5,
        6 => .evex6,
        else => error.Unsupported,
    };
}

/// A VEX or EVEX instruction's immediate: one byte in map `0F 3A`, and for
/// the shuffles, shifts and compares of map `0F` that take one.
fn vexImmediate(map: Map, opcode: u8) u8 {
    return switch (map) {
        .@"0f3a" => 1,
        .@"0f" => switch (opcode) {
            0x70...0x73, 0xc2, 0xc4, 0xc5, 0xc6 => 1,
            else => 0,
        },
        else => 0,
    };
}

/// The size of a `z` immediate: 16 bits under a `66` prefix, else 32.
fn zSize(inst: Instruction) u8 {
    return if (inst.operand_16) 2 else 4;
}

fn immediate1(inst: Instruction, address_32: bool) u8 {
    const op = inst.opcode;
    if (op < 0x40) return switch (op & 7) {
        4 => 1,
        5 => zSize(inst),
        else => 0,
    };
    return switch (op) {
        0x68, 0x69, 0x81, 0xa9, 0xc7 => zSize(inst),
        0x6a, 0x6b, 0x70...0x7f, 0x80, 0x83, 0xa8, 0xb0...0xb7, 0xc0, 0xc1, 0xc6, 0xcd, 0xe0...0xe7, 0xeb => 1,
        0xa0...0xa3 => if (address_32) 4 else 8,
        0xb8...0xbf => if (inst.rexW()) 8 else zSize(inst),
        0xc2, 0xca => 2,
        0xc8 => 3,
        // A near call or jump takes a 32-bit displacement in 64-bit mode
        // whatever the operand size.
        0xe8, 0xe9 => 4,
        0xf6 => if (inst.regField() <= 1) 1 else 0,
        0xf7 => if (inst.regField() <= 1) zSize(inst) else 0,
        else => 0,
    };
}

fn immediate0f(inst: Instruction) u8 {
    return switch (inst.opcode) {
        0x70...0x73, 0xa4, 0xac, 0xba, 0xc2, 0xc4, 0xc5, 0xc6, 0x0f => 1,
        0x80...0x8f => 4,
        // SSE4a's `extrq`/`insertq` with immediates: `66 0F 78 /0 ib ib`
        // and `F2 0F 78 /r ib ib`; plain `0F 78` is `vmread`, with none.
        0x78 => if (inst.operand_16) 2 else 0,
        else => 0,
    };
}

fn hasModrm0f(opcode: u8) bool {
    return modrm0f[opcode] != 2;
}

/// For each one-byte opcode: 0 no ModRM, 1 ModRM, 2 not an instruction in
/// 64-bit mode (prefixes and escapes never reach this table).
const modrm1: [256]u2 = table: {
    var t: [256]u2 = @splat(0);
    for (0..0x40) |op| {
        if (op & 7 < 4) t[op] = 1;
        if (op & 7 >= 6) t[op] = 2;
    }
    for ([_]u8{ 0x63, 0x69, 0x6b, 0xc0, 0xc1, 0xc6, 0xc7, 0xd0, 0xd1, 0xd2, 0xd3, 0xf6, 0xf7, 0xfe, 0xff }) |op| t[op] = 1;
    for (0x80..0x90) |op| t[op] = 1;
    for (0xd8..0xe0) |op| t[op] = 1;
    for ([_]u8{ 0x60, 0x61, 0x82, 0x9a, 0xce, 0xd4, 0xd5, 0xd6, 0xea }) |op| t[op] = 2;
    t[0x82] = 2;
    break :table t;
};

/// The same for the `0F` map.
const modrm0f: [256]u2 = table: {
    var t: [256]u2 = @splat(1);
    for ([_]u8{ 0x05, 0x06, 0x07, 0x08, 0x09, 0x0b, 0x0e, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x37, 0x77, 0xa0, 0xa1, 0xa2, 0xa8, 0xa9, 0xaa }) |op| t[op] = 0;
    for (0x80..0x90) |op| t[op] = 0;
    for (0xc8..0xd0) |op| t[op] = 0;
    for ([_]u8{ 0x04, 0x0a, 0x0c, 0x24, 0x25, 0x26, 0x27, 0x36, 0x39, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x7a, 0x7b }) |op| t[op] = 2;
    break :table t;
};

fn expectLength(expected: u8, bytes: []const u8) !void {
    const inst = try decode(bytes);
    try std.testing.expectEqual(expected, inst.len);
}

test "lengths of common encodings" {
    try expectLength(1, &.{0xc3}); // ret
    try expectLength(1, &.{0x55}); // push rbp
    try expectLength(3, &.{ 0x48, 0x89, 0xe5 }); // mov rbp, rsp
    try expectLength(4, &.{ 0x48, 0x83, 0xec, 0x10 }); // sub rsp, 16
    try expectLength(7, &.{ 0x48, 0x81, 0xec, 0x00, 0x01, 0x00, 0x00 }); // sub rsp, 256
    try expectLength(10, &.{ 0x48, 0xb8, 1, 2, 3, 4, 5, 6, 7, 8 }); // movabs rax, imm64
    try expectLength(5, &.{ 0xb8, 1, 0, 0, 0 }); // mov eax, 1
    try expectLength(4, &.{ 0x66, 0xb8, 1, 0 }); // mov ax, 1
    try expectLength(8, &.{ 0x48, 0x8b, 0x84, 0x24, 0x00, 0x01, 0x00, 0x00 }); // mov rax, [rsp+256]
    try expectLength(5, &.{ 0x48, 0x8b, 0x44, 0x24, 0x08 }); // mov rax, [rsp+8]
    try expectLength(7, &.{ 0x48, 0x8d, 0x05, 0, 0, 0, 0 }); // lea rax, [rip+0]
    try expectLength(7, &.{ 0x8b, 0x04, 0x25, 0, 0, 0, 0 }); // mov eax, [abs32]
    try expectLength(10, &.{ 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }); // nop word cs:[rax+rax]
    try expectLength(12, &.{ 0x48, 0xc7, 0x84, 0x24, 0x10, 0, 0, 0, 1, 0, 0, 0 }); // mov qword [rsp+16], 1
    try expectLength(3, &.{ 0x0f, 0xaf, 0xc1 }); // imul eax, ecx
    try expectLength(5, &.{ 0xc4, 0xe2, 0x79, 0x18, 0xc0 }); // vbroadcastss xmm0, xmm0
    try expectLength(3, &.{ 0xc5, 0xf8, 0x77 }); // vzeroupper
    try expectLength(6, &.{ 0xc4, 0xe3, 0x79, 0x0f, 0xc1, 0x04 }); // vpalignr xmm0, xmm0, xmm1, 4
    try expectLength(6, &.{ 0x62, 0xf1, 0x7c, 0x48, 0x28, 0xc1 }); // vmovaps zmm0, zmm1
    try expectLength(7, &.{ 0x62, 0xf1, 0x7c, 0x48, 0x28, 0x40, 0x01 }); // vmovaps zmm0, [rax+64]
    try expectLength(6, &.{ 0x66, 0x0f, 0x3a, 0x0f, 0xc1, 0x08 }); // palignr xmm0, xmm1, 8
    try expectLength(5, &.{ 0x66, 0x0f, 0x38, 0x00, 0xc1 }); // pshufb xmm0, xmm1
    try expectLength(3, &.{ 0xf6, 0xc1, 0x01 }); // test cl, 1
    try expectLength(2, &.{ 0xf7, 0xd8 }); // neg eax
    try expectLength(6, &.{ 0xf7, 0xc1, 1, 0, 0, 0 }); // test ecx, 1
    try expectLength(2, &.{ 0x0f, 0x0b }); // ud2
    try expectLength(4, &.{ 0xf0, 0x0f, 0xb1, 0x0a }); // lock cmpxchg [rdx], ecx
}

test "a truncated or unknown encoding is an error, not a guess" {
    try std.testing.expectError(error.Truncated, decode(&.{ 0xe8, 0, 0 }));
    try std.testing.expectError(error.Truncated, decode(&.{0x48}));
    try std.testing.expectError(error.Unsupported, decode(&.{ 0x06, 0x90 }));
    try std.testing.expectError(error.Unsupported, decode(&.{ 0x8f, 0xe8, 0x78, 0xc2, 0xc1, 0x01 }));
}

test "branches, jumps, calls and returns" {
    const at = 0x1000;
    // jne +0x10 (rel8)
    try std.testing.expectEqual(Flow{ .branch = at + 2 + 0x10 }, flow(try decode(&.{ 0x75, 0x10 }), at));
    // je -2 (rel32): a loop onto itself
    try std.testing.expectEqual(Flow{ .branch = at + 6 - 8 }, flow(try decode(&.{ 0x0f, 0x84, 0xf8, 0xff, 0xff, 0xff }), at));
    try std.testing.expectEqual(Flow{ .jump = at + 5 + 0x100 }, flow(try decode(&.{ 0xe9, 0x00, 0x01, 0, 0 }), at));
    try std.testing.expectEqual(Flow{ .jump = at + 2 - 2 }, flow(try decode(&.{ 0xeb, 0xfe }), at));
    try std.testing.expectEqual(Flow.ret, flow(try decode(&.{0xc3}), at));
    try std.testing.expectEqual(Flow.trap, flow(try decode(&.{ 0x0f, 0x0b }), at));
    try std.testing.expectEqual(Flow.trap, flow(try decode(&.{0xcc}), at));
    try std.testing.expectEqual(Flow.jump_indirect, flow(try decode(&.{ 0xff, 0xe0 }), at)); // jmp rax
    try std.testing.expectEqual(Flow.next, flow(try decode(&.{ 0xff, 0xd0 }), at)); // call rax
    const call = try decode(&.{ 0xe8, 0x10, 0, 0, 0 });
    try std.testing.expectEqual(Flow.next, flow(call, at));
    try std.testing.expectEqual(@as(?u64, at + 5 + 0x10), callTarget(call, at));
}

test "the loads of a guard's address into rdi" {
    const at = 0x2000;
    try std.testing.expectEqual(@as(?u64, 0x1234568), rdiConstant(try decode(&.{ 0xbf, 0x68, 0x45, 0x23, 0x01 }), at));
    try std.testing.expectEqual(@as(?u64, 0x1234568), rdiConstant(try decode(&.{ 0x48, 0xc7, 0xc7, 0x68, 0x45, 0x23, 0x01 }), at));
    try std.testing.expectEqual(@as(?u64, at + 7 + 0x100), rdiConstant(try decode(&.{ 0x48, 0x8d, 0x3d, 0x00, 0x01, 0, 0 }), at));
    // mov esi, imm32 and lea r15, [rip] load other registers.
    try std.testing.expectEqual(@as(?u64, null), rdiConstant(try decode(&.{ 0xbe, 0x68, 0x45, 0x23, 0x01 }), at));
    try std.testing.expectEqual(@as(?u64, null), rdiConstant(try decode(&.{ 0x4c, 0x8d, 0x3d, 0x00, 0x01, 0, 0 }), at));
}

test "indirect jumps: through a table, a register, a GOT slot or a pointer" {
    const expect = std.testing.expectEqual;
    // jmp [0x401000 + rax*8]
    try expect(IndirectJump{ .table = 0x401000 }, indirectJump(try decode(&.{ 0xff, 0x24, 0xc5, 0x00, 0x10, 0x40, 0x00 })).?);
    // jmp [rax + 0x100b8c0]: an index already scaled into rax.
    try expect(IndirectJump{ .table = 0x100b8c0 }, indirectJump(try decode(&.{ 0xff, 0xa0, 0xc0, 0xb8, 0x00, 0x01 })).?);
    // jmp [rip + 0x10]
    try expect(IndirectJump.rip_slot, indirectJump(try decode(&.{ 0xff, 0x25, 0x10, 0x00, 0x00, 0x00 })).?);
    // jmp [rax + 0x18] and jmp [rax + rcx*8]: pointers read out of memory.
    try expect(IndirectJump.other, indirectJump(try decode(&.{ 0xff, 0x60, 0x18 })).?);
    try expect(IndirectJump.other, indirectJump(try decode(&.{ 0xff, 0x24, 0xc8 })).?);
    // jmp rcx and jmp r9
    try expect(IndirectJump{ .register = 1 }, indirectJump(try decode(&.{ 0xff, 0xe1 })).?);
    try expect(IndirectJump{ .register = 9 }, indirectJump(try decode(&.{ 0x41, 0xff, 0xe1 })).?);
    // call rax is not a jump.
    try expect(@as(?IndirectJump, null), indirectJump(try decode(&.{ 0xff, 0xd0 })));
}

test "the load of a jump table's entry into a register" {
    // mov rcx, [0x401000 + rax*8]
    const load = tableLoad(try decode(&.{ 0x48, 0x8b, 0x0c, 0xc5, 0x00, 0x10, 0x40, 0x00 })).?;
    try std.testing.expectEqual(@as(u4, 1), load.register);
    try std.testing.expectEqual(@as(u64, 0x401000), load.table);
    // mov r9, [0x401000 + rax*8]
    try std.testing.expectEqual(@as(u4, 9), tableLoad(try decode(&.{ 0x4c, 0x8b, 0x0c, 0xc5, 0x00, 0x10, 0x40, 0x00 })).?.register);
    // mov rcx, [rax + 8]: a field, not a table.
    try std.testing.expectEqual(null, tableLoad(try decode(&.{ 0x48, 0x8b, 0x48, 0x08 })));
}
