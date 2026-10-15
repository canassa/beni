## 2026-10-15 08:55 CEST — a page build makes its edge lists once and prints once

**What I did**

Measured where a development build's instructions go on master, per
module, with a per-thread counter and with callgrind. On
`browser/tea/ApiItems` (629 million): the edge lists of all 28 modules
were built two times (62 million each time; a walk is 1.5 million), the
first lowering of the nine modules that are not core or the runtime
module cost 51 million and its bytes were thrown away, and the final
lowering, printing and source maps of core and the platforms cost 235
million. On `run/Dictionaries` (180 million) the edge lists are 32
million and core's emit 32 million. Then made the second walk read the
first walk's edge lists, and made a first lowering that leaves a module
out stop before printing. Added the `--self-profile` counters
`edge_lists`, `reach_walks`, `modules_lowered` and `modules_printed`, a
black-box test that is red without each half of the change, and dated
amendments to `backend.md` §9 and §15.1. Asked the owner where the cache
of embedded emit work lives: Jayson chose the maker of the checked core,
edge lists first; recorded in `fast-compiler.md` §8.

**What I learned**

`ApiItems` goes 629 → 545 million (−13.5 %) in development and
1 818 → 1 756 under `--release`; `browser/direct/AfterRenderFocus`
584 → 489 (−16.2 %) and 716 → 652. A `node` program has no runtime
module and does not change. Every run hash matched, so no output moved.
The first lowering can not yet be kept for the second: its own live bits
equal the second walk's on every page I looked at, but the safety wall
checks its references against the coarse set, and a reuse would hide a
missing edge into the runtime module.
