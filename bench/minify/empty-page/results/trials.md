built/_main.mjs: raw 2262, gz 1106, br 978

| edit, alone | Δ raw | Δ gz | Δ br |
|---|--:|--:|--:|
| property renaming: a slot's `cx` → `c` | 0 | +2 | +2 |
| property renaming: the program record's `init`/`update`/`view` → `i`/`u`/`v` | -25 | -13 | +1 |
| `const` → `let` everywhere | -72 | -16 | 0 |
| `const` → `let` in the emitted half only | -2 | -2 | +7 |
| `(a)=>` → `a=>` in the emitted half | -2 | -1 | -2 |
| a kind's unused parameters dropped: `m:(b,d)=>` → `m:()=>`, `p:(f,g)=>` → `p:()=>` | -6 | -6 | -5 |
| shorthand `e:e` → `e` in the emitted instance | -2 | -1 | +5 |
| the emitted const run's newlines dropped | -4 | -4 | -4 |
| the emitted half's statement newlines dropped | -5 | -4 | -4 |
| `parent` (a host global, never renamed) → a renamed name | -16 | -2 | +8 |
| `cx` (a shorthand key, never renamed) → a renamed name | +3 | +3 | +3 |
| `document` locals (a host global, never renamed) → a renamed name | -36 | -1 | +7 |
| `x!==null?x:y` → `x??y` (first, last, parentOf) | -30 | -7 | -6 |
| `s.u!==null&&s.u.length!==0` → `s.u?.length` | -30 | -7 | +2 |
| `!==null` → `!=null` everywhere | -9 | +2 | +9 |
| `===null` → `==null` everywhere | -6 | -3 | +11 |
| `T.$$root!==undefined` → `T.$$root` | -12 | -8 | -3 |
| `false`/`true` → `!1`/`!0` | -23 | -3 | +15 |
| `let L=[];let M=false;let N=null;` joined | -8 | -3 | +8 |
| `}\n` → `};` (three block ends before a statement) | 0 | -4 | -3 |
| mount's first render calls `Z()` instead of repeating it | -11 | +1 | +2 |
| `for(;;)` loops of put and drop as `do…while` | -10 | +18 | +27 |
| template: `flags&2` peeled before the `flags&4` test | +2 | 0 | +8 |
| the export as `export{O as flush}` → `flush` named at declaration | +7 | -2 | +9 |

steps/24-nothing-observable.mjs: raw 285, gz 215, br 163

| edit, alone | Δ raw | Δ gz | Δ br |
|---|--:|--:|--:|
| `insertBefore(x,null)` → `appendChild(x)` | -6 | -3 | -6 |
| `S===null` → `!S` (twice) | -12 | -3 | -2 |
| one `let D=globalThis.document` | -14 | +2 | +19 |
| the error thrown from a conditional message built first | +10 | -3 | -1 |
| `export let flush=()=>{}` → `let N=()=>{};…export{N as flush}` | +8 | +7 | +17 |

