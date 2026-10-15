## 2026-10-13 01:20 CEST — js-framework-benchmark on a quiet machine

**What I did.** Re-ran research 83's official js-framework-benchmark run on azathoth (Xeon E-2386G,
idle), because dagon's three passes were taken at load 33–41. Fresh clone with only the
`js-framework-benchmark` submodule, `nix develop`, a ReleaseFast beni, dagon's exact Chrome
154.0.8037.97 store path copied with `nix copy`, `--taskset=1-5,7-11` (five whole cores, core 0
left to the OS). The owner narrowed the field to vanillajs, Solid, beni-direct and beni-tea while
an eight-framework pass was half done; it was stopped and discarded, and two full passes of the
four ran at the runner's default counts, 31 minutes each, load never above 1.33. Results in
`bench/jfb/results/2026-10-13-azathoth/`, write-up in research 83 §7.

**What I learned.** Quiet, the official weighted geomean is vanillajs 1.00, beni-direct 1.02,
beni-tea 1.03, Solid 1.9.3 1.09, identical in both passes; medians moved at most 4 % and most IQRs
are ±1 %. Dagon's "beni-tea ahead of vanillajs" was load on two vanillajs cells. beni is within
6 % (direct) and 11 % (tea, on `swap`) of vanillajs per operation and ahead of or level with Solid 1
on all nine. `create10k` is beni's largest `script` gap to vanillajs (41.3 against 35.2 ms).
Solid/vanilla here is 1.08, exactly the published table's ratio. The emitted pages are
byte-identical between `86d161d0b` (dagon's) and `161eae05`, so the two runs measured the same code.
