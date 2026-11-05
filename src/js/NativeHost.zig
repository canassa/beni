// ownership pin begin: host_append
// ownership pin begin: host_asAnchor
// ownership pin begin: host_asElement
// ownership pin begin: host_asForm
// ownership pin begin: host_asInput
// ownership pin begin: host_asNode
// ownership pin begin: host_asOption
// ownership pin begin: host_asSelect
// ownership pin begin: host_asTextArea
// ownership pin begin: host_code
// ownership pin begin: host_dataOnly
// ownership pin begin: host_error
// ownership pin begin: host_errorMessage
// ownership pin begin: host_querySelector
// ownership pin begin: host_getAttribute
// ownership pin begin: host_get
// ownership pin begin: host_group
// ownership pin begin: host_init
// ownership pin begin: host_key
// ownership pin begin: host_onText
// ownership pin begin: host_post
// ownership pin begin: host_reader
// ownership pin begin: host_selectionDirection
// ownership pin begin: host_selectionEnd
// ownership pin begin: host_selectionStart
// ownership pin begin: host_set
// ownership pin begin: host_setSelectionRange
// ownership pin begin: host_setValue
// ownership pin begin: host_target
// ownership pin begin: host_typeErrorMessage
// ownership pin begin: host_value
//! Inline the typed boundary of reviewed generated host operations. Siblings
//! return host values; only the compiler knows Opt's sentinel and escape chain.
const std = @import("std");
const Ir = @import("JsIr.zig");
const Inst = @import("../bir/Bir.zig").Inst;
const Operations = @import("../native/Operations.zig");
const HostValues = @import("../native/HostValues.zig");
const N = Ir.Node.Index;
const List = std.ArrayList(N);
const E = std.mem.Allocator.Error;

pub fn emit(l: anytype, out: *List, row: Operations.Row, callee: ?N, values: []N, sources: []const Inst.Index, p: u32) E!N {
    const adapter = HostValues.get(row.recipe).?;
    const none = try l.optNone(p);
    const undef = try l.add(.undefined_lit, p, Ir.Node.Data.unused, Ir.Node.Data.unused);
    const global = try l.add(.global_this, p, Ir.Node.Data.unused, Ir.Node.Data.unused);
    // Each raw input's payload is a native handle or String, never a nested Opt.
    const optional_input: ?usize = switch (row.recipe) {
        .fetch_init => 2,
        .cf_responseCreate => 1,
        .cf_stubRpc => 3,
        else => null,
    };
    if (optional_input) |i| values[i] = try l.condOf(try l.binary(.strict_eq, values[i], none, p), if (row.recipe == .fetch_init) undef else try l.nullNode(p), values[i], p);
    if (row.recipe == .ws_message) values[1] = try messageListener(l, try l.nativeCallbackValue(out, sources[1], values[1], p), sources[1], none, p);
    if (row.recipe == .cf_instance) {
        values[2] = try rpcListener(l, try l.nativeCallbackValue(out, sources[2], values[2], p), sources[2], none, p);
        values[3] = try socketListener(l, try l.nativeCallbackValue(out, sources[3], values[3], p), sources[3], none, p);
    }
    const result = if (callee) |function| try l.call(function, values, p) else try directCall(l, row.recipe, values, p);
    if (adapter.mode == .passthrough) return result;
    const name = try l.fresh(l.well.temp);
    try l.constDecl(out, name, result, p);
    const value = try l.ident(name, p);
    const nullish = try l.binary(.logical_or, try l.binary(.strict_eq, value, try l.nullNode(p), p), try l.binary(.strict_eq, value, undef, p), p);
    return switch (adapter.mode) {
        .passthrough => unreachable,
        .null_value => l.condOf(try l.binary(.strict_eq, value, try l.nullNode(p), p), none, value, p),
        .undefined_value => l.condOf(try l.binary(.strict_eq, value, undef, p), none, value, p),
        .nullish => l.condOf(nullish, none, value, p),
        .unit_result => l.condOf(try l.binary(.strict_eq, value, try l.nullNode(p), p), value, none, p),
        .syntax_result => l.condOf(try l.binary(.instance_of, value, try l.member(global, try l.interner.getOrPut(l.gpa, "SyntaxError"), p), p), none, value, p),
        .checked_data => l.condOf(try l.binary(.strict_eq, value, try l.member(global, try l.interner.getOrPut(l.gpa, "Symbol"), p), p), none, value, p),
        .query_result => blk: {
            const absent = try l.call(try l.optCoreValue("some", p), &.{none}, p);
            const selected = try l.condOf(try l.binary(.strict_eq, value, try l.nullNode(p), p), absent, value, p);
            break :blk l.condOf(try l.binary(.instance_of, value, try l.member(global, try l.interner.getOrPut(l.gpa, "DOMException"), p), p), none, selected, p);
        },
        .worker_result => blk: {
            const absent = try l.call(try l.optCoreValue("some", p), &.{none}, p);
            const invalid = try l.call(try l.optCoreValue("some", p), &.{absent}, p);
            const error_name = try l.member(value, try l.interner.getOrPut(l.gpa, "name"), p);
            const dom = try l.binary(.instance_of, value, try l.member(global, try l.interner.getOrPut(l.gpa, "DOMException"), p), p);
            const syntax = try l.binary(.logical_and, dom, try l.binary(.strict_eq, error_name, try l.stringNode("SyntaxError", p), p), p);
            const security = try l.binary(.logical_and, dom, try l.binary(.strict_eq, error_name, try l.stringNode("SecurityError", p), p), p);
            const type_error = try l.binary(.instance_of, value, try l.member(global, try l.interner.getOrPut(l.gpa, "TypeError"), p), p);
            const failure = try l.condOf(syntax, none, try l.condOf(security, absent, invalid, p), p);
            // The sibling catches only documented failures. A constructor
            // wrapper can return a real Worker outside its own prototype chain.
            const failed = try l.binary(.logical_or, syntax, try l.binary(.logical_or, security, type_error, p), p);
            break :blk l.condOf(failed, failure, value, p);
        },
    };
}

fn textSlot(l: anytype, value: N, none: N, p: u32) E!N {
    return l.condOf(try l.binary(.strict_eq, try l.unary(.type_of, value, p), try l.stringNode("string", p), p), value, none, p);
}

fn messageListener(l: anytype, callback: N, source: Inst.Index, none: N, p: u32) E!N {
    const name = try l.fresh(l.well.temp);
    const event = try l.ident(name, p);
    const data_name = try l.fresh(l.well.temp);
    var body: List = .empty;
    try l.constDecl(&body, data_name, try l.member(event, try l.interner.getOrPut(l.gpa, "data"), p), p);
    try body.append(l.scratch, try l.returnStmt(try l.nativePayloadCallback(&body, source, callback, &.{try textSlot(l, try l.ident(data_name, p), none, p)}, p), p));
    return l.arrowOf(&.{name}, body.items, p);
}

fn rpcListener(l: anytype, callback: N, source: Inst.Index, none: N, p: u32) E!N {
    var names: [4]Ir.NameIndex = undefined;
    var args: [4]N = undefined;
    for (&names, &args) |*name, *arg| {
        name.* = try l.fresh(l.well.temp);
        arg.* = try l.ident(name.*, p);
    }
    for ([_]usize{ 0, 2 }) |i| args[i] = try l.condOf(try l.binary(.loose_eq, args[i], try l.nullNode(p), p), none, args[i], p);
    var body: List = .empty;
    const result = try l.nativePayloadCallback(&body, source, callback, &args, p);
    try body.append(l.scratch, try l.returnStmt(result, p));
    return l.arrowOf(&names, body.items, p);
}

fn socketListener(l: anytype, callback: N, source: Inst.Index, none: N, p: u32) E!N {
    const socket_name = try l.fresh(l.well.temp);
    const value_name = try l.fresh(l.well.temp);
    var body: List = .empty;
    const result = try l.nativePayloadCallback(&body, source, callback, &.{ try l.ident(socket_name, p), try textSlot(l, try l.ident(value_name, p), none, p) }, p);
    try body.append(l.scratch, try l.returnStmt(result, p));
    return l.arrowOf(&.{ socket_name, value_name }, body.items, p);
}

pub fn direct(recipe: Operations.Recipe) bool {
    return switch (recipe) {
        .event_target, .input_selectionStart, .input_selectionEnd, .input_selectionDirection, .document_active, .document_body, .event_error, .read_result_value, .text_content, .headers_get, .element_get_attribute, .storage_get, .storage_key, .cf_idName, .cf_requestSignal, .cf_kv, .cf_kvGet, .document_by_id, .map_get, .key_map_get => true,
        else => false,
    };
}

fn directCall(l: anytype, recipe: Operations.Recipe, values: []const N, p: u32) E!N {
    const property: ?[]const u8 = switch (recipe) {
        .event_target => "target",
        .input_selectionStart => "selectionStart",
        .input_selectionEnd => "selectionEnd",
        .input_selectionDirection => "selectionDirection",
        .event_error => "error",
        .read_result_value => "value",
        .text_content => "textContent",
        .cf_idName => "name",
        .cf_requestSignal => "signal",
        else => null,
    };
    if (property) |name| return l.member(values[0], try l.interner.getOrPut(l.gpa, name), p);
    if (recipe == .cf_kv) return l.member(try l.member(values[0], try l.interner.getOrPut(l.gpa, "storage"), p), try l.interner.getOrPut(l.gpa, "kv"), p);
    if (recipe == .document_active or recipe == .document_body or recipe == .document_by_id) {
        const global = try l.add(.global_this, p, Ir.Node.Data.unused, Ir.Node.Data.unused);
        const document = try l.member(global, try l.interner.getOrPut(l.gpa, "document"), p);
        if (recipe == .document_by_id) return l.call(try l.member(document, try l.interner.getOrPut(l.gpa, "getElementById"), p), &.{values[0]}, p);
        return l.member(document, try l.interner.getOrPut(l.gpa, if (recipe == .document_body) "body" else "activeElement"), p);
    }
    const method = switch (recipe) {
        .headers_get, .cf_kvGet, .map_get, .key_map_get => "get",
        .element_get_attribute => "getAttribute",
        .storage_get => "getItem",
        .storage_key => "key",
        else => unreachable,
    };
    return l.call(try l.member(values[0], try l.interner.getOrPut(l.gpa, method), p), values[1..], p);
}

pub fn payloadCallback(recipe: Operations.Recipe, index: usize) bool {
    return switch (recipe) {
        .ws_message => index == 1,
        .cf_instance => index == 2 or index == 3,
        else => false,
    };
}

// ownership pin end: host_append
// ownership pin end: host_asAnchor
// ownership pin end: host_asElement
// ownership pin end: host_asForm
// ownership pin end: host_asInput
// ownership pin end: host_asNode
// ownership pin end: host_asOption
// ownership pin end: host_asSelect
// ownership pin end: host_asTextArea
// ownership pin end: host_code
// ownership pin end: host_dataOnly
// ownership pin end: host_error
// ownership pin end: host_errorMessage
// ownership pin end: host_get
// ownership pin end: host_getAttribute
// ownership pin end: host_querySelector
// ownership pin end: host_group
// ownership pin end: host_init
// ownership pin end: host_key
// ownership pin end: host_onText
// ownership pin end: host_post
// ownership pin end: host_reader
// ownership pin end: host_selectionDirection
// ownership pin end: host_selectionEnd
// ownership pin end: host_selectionStart
// ownership pin end: host_set
// ownership pin end: host_setSelectionRange
// ownership pin end: host_setValue
// ownership pin end: host_target
// ownership pin end: host_typeErrorMessage
// ownership pin end: host_value
