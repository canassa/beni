module Controls
  contract wrapN: res ε fresh, [*] π2ε; nondup ⇐ all
  slotacct wrapN: source 27, total 317, growth 0 of 65536, continuation 317 of 27648, rounds 2, evaluations 3, validation 124, slots 3, arrivals 2, relations 2 (memo 0), deliveries 2, substitutions 6, positions 8, leaves 18, values 26, calls 9, demands 0, peak bytes 12924, v2 reads 0, walks { 68, 125, 124 }
    14:10 List.push l0: rejected alias: l0 holds it and is read at 15:7
  contract push: res .0 fresh, .0[*] π2ε, .1 fresh, .1[*] π2ε fresh; nondup no; NOT VALIDATED; forced claim refused by the validator
  slotacct push: source 33, total 273, growth 0 of 65536, continuation 273 of 33792, rounds 0, evaluations 1, validation 0, slots 5, arrivals 5, relations 3 (memo 0), deliveries 0, substitutions 15, positions 4, leaves 8, values 7, calls 2, demands 1, peak bytes 12984, v2 reads 0, walks { 273 }
    21:5 List.push l0: accepted call
  contract pushOnce: res ε fresh, [*] π2ε fresh; nondup ⇐ sel π2{ε}
  slotacct pushOnce: source 23, total 178, growth 0 of 65536, continuation 178 of 23552, rounds 0, evaluations 1, validation 0, slots 3, arrivals 3, relations 1 (memo 0), deliveries 0, substitutions 15, positions 4, leaves 7, values 6, calls 2, demands 1, peak bytes 6372, v2 reads 0, walks { 178 }
  contract deepLen: res crossing; nondup ⇐ all
  slotacct deepLen: source 25, total 160, growth 0 of 65536, continuation 160 of 25600, rounds 2, evaluations 3, validation 44, slots 3, arrivals 0, relations 0 (memo 0), deliveries 2, substitutions 0, positions 12, leaves 0, values 27, calls 3, demands 0, peak bytes 2980, v2 reads 0, walks { 72, 44, 44 }
    47:13 List.push kids: rejected alias: w holds it and is read at 47:43
  contract readAfter: res .0#0.0 π1ε, .0#0.0[*]#0.0 π1[*]#0.0, .0#0.0[*]⟲#0.0 π1[*]#0.0⟲; nondup ⇐ sel π1{ε,[*]#0.0,[*]#0.0⟲}
  slotacct readAfter: source 23, total 365, growth 0 of 65536, continuation 365 of 23552, rounds 0, evaluations 1, validation 0, slots 6, arrivals 3, relations 4 (memo 0), deliveries 0, substitutions 20, positions 2, leaves 5, values 7, calls 2, demands 1, peak bytes 6780, v2 reads 0, walks { 365 }
    54:16 List.push kids: accepted param
  contract readBefore: res .1#0.0 π1ε, .1#0.0[*]#0.0 π1[*]#0.0, .1#0.0[*]⟲#0.0 π1[*]#0.0⟲; nondup ⇐ sel π1{ε,[*]#0.0,[*]#0.0⟲}; writes π1ε; req yes
  slotacct readBefore: source 25, total 311, growth 0 of 65536, continuation 311 of 25600, rounds 0, evaluations 1, validation 0, slots 6, arrivals 3, relations 3 (memo 0), deliveries 0, substitutions 20, positions 2, leaves 4, values 7, calls 2, demands 1, peak bytes 6800, v2 reads 0, walks { 311 }
  slots module: v2 value-reader calls 0, imported contracts 0 (round trip mismatches 0)
  demands 0: accepted 0 (fresh 0, call 0, param 0, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 0
total 0: accepted 0 (fresh 0, call 0, param 0, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 0
