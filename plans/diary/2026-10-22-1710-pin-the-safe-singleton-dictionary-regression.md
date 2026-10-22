# Pin the safe singleton dictionary regression

The stop reported on #210 and #759 has a red ownership fixture: one fresh
Dict key holds a tuple and a fresh list, and Dict.update appends to that
list without retaining any old version. Its hidden-flag golden comes from
the earlier compiler, which accepts the program. The current compiler
refuses it as a checker limit. The fixture's platform token forces the
hidden flag, and the pending index records the ownership mismatch.

No checker fix or copy is attempted after the owner's stop condition.
The genuine Ref copies remain pushed in draft #739; #210 remains open.
