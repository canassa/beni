Sampling interval requested: 25 µs. Actual time deltas are retained.

Self times below are averages over fresh pages, under the profiler, **not** comparison timings. Idle and unattributed/native `(program)` time are excluded from the function rows and reported separately.

**table-update/vanillajs**, 20 pages; idle 10016.3 ms, unattributed/native 490.9 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| update /out/jfb/Main.js:209:8 | 216.15 |
| updateData /out/jfb/Main.js:75:12 | 12.60 |
| (anonymous) /out/jfb/Main.js:140:62 | 9.95 |
| stopPropagation :0:-1 | 4.15 |
| matches :0:-1 | 4.15 |

**table-update/solid1**, 20 pages; idle 10004.7 ms, unattributed/native 629.5 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| g.e /out/solid1/main.js:1:11107 | 185.50 |
| S /out/solid1/main.js:1:2125 | 67.30 |
| C /out/solid1/main.js:1:2462 | 50.30 |
| (anonymous) /out/solid1/main.js:1:10125 | 43.05 |
| L /out/solid1/main.js:1:5278 | 40.50 |
| (anonymous) /out/solid1/main.js:1:1610 | 29.60 |
| (anonymous) /out/solid1/main.js:1:537 | 25.55 |
| T /out/solid1/main.js:1:3046 | 22.20 |
| o /out/solid1/main.js:1:5350 | 20.55 |
| s /out/solid1/main.js:1:5415 | 20.50 |
| y /out/solid1/main.js:1:799 | 18.90 |
| (anonymous) /out/solid1/main.js:1:10199 | 18.15 |

**table-update/solid2**, 20 pages; idle 10000.4 ms, unattributed/native 700.4 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/solid2/bench.js:1:67624 | 166.30 |
| Le /out/solid2/bench.js:1:25853 | 91.75 |
| D.We /out/solid2/bench.js:1:17032 | 83.00 |
| (anonymous) /out/solid2/bench.js:1:57677 | 73.40 |
| Ge /out/solid2/bench.js:1:24482 | 57.10 |
| queueMicrotask :0:-1 | 48.50 |
| sl.e /out/solid2/bench.js:1:67581 | 44.95 |
| ne /out/solid2/bench.js:1:17181 | 42.90 |
| get /out/solid2/bench.js:1:40566 | 39.80 |
| Pe /out/solid2/bench.js:1:23017 | 34.00 |
| a /out/solid2/bench.js:1:58167 | 29.70 |
| (anonymous) /out/solid2/bench.js:1:67071 | 25.20 |

**table-update/beni-release**, 20 pages; idle 10009.1 ms, unattributed/native 597.3 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| p /out/beni-rel/_main.mjs:1:10698 | 216.10 |
| K /out/beni-rel/_main.mjs:1:4899 | 79.35 |
| J /out/beni-rel/_main.mjs:1:3241 | 46.85 |
| (anonymous) /out/beni-rel/_main.mjs:1:6196 | 43.40 |
| C /out/beni-rel/_main.mjs:1:2042 | 35.75 |
| la /out/beni-rel/_main.mjs:1:8686 | 23.25 |
| e /out/beni-rel/_main.mjs:1:10392 | 11.85 |
| b.$$root /out/beni-rel/_main.mjs:1:1444 | 8.15 |
| (anonymous) /out/beni-rel/_main.mjs:1:6179 | 7.90 |
| u /out/beni-rel/_main.mjs:1:1254 | 7.85 |
| Aa /out/beni-rel/_main.mjs:1:9715 | 7.65 |
| t /out/beni-rel/_main.mjs:1:1138 | 7.45 |

**table-update/beni-direct-release**, 20 pages; idle 10014.6 ms, unattributed/native 560.3 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| F /out/beni-direct-rel/_main.mjs:1:10093 | 153.90 |
| da /out/beni-direct-rel/_main.mjs:1:5864 | 110.75 |
| y /out/beni-direct-rel/_main.mjs:1:1960 | 19.50 |
| V /out/beni-direct-rel/_main.mjs:1:10690 | 10.20 |
| (anonymous) /out/beni-direct-rel/_main.mjs:1:7211 | 5.00 |
| G /out/beni-direct-rel/_main.mjs:1:2277 | 4.15 |
| w /out/beni-direct-rel/_main.mjs:1:1889 | 4.15 |
| z /out/beni-direct-rel/_main.mjs:1:2035 | 4.10 |
| M /out/beni-direct-rel/_main.mjs:1:2906 | 2.45 |

**table-update/p3**, 20 pages; idle 10015.1 ms, unattributed/native 556.7 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| render /apps/p3/bench.js:339:15 | 116.10 |
| reconcile /apps/p3/bench.js:211:18 | 32.80 |
| List$indexedMapHelp /out/beni-dev/_core/List.mjs:190:28 | 29.55 |
| flush /apps/p3/bench.js:63:14 | 19.00 |
| List$builder /out/beni-dev/_core/List.mjs:182:21 | 12.45 |
| Update /apps/p3/bench.js:310:15 | 12.10 |
| (garbage collector) :0:-1 | 7.70 |
| send /apps/p3/bench.js:83:13 | 5.10 |

**live/vanillajs**, 20 pages; idle 5527.6 ms, unattributed/native 951.2 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/live/10000/vanilla.js:16:56 | 15.65 |
| (garbage collector) :0:-1 | 3.90 |

**live/solid1**, 20 pages; idle 5935.9 ms, unattributed/native 754.5 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| L /out/scaling/live/10000/solid1.js:1:5256 | 78.25 |
| M /out/scaling/live/10000/solid1.js:1:5922 | 38.60 |
| s /out/scaling/live/10000/solid1.js:1:5393 | 14.50 |
| (anonymous) /out/scaling/live/10000/solid1.js:1:1233 | 7.65 |
| v /out/scaling/live/10000/solid1.js:1:1125 | 6.50 |
| (anonymous) /out/scaling/live/10000/solid1.js:1:533 | 4.25 |
| (anonymous) /out/scaling/live/10000/solid1.js:1:1519 | 3.60 |

**live/solid2**, 20 pages; idle 5934.0 ms, unattributed/native 820.7 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| queueMicrotask :0:-1 | 59.95 |
| (anonymous) /out/scaling/live/10000/solid2.js:1:32198 | 49.10 |
| c /out/scaling/live/10000/solid2.js:1:32626 | 19.95 |
| flush /out/scaling/live/10000/solid2.js:1:3521 | 9.90 |
| on /out/scaling/live/10000/solid2.js:1:34395 | 8.40 |
| h /out/scaling/live/10000/solid2.js:1:32691 | 7.65 |
| W /out/scaling/live/10000/solid2.js:1:6501 | 5.40 |
| Se /out/scaling/live/10000/solid2.js:1:23851 | 4.30 |
| composedPath :0:-1 | 4.25 |
| o /out/scaling/live/10000/solid2.js:1:32187 | 4.20 |
| (anonymous) /out/scaling/live/10000/solid2.js:1:33871 | 3.90 |
| K /out/scaling/live/10000/solid2.js:1:5844 | 3.80 |

**live/beni-release**, 20 pages; idle 5927.0 ms, unattributed/native 672.4 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/live/10000/beni-rel/_main.mjs:1:7423 | 38.10 |
| Y /out/scaling/live/10000/beni-rel/_main.mjs:1:6796 | 21.25 |
| B /out/scaling/live/10000/beni-rel/_main.mjs:1:9637 | 11.70 |
| C /out/scaling/live/10000/beni-rel/_main.mjs:1:9510 | 8.25 |
| pa /out/scaling/live/10000/beni-rel/_main.mjs:1:8509 | 7.60 |
| U /out/scaling/live/10000/beni-rel/_main.mjs:1:6494 | 4.05 |
| (anonymous) /out/scaling/live/10000/beni-rel/_main.mjs:1:7406 | 4.05 |
| k /out/scaling/live/10000/beni-rel/_main.mjs:1:734 | 3.80 |
| x /out/scaling/live/10000/beni-rel/_main.mjs:1:1436 | 3.70 |
| S /out/scaling/live/10000/beni-rel/_main.mjs:1:6149 | 3.65 |

**live/beni-direct-release**, 20 pages; idle 5932.0 ms, unattributed/native 613.7 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| q /out/scaling/live/10000/beni-direct-rel/_main.mjs:1:6252 | 22.50 |
| X /out/scaling/live/10000/beni-direct-rel/_main.mjs:1:5100 | 10.40 |
| A /out/scaling/live/10000/beni-direct-rel/_main.mjs:1:6677 | 8.65 |
| q /out/scaling/live/10000/beni-direct-rel/_main.mjs:1:656 | 4.20 |

**live/p3**, 20 pages; idle 5931.4 ms, unattributed/native 597.5 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| render /out/scaling/live/10000/p3.js:117:15 | 26.75 |
| send /out/scaling/live/10000/p3.js:27:13 | 7.45 |
| Go /out/scaling/live/10000/p3.js:88:11 | 4.30 |
| (anonymous) /out/scaling/live/10000/p3.js:143:29 | 4.30 |
| (garbage collector) :0:-1 | 3.85 |
| schedule /out/scaling/live/10000/p3.js:17:17 | 3.20 |

**helperRows/vanillajs**, 20 pages; idle 5525.7 ms, unattributed/native 948.0 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/helperRows/10000/vanilla.js:16:56 | 23.90 |
| (garbage collector) :0:-1 | 9.95 |

**helperRows/solid1**, 20 pages; idle 5995.4 ms, unattributed/native 522.7 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| L /out/scaling/helperRows/10000/solid1.js:1:5256 | 84.40 |
| A /out/scaling/helperRows/10000/solid1.js:1:2034 | 19.40 |
| M /out/scaling/helperRows/10000/solid1.js:1:5922 | 17.25 |
| s /out/scaling/helperRows/10000/solid1.js:1:5393 | 13.55 |
| (anonymous) /out/scaling/helperRows/10000/solid1.js:1:1233 | 7.75 |
| m /out/scaling/helperRows/10000/solid1.js:1:2371 | 4.50 |
| (anonymous) /out/scaling/helperRows/10000/solid1.js:1:2459 | 3.90 |
| y /out/scaling/helperRows/10000/solid1.js:1:1475 | 3.80 |
| v /out/scaling/helperRows/10000/solid1.js:1:1125 | 3.75 |
| composedPath :0:-1 | 3.75 |
| equals /out/scaling/helperRows/10000/solid1.js:1:52 | 3.70 |
| l /out/scaling/helperRows/10000/solid1.js:1:5328 | 2.05 |

**helperRows/solid2**, 20 pages; idle 5993.1 ms, unattributed/native 559.8 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/helperRows/10000/solid2.js:1:32198 | 53.30 |
| queueMicrotask :0:-1 | 45.95 |
| h /out/scaling/helperRows/10000/solid2.js:1:32691 | 23.00 |
| $.We /out/scaling/helperRows/10000/solid2.js:1:16904 | 15.10 |
| o /out/scaling/helperRows/10000/solid2.js:1:32187 | 12.30 |
| flush /out/scaling/helperRows/10000/solid2.js:1:3521 | 8.10 |
| on /out/scaling/helperRows/10000/solid2.js:1:34395 | 5.65 |
| q /out/scaling/helperRows/10000/solid2.js:1:5789 | 4.20 |
| c /out/scaling/helperRows/10000/solid2.js:1:32626 | 4.10 |
| (anonymous) /out/scaling/helperRows/10000/solid2.js:1:33871 | 3.95 |
| ye /out/scaling/helperRows/10000/solid2.js:1:22116 | 3.90 |
| Se /out/scaling/helperRows/10000/solid2.js:1:23851 | 3.85 |

**helperRows/beni-release**, 20 pages; idle 5991.6 ms, unattributed/native 376.0 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/helperRows/10000/beni-rel/_main.mjs:1:6122 | 29.70 |
| Y /out/scaling/helperRows/10000/beni-rel/_main.mjs:1:6974 | 11.20 |
| x /out/scaling/helperRows/10000/beni-rel/_main.mjs:1:1436 | 8.25 |
| (garbage collector) :0:-1 | 7.80 |
| q /out/scaling/helperRows/10000/beni-rel/_main.mjs:1:1171 | 7.05 |
| w /out/scaling/helperRows/10000/beni-rel/_main.mjs:1:1320 | 4.05 |
| f /out/scaling/helperRows/10000/beni-rel/_main.mjs:1:1588 | 3.85 |

**helperRows/beni-direct-release**, 20 pages; idle 5993.4 ms, unattributed/native 315.9 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| p /out/scaling/helperRows/10000/beni-direct-rel/_main.mjs:1:4026 | 25.40 |
| y /out/scaling/helperRows/10000/beni-direct-rel/_main.mjs:1:4379 | 4.15 |
| (anonymous) /out/scaling/helperRows/10000/beni-direct-rel/_main.mjs:1:3623 | 2.15 |

**derived/vanillajs**, 20 pages; idle 6041.5 ms, unattributed/native 346.4 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/derived/100000/vanilla.js:20:56 | 9.05 |
| (garbage collector) :0:-1 | 7.80 |

**derived/solid1**, 20 pages; idle 6034.4 ms, unattributed/native 387.4 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| P /out/scaling/derived/100000/solid1.js:1:5254 | 71.95 |
| q /out/scaling/derived/100000/solid1.js:1:5920 | 29.50 |
| (anonymous) /out/scaling/derived/100000/solid1.js:1:1389 | 11.90 |
| v /out/scaling/derived/100000/solid1.js:1:864 | 11.50 |
| A /out/scaling/derived/100000/solid1.js:1:2190 | 7.55 |
| l /out/scaling/derived/100000/solid1.js:1:5326 | 4.15 |
| (anonymous) /out/scaling/derived/100000/solid1.js:1:1675 | 4.05 |
| w /out/scaling/derived/100000/solid1.js:1:1631 | 3.95 |
| x /out/scaling/derived/100000/solid1.js:1:2740 | 3.90 |
| y /out/scaling/derived/100000/solid1.js:1:1281 | 3.85 |
| (anonymous) /out/scaling/derived/100000/solid1.js:1:5225 | 3.85 |
| S /out/scaling/derived/100000/solid1.js:1:2527 | 3.80 |

**derived/solid2**, 20 pages; idle 6034.3 ms, unattributed/native 440.3 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/derived/100000/solid2.js:1:32254 | 49.90 |
| queueMicrotask :0:-1 | 38.30 |
| h /out/scaling/derived/100000/solid2.js:1:32747 | 26.10 |
| (anonymous) /out/scaling/derived/100000/solid2.js:1:33927 | 16.70 |
| o /out/scaling/derived/100000/solid2.js:1:32243 | 12.45 |
| flush /out/scaling/derived/100000/solid2.js:1:3521 | 9.60 |
| Se /out/scaling/derived/100000/solid2.js:1:23851 | 7.90 |
| rn /out/scaling/derived/100000/solid2.js:1:34451 | 7.85 |
| W /out/scaling/derived/100000/solid2.js:1:6501 | 6.40 |
| D /out/scaling/derived/100000/solid2.js:1:5869 | 4.25 |
| q /out/scaling/derived/100000/solid2.js:1:5789 | 4.20 |
| c /out/scaling/derived/100000/solid2.js:1:32682 | 4.10 |

**derived/beni-release**, 20 pages; idle 6036.6 ms, unattributed/native 376.3 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/derived/100000/beni-rel/_main.mjs:1:5903 | 29.75 |
| ga /out/scaling/derived/100000/beni-rel/_main.mjs:1:7677 | 29.15 |
| w /out/scaling/derived/100000/beni-rel/_main.mjs:1:8725 | 12.80 |
| b.$$root /out/scaling/derived/100000/beni-rel/_main.mjs:1:1440 | 8.55 |
| (anonymous) /out/scaling/derived/100000/beni-rel/_main.mjs:1:5886 | 8.40 |

**derived/beni-direct-release**, 20 pages; idle 6033.9 ms, unattributed/native 356.5 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| u /out/scaling/derived/100000/beni-direct-rel/_main.mjs:1:3182 | 13.15 |
| p /out/scaling/derived/100000/beni-direct-rel/_main.mjs:1:2951 | 9.15 |
| (anonymous) /out/scaling/derived/100000/beni-direct-rel/_main.mjs:1:2393 | 4.25 |
| B /out/scaling/derived/100000/beni-direct-rel/_main.mjs:1:1479 | 4.15 |

**depth/vanillajs**, 20 pages; idle 6044.7 ms, unattributed/native 224.5 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/depth/128/vanilla.js:29:56 | 70.75 |
| (garbage collector) :0:-1 | 3.85 |

**depth/solid1**, 20 pages; idle 6029.9 ms, unattributed/native 431.9 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| Q /out/scaling/depth/128/solid1.js:1:9577 | 58.50 |
| k /out/scaling/depth/128/solid1.js:1:3569 | 49.10 |
| T /out/scaling/depth/128/solid1.js:1:4235 | 28.35 |
| (garbage collector) :0:-1 | 19.65 |
| v /out/scaling/depth/128/solid1.js:1:593 | 15.95 |
| i /out/scaling/depth/128/solid1.js:1:3641 | 14.85 |
| y /out/scaling/depth/128/solid1.js:1:1690 | 12.50 |
| j /out/scaling/depth/128/solid1.js:1:2611 | 11.30 |
| (anonymous) /out/scaling/depth/128/solid1.js:1:1118 | 10.80 |
| get n /out/scaling/depth/128/solid1.js:1:10933 | 8.45 |
| get n /out/scaling/depth/128/solid1.js:1:18967 | 5.45 |
| get n /out/scaling/depth/128/solid1.js:1:17010 | 4.55 |

**depth/solid2**, 20 pages; idle 6028.1 ms, unattributed/native 495.6 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| nl /out/scaling/depth/128/solid2.js:1:37120 | 56.80 |
| (anonymous) /out/scaling/depth/128/solid2.js:1:52010 | 52.50 |
| get /out/scaling/depth/128/solid2.js:1:39643 | 49.40 |
| queueMicrotask :0:-1 | 24.80 |
| d /out/scaling/depth/128/solid2.js:1:52503 | 17.10 |
| f /out/scaling/depth/128/solid2.js:1:52438 | 12.25 |
| Rt /out/scaling/depth/128/solid2.js:1:22381 | 12.00 |
| de /out/scaling/depth/128/solid2.js:1:28108 | 10.55 |
| bl /out/scaling/depth/128/solid2.js:1:38829 | 8.95 |
| Yl /out/scaling/depth/128/solid2.js:1:54207 | 8.35 |
| te /out/scaling/depth/128/solid2.js:1:26608 | 7.85 |
| I.We /out/scaling/depth/128/solid2.js:1:17100 | 7.75 |

**depth/beni-release**, 20 pages; idle 6026.5 ms, unattributed/native 484.3 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/depth/128/beni-rel/_main.mjs:1:2155 | 27.35 |
| B /out/scaling/depth/128/beni-rel/_main.mjs:1:2634 | 22.80 |
| yl /out/scaling/depth/128/beni-rel/_main.mjs:1:57401 | 16.65 |
| j /out/scaling/depth/128/beni-rel/_main.mjs:1:734 | 8.55 |
| xl /out/scaling/depth/128/beni-rel/_main.mjs:1:57372 | 8.35 |
| u /out/scaling/depth/128/beni-rel/_main.mjs:1:1161 | 7.65 |
| Ig /out/scaling/depth/128/beni-rel/_main.mjs:1:50753 | 7.25 |
| b.$$root /out/scaling/depth/128/beni-rel/_main.mjs:1:1487 | 7.10 |
| Hb /out/scaling/depth/128/beni-rel/_main.mjs:1:16823 | 6.80 |
| nf /out/scaling/depth/128/beni-rel/_main.mjs:1:41328 | 4.80 |
| jd /out/scaling/depth/128/beni-rel/_main.mjs:1:27379 | 4.45 |
| nl /out/scaling/depth/128/beni-rel/_main.mjs:1:57122 | 4.45 |

**depth/beni-direct-release**, 20 pages; idle 6029.6 ms, unattributed/native 433.4 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| Ik /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:39724 | 15.95 |
| b /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:40714 | 12.30 |
| Eb /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:3545 | 9.20 |
| Jk /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:40077 | 8.50 |
| Kj /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:26360 | 8.10 |
| Uj /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:28510 | 7.35 |
| pj /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:22496 | 7.30 |
| Fb /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:3568 | 4.85 |
| Cc /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:4843 | 4.70 |
| qc /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:4543 | 4.60 |
| Ic /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:4993 | 4.50 |
| tc /out/scaling/depth/128/beni-direct-rel/_main.mjs:1:4618 | 4.35 |

**depth/p3**, 20 pages; idle 6050.0 ms, unattributed/native 323.5 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| render /out/scaling/depth/128/p3.js:310:15 | 37.35 |
| bump93 /out/scaling/depth/128/p3.js:204:15 | 9.80 |
| (anonymous) /out/scaling/depth/128/p3.js:318:29 | 9.75 |
| bump1 /out/scaling/depth/128/p3.js:296:14 | 6.70 |
| bump98 /out/scaling/depth/128/p3.js:199:15 | 5.75 |
| bump113 /out/scaling/depth/128/p3.js:184:16 | 5.60 |
| bump114 /out/scaling/depth/128/p3.js:183:16 | 5.40 |
| bump128 /out/scaling/depth/128/p3.js:169:16 | 5.30 |
| bump57 /out/scaling/depth/128/p3.js:240:15 | 5.15 |
| bump58 /out/scaling/depth/128/p3.js:239:15 | 5.15 |
| bump83 /out/scaling/depth/128/p3.js:214:15 | 5.10 |
| bump91 /out/scaling/depth/128/p3.js:206:15 | 5.00 |

**width/vanillajs**, 20 pages; idle 6056.0 ms, unattributed/native 240.0 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/width/1024/vanilla.js:10:56 | 58.50 |
| (garbage collector) :0:-1 | 7.70 |

**width/solid1**, 20 pages; idle 6034.0 ms, unattributed/native 521.9 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| $ /out/scaling/width/1024/solid1.js:1:3530 | 36.60 |
| J /out/scaling/width/1024/solid1.js:1:9538 | 19.90 |
| k /out/scaling/width/1024/solid1.js:1:4196 | 13.80 |
| e /out/scaling/width/1024/solid1.js:1:3602 | 11.55 |
| C /out/scaling/width/1024/solid1.js:1:1690 | 10.75 |
| h /out/scaling/width/1024/solid1.js:1:1010 | 7.95 |
| (anonymous) /out/scaling/width/1024/solid1.js:1:56057 | 7.55 |
| l /out/scaling/width/1024/solid1.js:1:3667 | 6.10 |
| (anonymous) /out/scaling/width/1024/solid1.js:1:1118 | 4.35 |
| v /out/scaling/width/1024/solid1.js:1:2240 | 4.30 |
| K /out/scaling/width/1024/solid1.js:1:7454 | 4.15 |
| (anonymous) /out/scaling/width/1024/solid1.js:1:10249 | 4.05 |

**width/solid2**, 20 pages; idle 6035.1 ms, unattributed/native 547.8 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| (anonymous) /out/scaling/width/1024/solid2.js:1:51967 | 47.90 |
| queueMicrotask :0:-1 | 39.55 |
| c /out/scaling/width/1024/solid2.js:1:52460 | 13.15 |
| Ai /out/scaling/width/1024/solid2.js:1:31312 | 11.45 |
| F /out/scaling/width/1024/solid2.js:1:5922 | 11.35 |
| u /out/scaling/width/1024/solid2.js:1:52395 | 10.30 |
| flush /out/scaling/width/1024/solid2.js:1:3571 | 9.65 |
| composedPath :0:-1 | 8.30 |
| e /out/scaling/width/1024/solid2.js:1:51956 | 8.25 |
| get /out/scaling/width/1024/solid2.js:1:39643 | 7.85 |
| Ve /out/scaling/width/1024/solid2.js:1:54164 | 7.80 |
| ye /out/scaling/width/1024/solid2.js:1:44272 | 7.70 |

**width/beni-release**, 20 pages; idle 6031.3 ms, unattributed/native 505.7 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| s /out/scaling/width/1024/beni-rel/_main.mjs:1:127517 | 239.60 |
| f /out/scaling/width/1024/beni-rel/_main.mjs:1:1781 | 59.20 |
| (anonymous) /out/scaling/width/1024/beni-rel/_main.mjs:1:1299 | 36.90 |
| d.$$root /out/scaling/width/1024/beni-rel/_main.mjs:1:1026 | 8.30 |
| n /out/scaling/width/1024/beni-rel/_main.mjs:1:520 | 7.80 |
| (anonymous) /out/scaling/width/1024/beni-rel/_main.mjs:1:1282 | 4.40 |
| o /out/scaling/width/1024/beni-rel/_main.mjs:1:993 | 3.95 |
| r /out/scaling/width/1024/beni-rel/_main.mjs:1:127539 | 3.90 |

**width/beni-direct-release**, 20 pages; idle 6054.7 ms, unattributed/native 251.7 ms.

| function / URL:line:column | sampled self µs per page |
|---|--:|
| r /out/scaling/width/1024/beni-direct-rel/_main.mjs:1:20663 | 564.85 |
| q /out/scaling/width/1024/beni-direct-rel/_main.mjs:1:20621 | 12.15 |
| e /out/scaling/width/1024/beni-direct-rel/_main.mjs:1:46 | 9.00 |
| (anonymous) /out/scaling/width/1024/beni-direct-rel/_main.mjs:1:624 | 4.65 |
| b /out/scaling/width/1024/beni-direct-rel/_main.mjs:1:20697 | 3.90 |
