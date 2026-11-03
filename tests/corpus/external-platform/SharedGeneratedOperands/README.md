# Shared generated operands (#1782)

Driven by `typed lowering closes generic operand packets with checked source evidence`
in `tests/blackbox/external_platform_test.zig`, against the compiler carrying
`tests/platforms/toy`'s `typed-toy` lowering. The scenario supplies the custom
core module used by `Probe.data` and checks the emitted program in development
(cold and warm) and release.

The lowering uses one generated `sample` call in the capture packet and the
checked-data call, and one `first` call in the presence test and payload read.
Rewriting a shared call must update every occurrence in the cached name scan.
The ordinary `run/` compiler does not carry this external lowering.
