## 2026-11-05 17:47 CET — a label's answer handed on, and a step past a fold

**What I did.** #2036: a label's answer in another label's supply was never judged; three rules, `fresh` (`π{ε!}`), the kept check read the other way, a capture held for the next run, and a pass judged against what the callee holds. #2017 shown closed by an invariant asserted on every closed entry. #2042: a step past a non-regular type's fold read as a scalar, so a write made no demand and copied; it is now `⊤`.

**What I learned.** Each review of #2036 found a further route, and each "exemption" for precision opened one: `kept` does not show what a callee holds apart under `sep`, and a contract cannot tell a traversal from `[ h, …t ] → ( p h, t )`. #1979 and #2046 want the same fact recorded. An empty reading of a contract means "fresh" to a caller, so anything that loses a slot is a hole, not a refusal: `⊤` has to be open below its slot. #1978's prototype is in the issue, unfinished.
