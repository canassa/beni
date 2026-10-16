# 2026-10-16 — Explain the mixed-app compression effect

At the common measured N2,592, local reducers produce 146,776 brotli bytes for
the mixed app versus 117,590 averaged across ten homogeneous apps: 24.8% more,
with only 0.01% more raw code. Static reactivity's brotli response changes by
−1.2%, also with nearly identical raw size. The mean is a comparison, not an
additive prediction for a mixed response. A new HTML chart/table and standalone
figure explain why homogeneous slopes do not directly predict the mixed curve.
Vanilla's mixed app also includes ten shape factories rather than one.

Chrome checks verified the new report chart/table, absence of JavaScript errors
and page overflow at 390 px. The report contains 2,355 size observations, including
933 stress measurements, twenty measured crossings and fifteen compiler-limited
curves. The latest artifact audit verified 931 stress outputs before two more
arrived. Further family measurements continue. Research 106 remains below
2,000 words and now emphasizes the larger mixed/composition evidence.

Large resource requests could wait behind successive newer small jobs. Ordinary
requests now enter in arrival order, while optional compression helpers can use
spare capacity only when the oldest request cannot fit. A controlled check
verified helper progress and oldest-first ordinary admission. An earlier manual
admission hold let Solid's list measurement run at N96,192 (518,127 brotli bytes);
all held processes resumed automatically. Resource limits and byte accounting
are unchanged. Cluster TEA N6,176 and recursive-thread TEA N3,888 reached the
same recorded 16 GiB compiler cap.

No repository gates or suites, and no new application timing measurements ran.
