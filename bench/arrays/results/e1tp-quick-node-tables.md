# E1tp, results/e1tp-quick-node.jsonl

Median of the rounds' medians per call; **bold** is the fastest of the four columns, every other cell its ratio to it. "best other": the fastest persistent candidate in the file other than these three, named. ¹ one cold call. ² IQR over 20 % of the median. ³ one round. ⁴ load over 16. > 8 s / > 45 s killed; skip: failed at the size before; SO stack overflow.

**A. The list scenarios, Elm-style code**

| op | n | E1tp (elm) | E1t (elm) | cons (elm) | best other (elm) |
|---|--:|--:|--:|--:|--:|
| map, recursive | 10,000 | 116 µs²³ (2.6×) | 118 µs³ (2.6×) | **45.1 µs³** | 196 µs³ (4.3×) trie |
| filter, recursive | 10,000 | 122 µs³ (4.0×) | 115 µs³ (3.8×) | **30.4 µs³** | 182 µs³ (6.0×) trie |
| map, accumulator + reverse | 10,000 | 482 µs³ (5.9×) | 59.3 ms²³ (725×) | **81.8 µs³** | 1.22 ms³ (15×) funkia |
| filter, accumulator + reverse | 10,000 | 278 µs³ (6.6×) | 6.24 ms³ (148×) | **42.3 µs²³** | 794 µs³ (19×) funkia |
| sum | 10,000 | 138 µs³ (9.8×) | 142 µs³ (10×) | **14.1 µs³** | 167 µs³ (12×) trie |
| sum, List.foldl | 10,000 | 121 µs³ (8.3×) | 118 µs³ (8.1×) | **14.5 µs³** | 149 µs³ (10×) trie |
| takeWhile (90 %) | 10,000 | 98.0 µs³ (2.3×) | 94.5 µs³ (2.2×) | **42.9 µs³** | 168 µs³ (3.9×) trie |
| pairwise | 10,000 | 415 µs³ (3.0×) | 21.2 ms³ (155×) | **137 µs³** | 4.47 ms²³ (33×) funkia |
| merge sort | 10,000 | 9.22 ms³ (5.0×) | 61.5 ms³ (34×) | **1.83 ms³** | 25.2 ms³ (14×) funkia |
| merge sort, sorted input | 10,000 | 9.03 ms³ (4.4×) | 53.9 ms²³ (26×) | **2.07 ms³** | 24.2 ms²³ (12×) funkia |
| foldr building a list | 10,000 | 526 µs²³ (4.6×) | 55.5 ms²³ (486×) | **114 µs²³** | 1.31 ms²³ (11×) funkia |
| foldr sum | 10,000 | 397 µs³ (3.9×) | 18.1 ms³ (177×) | **103 µs³** | 1.06 ms³ (10×) funkia |
| range + sum | 10,000 | 268 µs³ (5.5×) | 22.1 ms³ (452×) | **49.0 µs²³** | 610 µs³ (12×) funkia |
| map2 (zip) | 10,000 | 257 µs³ (3.1×) | 197 µs²³ (2.4×) | **81.7 µs³** | 325 µs³ (4.0×) trie |
| concatMap | 10,000 | 592 µs³ (3.2×) | 643 µs³ (3.5×) | **185 µs³** | 1.69 ms²³ (9.2×) funkia |
| append in a loop, acc ++ [x] | 10,000 | 29.4 ms³ (18×) | 18.3 ms³ (11×) | 300 ms³ (184×) | **1.63 ms³** trie |
| append two | 10,000 | 82.1 µs³ (51×) | 105 µs³ (65×) | 60.7 µs³ (38×) | **1.61 µs³** funkia |
| reverse | 10,000 | 196 µs³ (5.7×) | 18.2 ms³ (532×) | **34.2 µs³** | 583 µs³ (17×) funkia |
| List.map | 10,000 | 140 µs²³ (2.0×) | 129 µs²³ (1.85×) | **69.5 µs³** | 185 µs³ (2.7×) trie |
| List.filter | 10,000 | 227 µs³ (2.0×) | 220 µs³ (1.93×) | **114 µs²³** | 266 µs²³ (2.3×) trie |
| x :: acc, then reverse | 10,000 | 547 µs³ (5.0×) | 42.1 ms²³ (382×) | **110 µs²³** | 1.27 ms³ (12×) funkia |
| into a record field | 10,000 | 595 µs²³ (2.7×) | 54.6 ms²³ (251×) | **217 µs²³** | 1.30 ms³ (6.0×) funkia |
| into a tuple (partition) | 10,000 | 562 µs³ (3.2×) | 44.0 ms³ (249×) | **177 µs³** | 1.44 ms²³ (8.1×) funkia |
| paths sharing tails, all kept | 10,000 | 1.16 ms²³ (6.8×) | 423 ms³ (2,503×) | **169 µs²³** | 2.00 ms²³ (12×) funkia |
| undo stack (3 edits, 1 undo) | 10,000 | 429 µs³ (4.2×) | 41.3 ms³ (401×) | **103 µs³** | 1.09 ms²³ (11×) funkia |
| add to front, first | 10,000 | 91.4 µs²³ (1.80×) | **50.7 µs³** | 77.3 µs²³ (1.52×) | 89.6 µs²³ (1.77×) funkia |
| add + remove oldest, steady | 10,000 | 466 µs²³ (3.4×) | 1.23 ms²³ (9.0×) | **137 µs³** | 1.14 ms³ (8.3×) funkia |
| toggle one, steady | 10,000 | 255 µs³ (1.74×) | 235 µs³ (1.60×) | **147 µs³** | 266 µs³ (1.81×) trie |
| remove one, first | 10,000 | 555 µs²³ (2.9×) | 24.5 ms³ (127×) | **193 µs³** | 1.03 ms²³ (5.3×) funkia |
| render only | 10,000 | 41.8 µs³ (1.11×) | **37.7 µs³** | 77.1 µs³ (2.0×) | 60.1 µs³ (1.60×) trie |

**B. The list scenarios, array-first code (cons on its own Elm-style code)**

| op | n | E1tp (first) | E1t (first) | cons (elm) | best other (first) |
|---|--:|--:|--:|--:|--:|
| map, recursive | 10,000 | 261 µs²³ (5.8×) | 196 µs²³ (4.4×) | **45.1 µs³** | 454 µs³ (10×) trie |
| filter, recursive | 10,000 | 190 µs³ (6.3×) | 185 µs³ (6.1×) | **30.4 µs³** | 296 µs³ (9.7×) trie |
| map, accumulator + reverse | 10,000 | 142 µs³ (1.74×) | 136 µs²³ (1.67×) | **81.8 µs³** | 259 µs³ (3.2×) funkia |
| filter, accumulator + reverse | 10,000 | 104 µs³ (2.5×) | 82.8 µs³ (2.0×) | **42.3 µs²³** | 192 µs³ (4.5×) funkia |
| sum | 10,000 | 133 µs³ (9.5×) | 136 µs³ (9.7×) | **14.1 µs³** | 178 µs³ (13×) trie |
| sum, List.foldl | 10,000 | 59.6 µs³ (4.1×) | 50.7 µs³ (3.5×) | **14.5 µs³** | 99.9 µs³ (6.9×) trie |
| takeWhile (90 %) | 10,000 | 258 µs²³ (6.0×) | 207 µs²³ (4.8×) | **42.9 µs³** | 450 µs³ (10×) trie |
| pairwise | 10,000 | 256 µs²³ (1.87×) | 233 µs²³ (1.70×) | **137 µs³** | 789 µs³ (5.8×) funkia |
| merge sort | 10,000 | 7.64 ms³ (4.2×) | 6.95 ms²³ (3.8×) | **1.83 ms³** | 12.3 ms³ (6.7×) trie |
| merge sort, sorted input | 10,000 | 8.63 ms³ (4.2×) | 4.82 ms²³ (2.3×) | **2.07 ms³** | 8.44 ms³ (4.1×) trie |
| foldr building a list | 10,000 | 137 µs³ (1.20×) | 129 µs³ (1.13×) | **114 µs²³** | 355 µs³ (3.1×) funkia |
| foldr sum | 10,000 | 50.4 µs³ (1.16×) | **43.5 µs³** | 103 µs³ (2.4×) | 96.0 µs³ (2.2×) trie |
| range + sum | 10,000 | **29.9 µs³** | 31.6 µs²³ (1.06×) | 49.0 µs²³ (1.64×) | 109 µs³ (3.6×) trie |
| map2 (zip) | 10,000 | 142 µs²³ (1.74×) | 94.1 µs²³ (1.15×) | **81.7 µs³** | 253 µs³ (3.1×) trie |
| concatMap | 10,000 | 344 µs²³ (1.86×) | 377 µs³ (2.0×) | **185 µs³** | 989 µs²³ (5.4×) funkia |
| append in a loop, acc ++ [x] | 10,000 | 147 µs³ (1.28×) | **115 µs³** | 300 ms³ (2,612×) | 287 µs³ (2.5×) funkia |
| append two | 10,000 | 104 µs³ (64×) | 82.6 µs³ (51×) | 60.7 µs³ (37×) | **1.62 µs³** funkia |
| reverse | 10,000 | **29.9 µs³** | 34.5 µs³ (1.15×) | 34.2 µs³ (1.14×) | 89.8 µs³ (3.0×) trie |
| List.map | 10,000 | **49.4 µs³** | 53.2 µs³ (1.08×) | 69.5 µs³ (1.41×) | 111 µs³ (2.2×) trie |
| List.filter | 10,000 | **69.7 µs³** | 72.8 µs³ (1.04×) | 114 µs²³ (1.63×) | 151 µs²³ (2.2×) trie |
| x :: acc, then reverse | 10,000 | 129 µs³ (1.17×) | 129 µs³ (1.17×) | **110 µs²³** | 279 µs³ (2.5×) funkia |
| into a record field | 10,000 | 287 µs³ (1.40×) | **206 µs³** | 217 µs²³ (1.06×) | 352 µs³ (1.71×) funkia |
| into a tuple (partition) | 10,000 | 209 µs²³ (1.18×) | 212 µs²³ (1.20×) | **177 µs³** | 363 µs³ (2.1×) funkia |
| paths sharing tails, all kept | 10,000 | 889 µs²³ (5.3×) | 447 µs²³ (2.6×) | **169 µs²³** | 2.22 ms²³ (13×) funkia |
| undo stack (3 edits, 1 undo) | 10,000 | 373 µs²³ (3.6×) | 377 µs³ (3.7×) | **103 µs³** | 502 µs²³ (4.9×) funkia |
| add to front, first | 10,000 | 83.7 µs²³ (1.18×) | 90.7 µs²³ (1.28×) | 77.3 µs²³ (1.09×) | **71.0 µs²³** trie |
| add + remove oldest, steady | 10,000 | 317 µs³ (2.3×) | 299 µs³ (2.2×) | **137 µs³** | 285 µs³ (2.1×) trie |
| toggle one, steady | 10,000 | 194 µs³ (1.33×) | 200 µs³ (1.37×) | **147 µs³** | 295 µs³ (2.0×) trie |
| remove one, first | 10,000 | 183 µs³ (1.01×) | **180 µs³** | 193 µs³ (1.07×) | 275 µs³ (1.52×) trie |
| render only | 10,000 | 39.8 µs³ (1.10×) | **36.3 µs³** | 77.1 µs³ (2.1×) | 65.0 µs³ (1.79×) trie |

**C. The single operations, array-first (cons on its own Elm-style code)**

| op | n | E1tp (first) | E1t (first) | cons (elm) | best other (first) |
|---|--:|--:|--:|--:|--:|
| get | 1,000 | **5.1 ns²³** | 5.3 ns²³ (1.03×) | 1.87 µs³ (367×) | 7.5 ns³ (1.46×) trie |
| set, first | 1,000 | 1.03 µs²³ (11×) | 959 ns²³ (10×) | 9.69 µs³ (102×) | **95 ns²³** trie |
| set, threaded | 1,000 | **65 ns²³** | 100 ns²³ (1.53×) | 6.28 µs²³ (96×) | 85 ns²³ (1.31×) trie |
| push, first | 1,000 | 1.31 µs²³ (28×) | 912 ns²³ (19×) | 9.44 µs³ (202×) | **47 ns²³** trie |
| push, threaded | 1,000 | 38 ns²³ (1.33×) | 29 ns²³ (1.01×) | 8.04 µs³ (280×) | **29 ns²³** funkia |
| pop, first | 1,000 | 892 ns²³ (26×) | 849 ns²³ (25×) | 13.0 µs³ (381×) | **34 ns²³** trie |
| pop, threaded | 1,000 | 37 ns²³ (1.17×) | **32 ns²³** | 3.37 µs³ (106×) | 65 ns²³ (2.0×) funkia |
| slice | 1,000 | **166 ns²³** | 213 ns²³ (1.28×) | 4.96 µs³ (30×) | 168 ns²³ (1.01×) funkia |
| concat | 1,000 | **730 ns³** | 746 ns²³ (1.02×) | 8.10 µs³ (11×) | 806 ns³ (1.10×) funkia |
| insert, first | 1,000 | 8.15 µs²³ (9.7×) | 5.83 µs²³ (7.0×) | 9.04 µs³ (11×) | **838 ns²³** funkia |
| insert, threaded | 1,000 | 13.0 µs³ (5.1×) | 13.4 µs²³ (5.2×) | 5.55 µs³ (2.2×) | **2.56 µs³** funkia |
| remove, first | 1,000 | 746 ns²³ (1.04×) | **715 ns²³** | 8.15 µs³ (11×) | 870 ns²³ (1.22×) funkia |
| remove, threaded | 1,000 | **470 ns²³** | 643 ns²³ (1.37×) | 4.47 µs²³ (9.5×) | 875 ns³ (1.86×) funkia |
| swap, first | 1,000 | 1.05 µs²³ (12×) | 1.14 µs²³ (13×) | 14.0 µs³ (157×) | **89 ns²³** trie |
| swap, threaded | 1,000 | **123 ns²³** | 143 ns²³ (1.17×) | 11.2 µs³ (91×) | 124 ns²³ (1.01×) trie |
| map | 1,000 | **4.17 µs²³** | 4.90 µs²³ (1.17×) | 10.1 µs³ (2.4×) | 16.4 µs³ (3.9×) trie |
| filter | 1,000 | 7.16 µs³ (1.46×) | 7.03 µs³ (1.44×) | **4.89 µs²³** | 11.1 µs³ (2.3×) trie |
| foldl | 1,000 | **1.30 µs²³** | 1.49 µs²³ (1.15×) | 4.31 µs³ (3.3×) | 2.61 µs²³ (2.0×) trie |
| iterate | 1,000 | 4.72 µs³ (1.03×) | **4.58 µs³** | 5.35 µs³ (1.17×) | 5.42 µs³ (1.18×) trie |
| fromArray | 1,000 | 348 ns²³ (1.18×) | **294 ns²³** | 2.37 µs²³ (8.1×) | 1.19 µs²³ (4.1×) trie |
| toArray | 1,000 | **6.6 ns²³** | 7.6 ns²³ (1.16×) | 5.78 µs³ (879×) | 1.43 µs²³ (218×) trie |
| eq | 1,000 | 1.30 µs²³ (1.07×) | 1.68 µs²³ (1.39×) | 5.08 µs³ (4.2×) | **1.21 µs²³** trie |
| sort | 1,000 | 191 µs³ (1.40×) | 188 µs³ (1.38×) | **137 µs³** | 429 µs³ (3.1×) funkia |

**D. §15's array scenarios (indexed code)**

| op | n | E1tp (index) | E1t (index) | cons (index) | best other (index) |
|---|--:|--:|--:|--:|--:|
| table/update one/first | 1,000 | 4.47 µs³ (1.27×) | 4.43 µs³ (1.26×) | 12.8 µs³ (3.6×) | **3.52 µs³** trie |
| table/update one/first | 10,000 | 42.8 µs³ (1.18×) | 42.8 µs³ (1.18×) | 129 µs²³ (3.6×) | **36.4 µs³** trie |
| table/update one/steady | 1,000 | 4.38 µs³ (1.10×) | 4.30 µs³ (1.08×) | 13.1 µs³ (3.3×) | **3.97 µs³** trie |
| table/update one/steady | 10,000 | 51.0 µs³ (1.14×) | 54.7 µs³ (1.22×) | 156 µs³ (3.5×) | **44.8 µs³** trie |
| table/update every 10th/first | 1,000 | **21.6 µs³** | 23.9 µs³ (1.11×) | 511 µs³ (24×) | 26.5 µs³ (1.23×) trie |
| table/update every 10th/first | 10,000 | **230 µs²³** | 247 µs²³ (1.08×) | 62.0 ms³ (270×) | 286 µs²³ (1.25×) trie |
| table/update every 10th/steady | 1,000 | **29.0 µs³** | 32.4 µs²³ (1.12×) | 644 µs³ (22×) | 33.2 µs²³ (1.15×) trie |
| table/update every 10th/steady | 10,000 | 298 µs²³ (1.10×) | **272 µs³** | 64.5 ms²³ (238×) | 415 µs²³ (1.53×) trie |
| table/swap/first | 1,000 | 4.45 µs²³ (1.30×) | 4.55 µs²³ (1.33×) | 15.7 µs³ (4.6×) | **3.42 µs³** trie |
| table/swap/first | 10,000 | 42.7 µs³ (1.10×) | 45.0 µs³ (1.16×) | 195 µs³ (5.0×) | **38.9 µs³** trie |
| table/swap/steady | 1,000 | **3.37 µs³** | 3.90 µs²³ (1.16×) | 14.7 µs³ (4.4×) | 3.40 µs³ (1.01×) trie |
| table/swap/steady | 10,000 | **38.5 µs³** | 42.1 µs³ (1.09×) | 197 µs²³ (5.1×) | 40.2 µs³ (1.05×) trie |
| table/remove one/first | 1,000 | 14.4 µs³ (1.00×) | **14.3 µs³** | 516 µs³ (36×) | 19.9 µs³ (1.39×) trie |
| table/remove one/first | 10,000 | 236 µs³ (1.01×) | **233 µs²³** | 60.1 ms³ (258×) | 270 µs²³ (1.16×) trie |
| table/remove one + add one/steady | 1,000 | 26.1 µs³ (1.01×) | 25.8 µs³ (1.00×) | 601 µs³ (23×) | **25.8 µs³** trie |
| table/remove one + add one/steady | 10,000 | **211 µs²³** | 218 µs²³ (1.03×) | 59.8 ms³ (283×) | 227 µs²³ (1.07×) trie |
| table/append 1000/first | 1,000 | 47.8 µs³ (1.31×) | **36.5 µs³** | 49.0 µs³ (1.34×) | 46.0 µs³ (1.26×) trie |
| table/append 1000/first | 10,000 | 83.7 µs³ (1.27×) | **66.0 µs³** | 243 µs²³ (3.7×) | 79.6 µs³ (1.21×) trie |
| table/select/steady | 1,000 | **2.87 µs³** | 3.15 µs³ (1.10×) | 6.34 µs³ (2.2×) | 3.38 µs³ (1.18×) trie |
| table/select/steady | 10,000 | **27.0 µs³** | 32.5 µs³ (1.20×) | 60.9 µs³ (2.3×) | 38.5 µs³ (1.43×) trie |
| decoded/decode | 10,000 | 3.46 ms³ (1.03×) | 4.14 ms³ (1.23×) | 3.37 ms³ (1.01×) | **3.35 ms³** trie |
| decoded/count (foldl) | 10,000 | 34.1 µs³ (1.03×) | **33.0 µs³** | 56.4 ms³ (1,708×) | 80.4 µs³ (2.4×) trie |
| decoded/total (foldl) | 10,000 | 59.0 µs³ (1.08×) | **54.4 µs³** | 65.8 ms³ (1,208×) | 108 µs³ (2.0×) trie |
| decoded/filter | 10,000 | **68.9 µs³** | 69.0 µs³ (1.00×) | 62.6 ms³ (909×) | 130 µs³ (1.89×) trie |
| decoded/sort + slice 20 | 10,000 | 2.41 ms³ (1.08×) | 2.33 ms³ (1.04×) | 2.40 ms³ (1.07×) | **2.24 ms³** trie |
| decoded/1000 binary searches | 10,000 | **210 µs³** | 229 µs³ (1.09×) | 311 ms³ (1,480×) | 263 µs³ (1.25×) trie |
| decoded/page of 50 by get | 10,000 | **277 ns²³** | 348 ns²³ (1.26×) | 961 µs³ (3,475×) | 280 ns²³ (1.01×) trie |
| grid/make | 10,000 | 61.0 µs³ (1.62×) | 65.7 µs³ (1.74×) | **37.7 µs³** | 78.8 µs³ (2.1×) trie |
| grid/tick k=1/first | 10,000 | 9.24 µs³ (30×) | 8.98 µs²³ (29×) | 142 µs³ (456×) | **311 ns³** trie |
| grid/tick k=1/steady | 10,000 | 314 ns²³ (1.06×) | 297 ns²³ (1.01×) | 128 µs³ (433×) | **295 ns²³** trie |
| grid/tick k=100/first | 10,000 | 32.7 µs³ (1.26×) | 34.8 µs³ (1.35×) | 25.0 ms²³ (966×) | **25.9 µs³** trie |
| grid/tick k=100/steady | 10,000 | 27.8 µs²³ (1.04×) | 28.1 µs³ (1.05×) | 23.5 ms³ (879×) | **26.8 µs³** trie |
| grid/life step | 10,000 | **1.10 ms³** | 1.11 ms²³ (1.01×) | 1.55 s²³ (1,409×) | 1.48 ms²³ (1.35×) trie |
| build/collect by push | 1,000 | 21.9 µs³ (1.19×) | **18.4 µs³** | 2.10 ms³ (114×) | 21.3 µs³ (1.16×) funkia |
| build/histogram of 100 000 | 1,000 | 6.92 ms³ (1.18×) | **5.87 ms³** | 391 ms³ (67×) | 6.65 ms³ (1.13×) trie |
| build/coin-change table | 1,000 | **50.8 µs³** | 57.5 µs³ (1.13×) | 7.52 ms³ (148×) | 70.5 µs³ (1.39×) trie |
| history/edit/first | 10,000 | 9.04 µs²³ (74×) | 9.46 µs³ (77×) | 17.1 µs³ (139×) | **123 ns²³** trie |
| history/edit/steady | 10,000 | 601 ns²³ (1.23×) | 496 ns²³ (1.01×) | 30.7 µs²³ (63×) | **490 ns²³** trie |
| history/undo 100 | 10,000 | 58.8 µs³ (1.50×) | 47.9 µs³ (1.22×) | 176 ms³ (4,487×) | **39.2 µs³** trie |
| interop/toJs/mapped | 10,000 | 7.0 ns²³ (1.00×) | **7.0 ns²³** | 43.8 µs³ (6,287×) | 15.0 µs²³ (2,158×) trie |
| interop/JSON.stringify/mapped | 10,000 | **1.09 ms³** | 1.10 ms³ (1.01×) | 1.15 ms³ (1.05×) | 1.18 ms³ (1.08×) trie |
| interop/Math.max/mapped | 10,000 | **39.6 µs³** | 39.7 µs³ (1.00×) | 98.3 µs³ (2.5×) | 45.8 µs³ (1.16×) trie |
| interop/html list/mapped | 10,000 | 1.04 ms³ (1.17×) | **893 µs³** | 1.08 ms³ (1.21×) | 896 µs³ (1.00×) trie |
| interop/toJs/edited | 10,000 | **11.8 µs³** | 16.9 µs³ (1.43×) | 55.6 µs³ (4.7×) | 15.7 µs²³ (1.33×) trie |
| interop/JSON.stringify/edited | 10,000 | 1.22 ms³ (1.14×) | 1.18 ms³ (1.09×) | **1.07 ms³** | 1.11 ms³ (1.04×) funkia |
| interop/Math.max/edited | 10,000 | **45.2 µs³** | 48.0 µs³ (1.06×) | 95.3 µs³ (2.1×) | 47.9 µs³ (1.06×) trie |
| interop/html list/edited | 10,000 | 1.00 ms³ (1.11×) | 995 µs³ (1.10×) | 1.13 ms³ (1.26×) | **903 µs³** funkia |

**Rows within 1.5× of the row's best / over 3× / over 10×**

| table | rows | E1tp | E1t | cons |
|---|--:|--:|--:|--:|
| A. The list scenarios, Elm-style code | 30 | 1 / 21 / 2 | 2 / 22 / 18 | 26 / 2 / 2 |
| B. The list scenarios, array-first code (cons on its own Elm-style code) | 30 | 14 / 10 / 1 | 15 / 8 / 1 | 24 / 2 / 2 |
| C. The single operations, array-first (cons on its own Elm-style code) | 23 | 17 / 6 / 4 | 16 / 6 / 4 | 3 / 18 / 14 |
| D. §15's array scenarios (indexed code) | 47 | 43 / 2 / 2 | 44 / 2 / 2 | 8 / 35 / 25 |
