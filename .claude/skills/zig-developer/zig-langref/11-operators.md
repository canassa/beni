# Operators


There is no operator overloading. When you see an operator in Zig, you know that it is doing something from this table, and nothing else.

### [Table of Operators](#toc-Table-of-Operators) [§](#Table-of-Operators)

[TABLE]

### [Precedence](#toc-Precedence) [§](#Precedence)

    x() x[] x.y x.* x.?
    a!b
    x{}
    !x -x -%x ~x &x ?x
    * / % ** *% *| ||
    + - ++ +% -% +| -|
    << >> <<|
    & ^ | orelse catch
    == != < > <= >=
    and
    or
    = *= *%= *|= /= %= += +%= +|= -= -%= -|= <<= <<|= >>= &= ^= |=

