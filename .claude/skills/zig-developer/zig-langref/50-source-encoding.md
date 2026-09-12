# Source Encoding


Zig source code is encoded in UTF-8. An invalid UTF-8 byte sequence results in a compile error.

Throughout all zig source code (including in comments), some code points are never allowed:

- Ascii control characters, except for U+000a (LF), U+000d (CR), and U+0009 (HT): U+0000 - U+0008, U+000b - U+000c, U+000e - U+0001f, U+007f.
- Non-Ascii Unicode line endings: U+0085 (NEL), U+2028 (LS), U+2029 (PS).

LF (byte value 0x0a, code point U+000a, `'\n'`) is the line terminator in Zig source code. This byte value terminates every line of zig source code except the last line of the file. It is recommended that non-empty source files end with an empty line, which means the last byte would be 0x0a (LF).

Each LF may be immediately preceded by a single CR (byte value 0x0d, code point U+000d, `'\r'`) to form a Windows style line ending, but this is discouraged. Note that in multiline strings, CRLF sequences will be encoded as LF when compiled into a zig program. A CR in any other context is not allowed.

HT hard tabs (byte value 0x09, code point U+0009, `'\t'`) are interchangeable with SP spaces (byte value 0x20, code point U+0020, `' '`) as a token separator, but use of hard tabs is discouraged. See [Grammar](#Grammar).

For compatibility with other tools, the compiler ignores a UTF-8-encoded byte order mark (U+FEFF) if it is the first Unicode code point in the source text. A byte order mark is not allowed anywhere else in the source.

Note that running zig fmt on a source file will implement all recommendations mentioned here.

Note that a tool reading Zig source code can make assumptions if the source code is assumed to be correct Zig code. For example, when identifying the ends of lines, a tool can use a naive search such as `/\n/`, or an [advanced](https://msdn.microsoft.com/en-us/library/dd409797.aspx) search such as `/\r\n?|[\n\u0085\u2028\u2029]/`, and in either case line endings will be correctly identified. For another example, when identifying the whitespace before the first token on a line, a tool can either use a naive search such as `/[ \t]/`, or an [advanced](https://tc39.es/ecma262/#sec-characterclassescape) search such as `/\s/`, and in either case whitespace will be correctly identified.

