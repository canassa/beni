## 2026-10-23 12:39 CEST — decoders and lambda answers keep their record condition (#420, #868)

**What I did.** Running the reactivity research's generated `beni-inline` apps for R6 found that
R4's enforcement refused them: `unique-components` and `big-component` at every size, on the
`exclusive` cause at the entry. Two precision fixes, both record-only: a decoder's answer
(`Json.decode`, `decodeValue`, a schema declaration's `parse`) holds no record twice when its
codec's decoded slot holds nothing the program made; and a lambda that answers a declaration's
function parameter (`edit list f = List.map list λrow → … f row …`) states `sep cb cb` and
`keep cb c` instead of losing the condition. `ownership/RecordContentsAnswered` pins both and a
captured row, refused. The two scenarios and `shared-components` check again at sizes 16, 64 and
128, seeds 1–3.

**What I learned.** A cross term between a parameter's answer and the element the callee hands
the lambda cannot be a `sep π[*] cb` atom: instantiating `cb` hands the actual `⊤` arguments. The
existing `keep cb c` says exactly what is needed (the answer is made, or the element handed), and
its instantiation already reads the actual's summary. Three research scenarios are still refused
under R4 (`big-table`'s `List.sortWith` and run-time `Schema.read`, `routed-app`'s base no
provenance names); they need their own fixes before R6's research checks cover them.
