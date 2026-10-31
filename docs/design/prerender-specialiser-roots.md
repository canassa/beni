# Prerender specialiser roots

2026-10-30. Implementation correction to backend §9 and prerender §4/§6.

The release specialiser models the entry file that will actually execute. Ordinary
page entries retain the existing `run(main)` call, including its argument flow.
A prerender-pre entry instead exports values for the build's external renderer:
without data, `render = main[0]` and `routes = main[1]`; with data, `render = main`.
It does not call the page runtime's `run`.

`Spec.Input` records external numeric-index exports separately from whole-value
escapes and the ordinary entry call. Their base globals remain declaration roots;
only the results of the stated index reads escape. The points-to solver applies
its existing numeric-index read transfer (`readAll`) each sweep, then escapes the
result. This transfer currently merges array elements, as ordinary `index_get`
does; this adds no new precision claim. It does not escape the base container or
invent exports for other properties. The data renderer is a direct whole-value
export. External callables therefore receive the existing unknown-caller and
parameter treatment, preserving callbacks reached through the renderer.

The call-graph poison guard stays enabled. The regression must compile and run a
prerendered page with `--release --check-call-graph`; its renderer was previously
poisoned because the synthetic page-runtime call never reached it. Existing
Counter and a data-backed renderer additionally validate both entry shapes.

The scope-hoisted linker also resolves a runtime `run` spelling only when its
entry emits that call. A prerender tree may correctly prune `run` entirely.

Defect: [#1338](https://github.com/canassa/beni/issues/1338), related to #685.
`RendererEntryRoot` fails before this correction at the generated renderer with
`--release --allow-debug --check-call-graph`. Afterward its four corpus builds
(dev/release, ordinary/prerender) render `42`, and Counter and DataSandbox retain
their existing full DOM transcripts. Goldens were captured using the corpus
harness with `BENI_WRITE_EXPECTED=1`, limited to `RendererEntryRoot`.
