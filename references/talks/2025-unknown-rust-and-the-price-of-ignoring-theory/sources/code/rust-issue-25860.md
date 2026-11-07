# Implied bounds on nested references + variance = soundness hole

URL: https://github.com/rust-lang/rust/issues/25860
State: open
Opened: 2015-05-28T17:37:18Z
Author: aturon
Retrieved: 2026-11-02

<!-- homu-ignore:start -->
*[View all comments](https://triagebot.infra.rust-lang.org/gh-comments/rust-lang/rust/issues/25860)*
<!-- homu-ignore:end -->

The combination of variance and implied bounds for nested references opens a hole in the current type system:

``` rust
static UNIT: &'static &'static () = &&();

fn foo<'a, 'b, T>(_: &'a &'b (), v: &'b T) -> &'a T { v }

fn bad<'a, T>(x: &'a T) -> &'static T {
    let f: fn(&'static &'a (), &'a T) -> &'static T = foo;
    f(UNIT, x)
}
```

This hole has been fixed in #129021 for non-higher-ranked function pointers. The underlying issue still persists.
```rust
static UNIT: &'static &'static () = &&();

fn foo<'a, 'b, T>(_: &'a &'b (), v: &'b T, _: &()) -> &'a T { v }

fn bad<'a, T>(x: &'a T) -> &'static T {
    let f: fn(_, &'a T, &()) -> &'static T = foo;
    f(UNIT, x, &())
}

fn main() {}
```
