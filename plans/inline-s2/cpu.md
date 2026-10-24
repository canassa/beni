# S2 target — CPU, indicative only

`./rr bench`'s event timing (`harness/bench/big-table.js`'s actions, script µs, median), quick mode
(2 warm-up and 5 measured reps per half), big-table N = 1, seed 1, 1 000 rows, one Chrome, the apps
interleaved and the order reversed every round (`tools/bench.mjs`). Host: 32 cores, load 8–28 from
other sessions during the runs, so a ratio moves by ±30 % between runs. Only directions that held in
every run are read in `docs/design/browser-inline.md` §9.7; the slice's bar is measured by the full
method on a quiet machine (§9.9, S2e). Measured 2026-10-25.

Variants: `vanilla` and `tea` are the research project's emitters as they are; `s2` is the target
before edits at the write (`gdlyvhc`: `updateEvery` and `serverUpdate` edited from their `{*}` tag,
append reconciled); `s2w`/`s2pos` the target with edits at the write and the decided index
(`gdlyvhcw`); `s2pair` the same with the pair index (`gdlyvhcwp`).

## Run 1 (2 rounds; `s2` before edits at the write)

    event	vanilla µs	tea µs	s2 µs	tea/vanilla	s2/vanilla
    create 1000 rows	5438	5113	4571	0.94	0.84
    clear 1000 rows	4257	3491	3233	0.82	0.76
    replace 1000 rows	9070	8126	8473	0.90	0.93
    update every 10th row of 10000	2197	3729	8532	1.70	3.88
    select row 2	49	40	48	0.82	0.99
    select row 3	56	42	48	0.74	0.86
    swap rows	83	98	89	1.17	1.07
    swap rows back	87	98	81	1.13	0.94
    remove the 4th row	103	75	105	0.72	1.02
    create 10000 rows	47341	48395	52236	1.02	1.10
    09 clear 10000 rows	36875	32564	33449	0.88	0.91
    append 1000 rows to 10000	4814	4787	6193	0.99	1.29
    serverUpdate of 10 rows	191	197	631	1.03	3.30
    serverUpdate of 10 rows back	151	143	629	0.95	4.18
    dispatch: whole-state snapshot	1635	2908	3199	1.78	1.96
    dispatch: whole-state snapshot (again)	1492	2607	3139	1.75	2.10

## Run 2 (2 rounds; edits at the write, decided index)

    event	vanilla µs	tea µs	s2 µs	tea/vanilla	s2/vanilla
    create 1000 rows	4152	4320	4600	1.04	1.11
    clear 1000 rows	3161	3528	3321	1.12	1.05
    replace 1000 rows	6916	7298	7599	1.06	1.10
    update every 10th row of 10000	1577	3455	3759	2.19	2.38
    select row 3	29	42	40	1.47	1.39
    select row 2	25	45	42	1.80	1.68
    swap rows	62	80	81	1.28	1.30
    swap rows back	64	81	77	1.26	1.20
    remove the 4th row	62	69	96	1.12	1.55
    create 10000 rows	41094	44915	48327	1.09	1.18
    09 clear 10000 rows	31999	32833	32261	1.03	1.01
    append 1000 rows to 10000	4390	4553	4449	1.04	1.01
    serverUpdate of 10 rows	127	139	158	1.09	1.24
    serverUpdate of 10 rows back	125	137	134	1.09	1.07
    dispatch: whole-state snapshot	1144	2585	2740	2.26	2.40
    dispatch: whole-state snapshot (again)	1168	2575	2498	2.21	2.14

## Run 3 (3 rounds; both indexes)

    event	vanilla µs	tea µs	s2pos µs	s2pair µs	tea/vanilla	s2pos/vanilla	s2pair/vanilla
    create 1000 rows	4361	4380	4861	5955	1.00	1.11	1.37
    clear 1000 rows	3277	3178	3584	4491	0.97	1.09	1.37
    replace 1000 rows	7365	7869	7937	15196	1.07	1.08	2.06
    update every 10th row of 10000	1558	3422	4050	6900	2.20	2.60	4.43
    select row 3	41	42	46	73	1.02	1.11	1.77
    select row 2	40	46	47	70	1.14	1.16	1.75
    swap rows	66	105	97	128	1.59	1.47	1.94
    swap rows back	66	97	99	137	1.47	1.50	2.08
    remove the 4th row	63	76	117	100	1.21	1.86	1.59
    create 10000 rows	38651	49536	52607	55209	1.28	1.36	1.43
    09 clear 10000 rows	33265	32802	34464	35529	0.99	1.04	1.07
    append 1000 rows to 10000	4577	4832	4613	4841	1.06	1.01	1.06
    serverUpdate of 10 rows	153	186	171	165	1.22	1.12	1.08
    serverUpdate of 10 rows back	128	177	150	142	1.38	1.17	1.11
    dispatch: whole-state snapshot	1256	2705	3050	3277	2.15	2.43	2.61
    dispatch: whole-state snapshot (again)	1192	2716	3185	3462	2.28	2.67	2.90

## The removal, alone (`tools/micro.mjs`, Node 24)

One removal of the 4th of 1 000 entries and its reinsertion, per iteration:

    Dict.remove(4th) + reinsert, decided index (key → position, eager reindex)   20.06 µs
    pair index (key → entry; native indexOf)                                      1.42 µs
    array findIndex + splice + reinsert (tea-inline's)                            1.39 µs
    10 000 entries, decided index                                                265.97 µs

A removal is half of each line: about 10 µs at 1 000 entries and 130 µs at 10 000 for the decided
index, about 0.7 µs for the pair index.
