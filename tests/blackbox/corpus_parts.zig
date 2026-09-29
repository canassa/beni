//! The parts `test-blackbox` splits the corpus walker into
//! (`plans/checker-rewrite.md` §2.4, *Parts*). ONE list, read by both sides:
//! `build.zig` imports this file and adds one run of `corpus_test.zig` per
//! part, with `BENI_CORPUS_PART=<tag>`, so the parts run as separate
//! processes in parallel; `corpus_test.zig` maps every kind — and each of
//! `run/`'s two passes — to exactly one part with an exhaustive switch
//! (`partOf`). A kind cannot be left out of every run and a part cannot be
//! added without a run: either is a compile error or a new process, never a
//! silent loss of coverage.
//!
//! An unset or empty `BENI_CORPUS_PART` is every part, in one process: what
//! a hand run of the walker and `test-pending` get.
//!
//! The grouping is by measured wall time; inside a part the walker spreads
//! its cases over a pool of workers.
//! Imports nothing, because `build.zig` imports it.

pub const Part = enum {
    /// `parse/good`, `parse/bad`, `fmt`, `bir`, `regress`.
    parse,
    /// `check/good`, `check/bad`, `check/args`, `check/depth`, `dispatch`.
    check,
    /// `build/bad`, `build/bad-release`, `emit` (with `emit/app/` and
    /// `emit/release/`).
    build,
    /// `run/`'s development pass: build, run, compare with `.expected`.
    run_dev,
    /// `run/`'s `--release --allow-debug` pass, against `.release-expected`
    /// or `.expected` (`backend.md` §9's *Testing*).
    run_release,
    /// `browser/`: both builds of each fixture, each loaded into a page.
    browser,
};
