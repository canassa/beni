//! The union of the six languages' reserved words (docs/design/compare-bench.md
//! §2.4). Every generated name is a letter followed by digits, or one of
//! Base's fixed names, so none can be one of these; the oracle and a unit
//! test check it anyway.

const std = @import("std");

pub const keywords = [_][]const u8{
    // beni (language.md §2.3)
    "if",       "then",       "else",         "case",      "of",        "let",       "in",        "type",       "alias",
    "pub",      "opaque",     "import",       "as",        "exposing",  "foreign",
    // Elm
      "module",    "port",       "where",
    "effect",   "command",    "subscription",
    // Gleam
    "assert",    "auto",      "const",     "delegate",  "derive",     "echo",
    "fn",       "implement",  "macro",        "panic",     "test",      "todo",      "use",
    // Roc
          "when",       "is",
    "expect",   "dbg",        "crash",        "return",    "break",     "for",       "var",       "while",      "and",
    "or",       "not",        "match",        "interface", "app",       "package",   "platform",  "provides",   "requires",
    "exposes",  "imports",    "with",         "generates",
    // PureScript
    "ado",       "class",     "data",      "derive",     "do",
    "forall",   "foreign",    "hiding",       "infix",     "infixl",    "infixr",    "instance",  "newtype",    "qualified",
    "role",
    // TypeScript (strict mode included)
        "break",      "catch",        "continue",  "debugger",  "default",   "delete",    "enum",       "export",
    "extends",  "false",      "finally",      "function",  "new",       "null",      "super",     "switch",     "this",
    "throw",    "true",       "try",          "typeof",    "void",      "with",      "yield",     "implements", "package",
    "private",  "protected",  "public",       "static",    "interface", "await",     "any",       "boolean",    "number",
    "string",   "symbol",     "unknown",      "never",     "object",    "undefined", "arguments", "eval",       "keyof",
    "readonly", "infer",      "asserts",      "satisfies", "declare",   "abstract",  "namespace", "require",    "global",
    "accessor", "async",      "constructor",  "get",       "set",       "from",      "of",        "out",        "override",
    "unique",   "bigint",     "is",           "module",    "type",      "var",       "let",       "const",      "enum",
    "in",       "instanceof", "new",          "return",    "case",      "do",        "for",       "if",         "else",
    "while",    "class",
};

pub fn isKeyword(name: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

test "generated name shapes are outside every keyword list" {
    // Every name the generator makes is one of these shapes: a letter and
    // digits (f1003012, v12, T100302, C100302x7, a0 ... in type variables),
    // or one of Base's and the entry points' fixed names.
    const fixed = [_][]const u8{
        "Base", "Seq",  "Opt",     "Res",   "SNil",    "SCons", "ONone", "OSome", "RErr",   "ROk",
        "slen", "smap", "sfilter", "sfold", "sappend", "srev",  "stake", "sany",  "shead",  "ssingle",
        "omap", "rmap", "pfst",    "psnd",  "pswap",   "entry", "total", "Main",  "absurd", "a",
        "b",    "c",    "d",       "main",  "compare",
    };
    for (fixed) |n| try std.testing.expect(!isKeyword(n));
    const prefixes = "fvTCmxa";
    for (prefixes) |p| {
        var buf: [8]u8 = undefined;
        for (0..100) |i| {
            const n = try std.fmt.bufPrint(&buf, "{c}{d}", .{ p, i });
            try std.testing.expect(!isKeyword(n));
        }
    }
}
