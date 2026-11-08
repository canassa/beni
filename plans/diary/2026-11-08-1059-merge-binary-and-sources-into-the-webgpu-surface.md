## 2026-11-08 10:59 CET — merge Binary and sources into the WebGPU surface

**What I did.** Merged master (Binary, the WGSL layout and the browser
sources) into the WebGPU surface branch, then that branch into the engine
branch. Generate.zig keeps both the Gpu emitter and the intrinsic types;
webgpu.md keeps the corrected Size64 bound (0 … 2⁵³ − 1) with master's
Word64 API names; browser-tea re-exports both module sets; SKILL.md takes
the shorter wording of each side and stays under 8 000 bytes. The api
references were regenerated, not hand-merged.

**What I learned.** Both branches generated the seven source host types
(HTMLCanvasElement, ImageBitmap, …) with different headers, and each
staleness check refused the other's text. The native catalogue owns them
now; the WebGPU emitter writes only the GPU interfaces, as webgpu.md §2.2
says it should. A merge that touches a generator needs the two staleness
checks run together, not one at a time.
