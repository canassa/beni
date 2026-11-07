# A shared call whose replacement is another call (#2178, #1782)

Driven by `a shared generated call is rewritten once when its replacement is a call`
in `tests/blackbox/external_platform_test.zig`, with the toy compiler.

`shared-toy` builds one `Probe.flip("left", "right")` expression and puts it
on both sides of a separator. The Beni wrapper becomes a foreign `combine`
call with the arguments reversed. Every occurrence evaluates separately,
and both builds must print `rightleft/rightleft`. Applying the old wrapper's
body to a second pending occurrence would reverse the arguments again.
