//! Private browser-worker storage and control frames. Both projections and
//! the startup reporter use this table; user values and native APIs do not.
const std = @import("std");

// Bump when the prescribed representation changes; fingerprints include it.
pub const version = "private-worker-encoding-3";

const Field = struct { source: []const u8, encoded: []const u8 };
// Deliberately exclude public Options fields, descriptor keys, diagnostic
// payloads and native properties. `kind` also names a public abandonment
// diagnostic field, so its spelling is deliberately retained everywhere.
// Transport headers and Hello/Defect labels stay stable across builds so
// fingerprint negotiation precedes layout-specific interpretation.
// These encoded names belong only to runtime storage.
const fields = [_]Field{
    .{ .source = "phase", .encoded = "g" },
    .{ .source = "terminal", .encoded = "h" },
    .{ .source = "eventCount", .encoded = "evCount" },
    .{ .source = "eventBytes", .encoded = "j" },
    .{ .source = "eventLimit", .encoded = "k" },
    .{ .source = "byteLimit", .encoded = "l" },
    .{ .source = "greeting", .encoded = "m" },
    .{ .source = "greetingWake", .encoded = "n" },
    .{ .source = "closedWaiters", .encoded = "o" },
    .{ .source = "startup", .encoded = "p" },
    .{ .source = "listeners", .encoded = "q" },
    .{ .source = "requests", .encoded = "r" },
    .{ .source = "events", .encoded = "s" },
    .{ .source = "native", .encoded = "t" },
    .{ .source = "interrupted", .encoded = "u" },
    .{ .source = "wire", .encoded = "w" },
    .{ .source = "queue", .encoded = "e" },
    .{ .source = "next", .encoded = "i" },
    .{ .source = "failure", .encoded = "v" },
    .{ .source = "ready", .encoded = "y" },
    .{ .source = "opening", .encoded = "z" },
    .{ .source = "owned", .encoded = "A" },
    .{ .source = "alive", .encoded = "B" },
    .{ .source = "bytes", .encoded = "C" },
    .{ .source = "result", .encoded = "D" },
    .{ .source = "wake", .encoded = "E" },
    .{ .source = "peer", .encoded = "F" },
};

/// Prescribed keys share typed records with normally renamed fields. Their
/// output spellings cannot be colours for those other fields (#1803).
pub fn reserveFields(arena: std.mem.Allocator, reserved: *std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    for (fields) |entry| try reserved.put(arena, entry.encoded, {});
}

pub fn field(source: []const u8) []const u8 {
    for (fields) |entry| if (std.mem.eql(u8, entry.source, source)) return entry.encoded;
    return source;
}

const Tag = struct { source: []const u8, encoded: u8 };
const tags = [_]Tag{
    .{ .source = "Ready", .encoded = 1 },
    .{ .source = "InitializationFailed", .encoded = 2 },
    .{ .source = "Closed", .encoded = 3 },
    .{ .source = "Close", .encoded = 4 },
    .{ .source = "Request", .encoded = 5 },
    .{ .source = "Interrupt", .encoded = 6 },
    .{ .source = "EventAck", .encoded = 7 },
    .{ .source = "Ping", .encoded = 8 },
    .{ .source = "Pong", .encoded = 9 },
    .{ .source = "TransportFailure", .encoded = 10 },
    .{ .source = "Success", .encoded = 12 },
    .{ .source = "Failure", .encoded = 13 },
    .{ .source = "Event", .encoded = 14 },
    .{ .source = "Starting", .encoded = 15 },
    .{ .source = "Closing", .encoded = 16 },
    .{ .source = "Lost", .encoded = 17 },
    .{ .source = "Transport", .encoded = 18 },
    .{ .source = "Abandoned", .encoded = 19 },
};

pub fn tag(source: []const u8) ?u8 {
    for (tags) |entry| if (std.mem.eql(u8, entry.source, source)) return entry.encoded;
    return null;
}
