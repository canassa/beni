## 2026-10-22 23:14 UTC — check an object's tick sync at define

**What I did**

- Cesar answered `cf-workers-q9`: neither a load-time check nor `Js.maySuspend`. `define`'s
  annotation writes the handler record out with `tick : sync (state → Maybe Duration)` inside
  it, as `Browser.program`'s record marks `update` and `view`; `Handlers` stays the alias.
- Tested the reduced case first with the edited platform from disk (`--platform=<dir>`): a
  `define` whose `request` sleeps and whose `tick` does not is accepted; one whose `tick`
  calls a sleeping function is refused with `sync_boundary`; both as `{ Object.none | … }`. The
  demand survives the record update. The span is the update's `{`, not the field's value.
- The refusal is the fixture `build/bad/workers/ObjectTickWaits`; the harness gains the
  `build/bad/workers/` group, built for `cloudflare`, since a `workers/` fixture must build.
  §9.12 (e.5) carries the dated amendment that closes q9; the skill says `tick` must not wait.

**What I learned**

- A `sync` mark on a record field of a platform declaration's argument reaches a call that
  builds the record by update syntax: the checker attributes the field's demand through
  `{ r | f = v }`. Only the span is coarser than a literal's.
- `beni check --platform=<directory>` reads an edited platform from disk, so a signature change
  can be tried without a rebuild of the binary.
