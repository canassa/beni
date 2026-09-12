# Integers


### [Integer Literals](#toc-Integer-Literals) [§](#Integer-Literals)

    const decimal_int = 98222;
    const hex_int = 0xff;
    const another_hex_int = 0xFF;
    const octal_int = 0o755;
    const binary_int = 0b11110000;

    // underscores may be placed between two digits as a visual separator
    const one_billion = 1_000_000_000;
    const binary_mask = 0b1_1111_1111;
    const permissions = 0o7_5_5;
    const big_address = 0xFF80_0000_0000_0000;

integer_literals.zig

### [Runtime Integer Values](#toc-Runtime-Integer-Values) [§](#Runtime-Integer-Values)

Integer literals have no size limitation, and if any Illegal Behavior occurs, the compiler catches it.

However, once an integer value is no longer known at compile-time, it must have a known size, and is vulnerable to safety-checked [Illegal Behavior](#Illegal-Behavior).

    fn divide(a: i32, b: i32) i32 {
        return a / b;
    }

runtime_vs_comptime.zig

In this function, values `a` and `b` are known only at runtime, and thus this division operation is vulnerable to both [Integer Overflow](#Integer-Overflow) and [Division by Zero](#Division-by-Zero).

Operators such as `+` and `-` cause [Illegal Behavior](#Illegal-Behavior) on integer overflow. Alternative operators are provided for wrapping and saturating arithmetic on all targets. `+%` and `-%` perform wrapping arithmetic while `+|` and `-|` perform saturating arithmetic.

Zig supports arbitrary bit-width integers, referenced by using an identifier of `i` or `u` followed by digits. For example, the identifier `i7` refers to a signed 7-bit integer. The maximum allowed bit-width of an integer type is `65535`. For signed integer types, Zig uses a [two's complement](https://en.wikipedia.org/wiki/Two's_complement) representation.

See also:

- [Wrapping Operations](#Wrapping-Operations)

