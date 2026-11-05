# Research 110: how statically typed compile-to-JS languages keep their integer type sound

*Added to the repository 2026-11-05, for issue #1988, as the earlier research behind the owner's
decisions of that day. The text below is the report as written, kept whole, so its caveats stand:
**no language compiler was run** (§3.7), and **some [doc] quotes came through a page-extraction
model, not the raw page**, so re-check the wording of a [doc] quote before citing it verbatim. Its
§3.5 and §3.6 argue positions the owner has since settled: [`language.md`](../language.md) §13 is
what was decided, and this report is evidence, not contract. The "summary table above" that §1
names was in the message that carried the report and was not kept. Report 111 is the run-time hole
hunt that followed.*

Research report for beni, 2026-11-05.

| Label | Meaning |
|---|---|
| **[src]** | Read in the language's compiler or runtime source. Not run through that compiler. |
| **[doc]** | From official documentation. |
| **[issue]** | Read in an issue, PR or design thread. |
| **[run]** | The JS expression was run on Node 24.19 / V8 13.6, arm64 macOS. The language's compiler was **not** run. |
| **[U]** | Unverified: memory or a secondary source. |

Some [doc] quotes came through a page-extraction model, not the raw page, so re-check the wording before citing them verbatim. Text marked [src] or [issue] was read directly.

## 1. Comparison table

See the summary table above. These languages are not in it:

- **GHCJS:** assumed the same as GHC JS [U].
- **ClojureScript:** dynamic, so no static claim to break. `int` is `bit-or 0` and `quot` by zero is NaN by inspection.
- **TypeScript:** has no int type, only `number` and `bigint`.
- **MoonBit:** `Int` is 32-bit and `to_int` saturates with NaN→0. `/ 0` throws a bare `Error` on JS, and the backends diverge in an open issue.
- **GWT:** "will not wrap" for `int`; `long` is a lo/hi pair.
- **AssemblyScript and Grain:** Wasm targets, so out of scope.

## 2. Language by language

### 2.1 PureScript

Representation is a JS number in int32 range. [src]

```js
export const intAdd = function (x) { return function (y) { return (x + y) | 0; }; };
export const intMul = function (x) { return function (y) { return (x * y) | 0; }; };
export const pow = function (x) { return function (y) { return Math.pow(x, y) | 0; }; };
```

- **Multiplication is not exact wrapping.** `(0x7fffffff*0x7fffffff)|0` is 0, while `Math.imul` gives 1. They disagreed on 91.1% of a million random int32 pairs. [run] Values stay sound; low bits are wrong.
- **Power.** `pow 2 (-1)` = 0 and `pow 0 (-1)` = 0. `pow 3 40` = 689956864, while true wrapping gives 689956897. [run]
- **Division.** `intDiv` and `intMod` return 0 on zero; `quot` is `(x / y) | 0`. **`rem` is bare `x % y`, so `rem x 0` is NaN typed `Int`.** [src, expression run]
- **Float→Int.** "Values outside the `Int` range are clamped, `NaN` and `Infinity` values return 0." So ±Infinity goes to 0 while a huge finite value goes to `top`. `fromNumber :: Number -> Maybe Int` is the checked route. [src]

Rationale ([prelude#60](https://github.com/purescript/purescript-prelude/issues/60)) [issue]:

> michaelficarra: "Overflow or underflow on arithmetic operations is a program error, and I would prefer an immediate halt. Since we have no indication of the event at the JS level, I think the best we can do is leave it undefined."
>
> hdgarrood: "I guess that would be an unacceptable performance hit."

That cost was never measured in the thread. Their obstacle does not apply to a 53-bit double (§3.3).

### 2.2 ReScript and BuckleScript

"32-bits, truncated when necessary." [doc] The docs warn that binding JS numbers as `int` can lose data and recommend `float`, so a timestamp is a `float`.

```ocaml
let int32_add ?comment e1 e2 = to_int32 (float_add ?comment e1 e2)
| _ -> to_int32 (float_mul ?comment e1 e2)   (* int32_mul *)
| _ -> to_int32 (float_pow ?comment e1 e2)   (* int32_pow *)
```

- **Two powers disagree.** `**` is `(a ** b) | 0`, so `2 ** -1` = 0. `Math.Int.pow` is `external pow: (int, ~exp: int) => int = "Math.pow"`, so `Math.Int.pow(2, ~exp=-1)` is **0.5 typed `int`**. [src, run]
- **Multiplication** has PureScript's low-bit loss, except by constant powers of two. `Math.Int.imul` exists separately. [src]
- **Division by zero** throws `Division_by_zero`. [src] [#1760](https://github.com/rescript-lang/rescript/issues/1760) records BuckleScript optimising the exception away when the result was unused.
- **Float→Int** is `x | 0`: NaN and ±Inf give 0, and `1.7e12|0` is −807049216. [src, run]
- **`bigint`** arrived in 11.1. [doc]

### 2.3 Melange

`int` is a number; `int64` is "array of 2 elements [high, low]". [doc]

> "In Melange, integers are limited to 32 bits due to the fixed-width conversion of bitwise operations in JavaScript." … "When dealing with large numbers, it is advisable to use floats instead. For instance, floats are used in bindings like Js.Date."

`Division_by_zero` is raised in `caml_int32.ml`. [src]

**A leak** [src, `js_math.ml`]:

```ocaml
let floor_int f =
  if f > Int.toFloat Int.max then Int.max
  else if f < Int.toFloat Int.min then Int.min
  else unsafe_floor_int f
```

NaN fails both comparisons, so the result is NaN typed `int`. `ceil_int` has the same shape. The emit for `*` was not established.

### 2.4 js_of_ocaml

> "Most notably, integers are 32 bits (rather than 31 bits or 63 bits), which is their natural size in JavaScript" [doc]

- `caml_mul` is `Math.imul(a, b)`.
- `caml_div` is `if (y === 0) caml_raise_zero_divide(); return (x / y) | 0;`.
- `caml_int_of_float` goes through `to_int`.
- `Int64` is `MlInt64` with 24-, 24- and 16-bit limbs. [src]

This is the cleanest 32-bit design in the OCaml family.

### 2.5 Elm

Contract [doc]:

> "`Int` math is well-defined in the range `-2^31` to `2^31 - 1`. Outside of that range, the behavior is determined by the compilation target. When generating JavaScript, the safe range expands to `-(2^53 - 1)` to `2^53 - 1` for some operations, but if we generate WebAssembly some day, we would do the traditional integer overflow. This quirk is necessary to get good performance on quirky compilation targets."

Kernel [src]:

```js
var _Basics_mul = F2(function(a, b) { return a * b; });
var _Basics_idiv = F2(function(a, b) { return (a / b) | 0; });
var _Basics_pow = F2(Math.pow);
var _Basics_remainderBy = F2(function(b, a) { return a % b; });
function _Basics_truncate(n) { return n | 0; }
var _Basics_floor = Math.floor; var _Basics_round = Math.round;
```

- `modBy` calls `__Debug_crash(11)` on zero. `remainderBy 0` is NaN. `1 // 0` is 0. [src, run]
- **Mixed widths** ([#1003](https://github.com/elm/core/issues/1003)): "`truncate` truncates to 32bit, but `floor`, `ceil` and `round` don't. Operators: `//` truncates to 32bit, but `+`, `-`, `*`, `^`, `modBy`, `remainderBy` don't."
- **Timestamps.** [#1079](https://github.com/elm/core/issues/1079): `truncate <| t * 1000` "causes an overflow, giving times before 1970". `(2^48) // 2` is 0. [run]
- **Non-arithmetic leaks.** [#1150](https://github.com/elm/core/issues/1150): `Char.toCode` can return `NaN : Int`. [#1142](https://github.com/elm/core/issues/1142): `String.toInt "9007199254740991"` gives `…992`. `Json.Decode.int` accepts all finite whole numbers.

[#960](https://github.com/elm/core/issues/960) records beni's own leaning, unresolved since 2018: "`(^)` having a return type of `Float` would be better."

### 2.6 Gren

Inherits `_Basics_pow = F2(Math.pow)` and the same note. [src] [core#140](https://github.com/gren-lang/core/issues/140) is open, and [compiler#383](https://github.com/gren-lang/compiler/issues/383) shows `//` differing between its inlined and kernel forms. There is no fix to learn from yet.

### 2.7 Gleam: JavaScript versus Erlang

The difference is called out [doc]:

> "When running on the Erlang virtual machine ints have no maximum and minimum size." / "When running on JavaScript runtimes ints are represented using JavaScript's 64 bit floating point numbers."
>
> "When running on the BEAM any overflow will raise an error." "So there is no `NaN` or `Infinity` float value in the Erlang runtime." "Division by zero will not overflow, but is instead defined to be zero."

```js
export function remainderInt(a, b) { if (b === 0) { return 0; } else { return a % b; } }
export function divideInt(a, b) { return Math.trunc(divideFloat(a, b)); }
```

- **`Math.trunc`, not `|0`:** division works across 53 bits. This is the right shape for beni. `int.divide` and friends return `Result`. [src]
- **Power.** `pub fn power(base: Int, of exponent: Float) -> Result(Float, Nil)`. Failure is a value. But `float.power` rejects only imaginary results and zero base with negative exponent, so overflow yields `Ok(Infinity)` despite the FFI comment. [src, not run]
- **Holes.** `float.truncate` is `Math.trunc(float)` typed `Int`, and `Math.trunc(Infinity)` is Infinity. `parse_int` has no range check. [src, run]
- **Literals.** The compiler warns outside the safe range (changelog v1.6). [doc]
- **BigInt refused** ([#2853](https://github.com/gleam-lang/gleam/issues/2853)): "Because they are very slow and break interop."

### 2.8 Fable

> "we use F# numeric types, which are all translated to JS Number (64-bit floating type) at the exception of `int64`, `uint64`, `bigint` and `decimal`." [doc]

- `+ - *` are bare `binOp`. Division is `~~(a/b)`. `%` is bare. `int x` is `~~x`. [src]
- `"PowInteger"` goes to `Math.pow`, so `pown 2 -1` looks like 0.5 typed `int`. [src, not run]
- Rationale ([#1541](https://github.com/fable-compiler/Fable/issues/1541)): "one of the original guidelines of Fable was to output readable JS and add minimal overhead." The outcome was documentation, not a fix.
- `int64` is BigInt since 4.0.5. [doc]

### 2.9 Scala.js

- `Int_+` is `or0`, `Int_*` is `ImulBuiltin`, and division goes through `checkIntDivisor`, elided for non-zero literals. [src]
- Double→Int: `If(x > 2147483647, 2147483647, If(x < -2147483648, -2147483648, x | 0))`. [src]
- [#3544](https://github.com/scala-js/scala-js/pull/3544): "this one has always been problematic, because Scala as a language and a type system do nothing to guard against it."

`Long` is a flattened lo/hi pair ([#5205](https://github.com/scala-js/scala-js/pull/5205)), with a `useBigIntForLongs` path. [src] Performance evidence:

| Source | Finding |
|---|---|
| [Fast 64-Bit Integers for the JavaScript Platform](https://lively-kernel.org/lively4S2/testdir/ecoop18-paper22.pdf) (anonymised draft; link to Doeraene is inferred) | "outperforms that of GWT, TeaVM and Kotlin by 3.6x to 60x and is only 3–5x slower than Ints". SHA-512: 2.9x slower on Chrome, 4.9x on Firefox. Before it, "one to two orders of magnitude slower". |
| [proposal-bigint#117](https://github.com/tc39/proposal-bigint/issues/117), 2018 | BigInt `Long` "a whopping 60 times slower"; V8 replied this was plausible and might be optimised. Stale: see §3.4. |
| #5205 | Bounce benchmark 37.3 → 33.4, "a strong 10% performance improvement". |
| [1.20.2](https://www.scala-js.org/news/2026/01/05/announcing-scalajs-1.20.2/) | Division and remainder "3x speedup". |

### 2.10 Kotlin/JS

"Kotlin preserves overflow semantics for `kotlin.Int`…" [doc] `Long` maps to BigInt on ES2020, which is experimental.

- `transformAdd` applies `toInt32` only under `canAddOrSubOverflow()`, so **the `|0` is dropped when the compiler can show it is unneeded**. `*` uses `jsImul`. [src]
- [PR #6382](https://github.com/JetBrains/kotlin/pull/6382): "Previously, division by zero in generated JavaScript followed JS behavior and did not throw as expected".
- `doubleToInt` saturates. `toInt` "Returns zero if this Double value is NaN", but `roundToInt` has "@throws IllegalArgumentException when this value is `NaN`". One library makes both choices. [src, doc]
- Only `Double.pow` exists in the JS math file. [src]
- [PR #6450](https://github.com/JetBrains/kotlin/pull/6450) adopts Scala.js's algorithms, citing an ARITH 2026 paper I could not find.

### 2.11 Dart (dart2js), the key case

[doc]:

> Native: "64-bit two's complement integers with operations that wrap to that range on overflow."
>
> Web: "An `int` on the web is represented as a double-precision floating-point value with no fractional part." "On the web, these values do not overflow because they are represented differently." "the bitwise operators truncate their operands to 32-bit integers when compiled to JavaScript." "For efficiency, Dart maps both `int` and `double` to this single representation."

Dart 2 design (informal spec, background material) [doc]:

> "On the VM, almost every number-operation must check if the result overflowed … This blows up the executable and generally slows down the code."
>
> "Dart 2.0's integers wrap around". Chosen over "saturation, unspecified behavior, or exceptions". Throwing would be reevaluated only with "convincing numbers".
>
> "We expect dart2js to continue mapping to JavaScript's numbers, which means that dart2js would continue to be non-compliant."

The type is open, and the maintainers know [issue]:

- [sdk#43325](https://github.com/dart-lang/sdk/issues/43325): "Infinity is int in dart2js". Excluding it "would necessarily be slower", and "We may actually *want* infinity to be an `int` because we want it to ensure that `int + int` and `int * int` are guaranteed to evaluate to an `int`".
- [sdk#43389](https://github.com/dart-lang/sdk/issues/43389): `x - x` on Infinity is NaN, and `n is int` folds to true. "You got a NaN, which is like the double version of throwing an `Error`."
- [sdk#46852](https://github.com/dart-lang/sdk/issues/46852): NaN accepted as an index.
- [sdk#64491](https://github.com/dart-lang/sdk/issues/64491): the 53-bit bounds are defined privately across 10 internal files.

#43389's shape, a compiler trusting a false invariant, is a real risk for beni.

Conversions throw [src]:

```dart
int toInt() {
  if (this >= _MIN_INT32 && this <= _MAX_INT32) { return JS('int', '# | 0', this); }
  if (JS('bool', r'isFinite(#)', this)) {
    return JS('int', r'# + 0', truncateToDouble()); // Converts -0.0 to +0.0.
  }
  throw UnsupportedError(JS('String', '"" + # + ".toInt()"', this));
}
```

This is a useful template: an int32 fast path, a general path, and `+ 0` for `-0`.

`~/` throws `UnsupportedError`. `%` has no zero check on the path read, so `5 % 0` is NaN. [src; dart2js not run] `pow(num, num)` is `Math.pow`. Its shared doc claims "always equal to the mathematical result", which cannot hold on doubles. [src]

### 2.12 Haxe

> "For performance reasons, the Haxe Compiler does not enforce any overflow behavior." "The burden of checking for overflows falls to the target platform." [doc]

- "The result of a division is always a Float; use Std.int(a / b)". [doc] This is the cleanest division in the survey.
- `Std.int` is `(cast x) | 0`. [src] `Math.pow` is Float only.
- `Math.floor(v:Float):Int` on NaN or Infinity: "the result is unspecified." [doc]
- `haxe.Int32` is the opt-in, with `clamp` and `Math.imul`. [src]

### 2.13 ClojureScript

`int` is `(bit-or x 0)`; `long` is `fix`. `integer?` excludes NaN and Infinity explicitly. [src]

### 2.14 GHC JS backend, GHCJS

```haskell
IntAddOp -> r |= toI32 (Add x y)
IntMulOp -> r |= app hdMulImulStr [x, y]
DoubleToIntOp -> r |= toI32 x
```

`Int#` is a "number in Int32 range"; `Int64#` is two 32-bit numbers. [src, doc] So `Int` is 32-bit on JS. `GHC.Internal.Real` checks `b == 0 = divZeroError` and has `x0 ^ y0 | y0 < 0 = errorWithoutStackTrace "Negative exponent"`. [src]

**Naming:** in Haskell, `^` is the integer power and `^^` is the variant needing a `Fractional` base. [src for `^`, otherwise U] Beni's `^^` would nearly reverse that.

### 2.15 Idris 2

- `jsIntKind IntType = Just . Signed $ P 32`, superseding [#801](https://github.com/idris-lang/Idris2/issues/801). `_truncInt32 = x => x & 0xffffffff`. [src]
- `Double → Integer` is `BigInt(Math.trunc(x))`, which throws RangeError on NaN and Infinity. [src, run]
- `power : Nat -> Nat -> Nat` excludes negative exponents by type. [src]
- `div` on `Int` uses a non-covering `case y == 0 of False => …`. [src]

### 2.16 TypeScript

`number` and `bigint` only [U, uncontroversial]. `new Array(1.5)` throws `RangeError: Invalid array length`. [run]

### 2.17 Other deliberate choices

**Nim is the only surveyed language that traps on JS** [src]:

```nim
proc checkOverflowInt(a: int) {.asmNoStackFrame, compilerproc.} =
  {.emit: """ if (`a` > 2147483647 || `a` < -2147483648) `raiseOverflow`(); """.}
proc addInt(a, b: int): int {.asmNoStackFrame, compilerproc.} =
  {.emit: """ var result = `a` + `b`; `checkOverflowInt`(result); return result; """.}
```

`optOverflowCheck` selects the checked form, and `-d:danger` "Turns off all runtime checks". [doc] `OverflowDefect` is a defect, matching beni's constraint (b). The bound is 32-bit. Power takes `y: Natural`. No performance data was found. `divInt` tests `a == 2147483647`, which looks like the wrong edge for `MIN / -1`.

**MoonBit:** [core#4622](https://github.com/moonbitlang/core/issues/4622) (open) says "`/ 0`, `% 0`, `MIN / -1` have no contract": native gives 0, JS throws, wasm-gc traps. This is what leaving it to each backend produces.

**GWT:** "overflowing an integral data type … will not wrap". [doc]

### 2.18 AssemblyScript and Grain

AssemblyScript compiles to Wasm. [doc] Grain was not researched; I believe it also targets Wasm. [U]

### 2.19 Non-JS prior art

- **Swift:** "arithmetic operators in Swift don't overflow by default. Overflow behavior is trapped and reported as an error." `&+` opts out. [doc]
- **Rust RFC 560:** overflow is a program error, but "these checks will be compiled out whenever an optimized build is produced, so final code will not pay a performance penalty." [doc]
- **Rust 1.45:** `as` became "a 'saturating cast'", and "NaN produces zero", after [#10184](https://github.com/rust-lang/rust/issues/10184) ran from 2013 to 2020. [doc]
- **Roc:** `plus`, `plus_wrap`, `plus_try`, `plus_saturated`; `pow_try : … -> Try(I64, [Overflow, Underflow])`; `div_try`; `to_i64_try`, `to_i64_wrap`. [doc] The default crashes and every operation has explicit spellings. **This family is the design to copy.**
- **Check cost, native:** [Regehr](https://blog.regehr.org/archives/1384) reports 11.8% on SPEC CINT 2006, 8.7% after patches, mostly blocked vectorisation. [Dan Luu](https://danluu.com/integer-overflow/) estimates a few percent. [secondary summary] **No measurement of a checked Int on a JS JIT was found anywhere.**

## 3. Synthesis

### 3.1 Strategies

| # | Strategy | Who | Sound? | 53-bit timestamps? | Cost |
|---|---|---|---|---|---|
| A | Wrap to int32 | PureScript, ReScript, Melange, jsoo, Scala.js, Kotlin, GHC JS, Idris, MoonBit | Yes, if every primitive is covered | **No** | Near zero |
| B | Double, unchecked | Elm, Gren, Gleam, Dart, Haxe, Fable | **No** | Yes | Zero |
| C | Double, range-checked | Nim, 32-bit bound | Yes | **Nobody has shipped it at 53 bits** | Branch per op, unmeasured on UI |
| D | Emulated 64-bit | Scala.js, Kotlin, Fable, Idris `Bits64`, Nim `--jsbigint64` | Yes | Yes | 3–5× Int at best; interop cost |
| E | Arbitrary precision | Idris `Integer`, ReScript `bigint`, Gleam `bigi` | Yes | Yes | Slowest; breaks JSON |
| F | Refuse by type, or failure value | Gleam, PureScript `fromNumber`, Roc, Nim, Idris, Rust, Haxe `/` | Yes, per operation | n/a | Ergonomic |

### 3.2 Holes the brief did not list

1. **`-0 : Int`.** `0 * -1`, `-4 % 2`, `Math.round(-0.4)`, `Math.ceil(-0.5)` and `Math.trunc(-0.5)` all give `-0`. [run] `===`, `String`, `JSON.stringify` and `Map` treat it as 0, so the visible route is `1 / toFloat x`. Fix: `toFloat` emits `x + 0`.
2. **`Math.pow|0` and `(a*b)|0` are not correct 32-bit operations.** [run]
3. **`%` by zero gives NaN** in Elm, PureScript `rem` and Fable. Check beni for this. [not read for beni]
4. **`(a / b) | 0`** causes the Elm timestamp bugs. `Math.trunc(a / b)` had 0 errors over 4M random cases near 2^53 plus an adversarial `q*b-1` sweep of up to 4M. [run; random test, not a proof]
5. **Non-arithmetic sources:** literals, `String.toInt`, JSON and `schema` decoders, `Char.toCode`, `foreign` returns, host values.

### 3.3 The trap can be exact

For safe operands, `|r| ≤ 2^53−1` after `+ - *` is an exact test. If the true result is in range, it is representable, so `r` is exact. If its magnitude is at least 2^53, monotonic rounding keeps `|r|` at least 2^53. A 6M-operation random test against BigInt gave 0 misclassifications. [run]

### 3.4 Measurements

**Indicative only.** Runs were bimodal: unchanged `Math.imul` code gave 1.1 ns in one file and 5.9 ns in another. The cause was not established; performance versus efficiency cores is a guess. [U] Figures are minimums over repeats, in ns/op, except the record row, which is a median.

| Loop body | ns/op |
|---|---:|
| `s = s + a[i]` | 0.95 |
| `s = (s + a[i]) \| 0` | 0.89 |
| add with range check | 1.56–1.70 |
| add with range check, values ≈ 2^40 | 1.53–1.70 (plain 0.92–0.95) |
| `BigInt.asIntN(64, …)` | 2.80–2.85, about 3× and not 60× |
| `Math.floor` | 0.93–0.95 |
| `Math.floor` with saturation | 4.23–4.27, unexplained, likely an artefact |
| `{...o, a: x}`, small / ≈1.7e12 | 8.9 / 10.2 |

These numbers support two things: the check is not free in a tight loop, and BigInt has improved. They say nothing about UI cost. Rule 8 requires js-framework-benchmark against Solid 2.

With pointer compression, Smis are 31-bit: "limiting the Smi payload to 31 bits". [doc] So values of 2^30 and above are boxed in record fields whatever beni does. Whether TurboFan folds the range test on values it knows are int32 **was not determined and is the best next measurement.**

### 3.5 Assessment of the leaning

**`^ : number, number → Float`: supported.** Gleam, Kotlin, Scala and Haxe all return a float, and it is the fix proposed on elm/core#960. The cost is that `2 ^ 10 : Int` stops compiling, which is a compile-time error fixable by migration. Elm never shipped it, but no thread gives a technical objection.

**`^^ : Int, Int → Int`: partly supported.**
- The operation is needed.
- The name is a trap for Haskell readers. Prefer `Int.pow`.
- "Rounds toward zero" has no deliberate precedent. PureScript and ReScript `**` do it as a `|0` side effect. Designs that thought about it refuse the input (Rust, Nim, Idris, Haskell, Gleam, Roc), and Dart returns a double.
- It can still be defended by defining `x ^^ (-n) = 1 // (x ^^ n)`, so `0 ^^ (-n)` inherits `1 // 0`.
- Offer a `Maybe` form alongside it.
- Use repeated multiplication with `*`'s check, not `Math.pow|0`. `Math.pow` was exact on all 8,553 cases with base ≤ 2000 in the safe range on V8 [run], but the spec calls it implementation-approximated [U], and other engines were not tested.

**Saturating conversions: supported, with amendments.** Scala.js, Kotlin, MoonBit and Rust agree on NaN→0.

Counter-evidence:
- PureScript sends ±Inf to 0, and Dart throws.
- Kotlin's `roundToInt` throws on NaN.
- Roc offers only `_try` and `_wrap`.
- `round NaN = 0` is a silent wrong answer under rule 7.
- It sits awkwardly beside a trapping `+`. The honest distinction is that `round` is declared lossy and NaN has no answer, while `+` has an answer that does not fit.

Amendments: bound at ±(2^53−1), and add a `Maybe` form.

**Trap on overflow: supported on soundness, unsupported on cost, and the owner's decision.**

For:
- It is the only way to keep (a) and soundness together.
- The check is exact.
- Swift, Roc and Nim show the shape.
- It stops `NaN` reaching `eq` and `Dict`.

Against:
- Nobody has shipped it at 53 bits or measured it on JS UI.
- Rust compiles it out of release builds. Dart wanted "convincing numbers". Haxe cites performance.
- Code size is unpriced for a language with 1.4 kB pages.
- It changes the promise. Overflow from user input, such as `quantity * price`, is not obviously a program defect, yet rule 9 would show a crash screen.

| Option | Sound? | Cost | Silent wrong answer? |
|---|---|---|---|
| Trap on `+ - *` | Yes, exact | Branch per op | No |
| Check `*` only | **No**, doubling with `x + x` reaches Infinity | Lower | Yes, above 2^53 |
| Saturate at ±(2^53−1) | Yes | Same branch | **Yes** |
| Wrap mod 2^53 | Yes | More than a branch; no precedent | Yes |
| No check | **No** | Zero | Yes |

A weaker invariant exists. Integer-valued doubles stay integer-valued under `+ - *`, so only Infinity breaks type soundness as opposed to exactness. That is a fallback, not a recommendation.

Kotlin's `canAddOrSubOverflow` and Scala.js's literal elision are precedents for dropping proven checks. **Range analysis in the release optimiser is the realistic route to low cost.**

### 3.6 Recommendation

1. Define the invariant: an `Int` is an integer with `|x| ≤ 2^53−1`.
2. Seal every source first. Out-of-range literals become compile errors, `String.toInt` returns `Nothing`, decoders refuse, and core and platform `foreign` bindings are audited.
3. Remove 32-bit truncation from everything except `Bitwise` and `Int32`.
4. Make `^` return Float.
5. Provide `Int.pow`, defined through `//`, with a `Maybe` form.
6. Saturate conversions at the bounds with NaN→0, add a `Maybe` form, and have `toFloat` add `+ 0`.
7. Pick one contract for division by zero and apply it to every operator. Total with `Maybe` forms has Gleam's precedent; defect has Scala.js's and Kotlin's.
8. Implement the overflow check behind a build switch and measure Solid benchmark, brotli size and Smi-path folding before committing. If the cost is small, trap as a defect and add Roc's family as the escape hatch. If it is material, choose between elision and saturation.

**Owner decisions:**
- Is integer overflow a defect?
- Is `round NaN = 0` acceptable?
- `Int.pow` or an operator?
- Is `x // 0` total or a defect?

### 3.7 Gaps

- No language compiler was run.
- Not found: any JS measurement of checked integers, the ARITH 2026 paper, or dart2js web rationale beyond the informal spec.
- Not established: Melange's `*` emit, MoonBit's `Int` emit and power, Haxe's `Int` arithmetic emit, and Fable's runtime behaviour.
- GHCJS and Grain were not researched separately.
- The ECOOP paper is an anonymised third-party draft.
- A keyword miss in an issue tracker does not show that no thread exists.

## 4. Sources

### Source code, pinned

File paths resolve under each commit. GHC was read at master, not pinned.

| Project | Commit | Files |
|---|---|---|
| [purescript-prelude](https://github.com/purescript/purescript-prelude/tree/e789260bb354071f8d43ed482e821b9381855315) | `e789260` | `src/Data/Semiring.js`, `Ring.js`, `EuclideanRing.js` |
| [purescript-integers](https://github.com/purescript/purescript-integers/tree/98f2f52bd5a702ddeb0692ac3df30a9785158eb6) | `98f2f52` | `src/Data/Int.js`, `Int.purs` |
| [rescript](https://github.com/rescript-lang/rescript/tree/43f4c9d899185bd4b471b665d6ba1d8729846f7f) | `43f4c9d` | `compiler/core/js_exp_make.ml`, `lam_compile_primitive.ml`, `packages/@rescript/runtime/Primitive_int.res`, `Stdlib_Math.resi` |
| [melange](https://github.com/melange-re/melange/tree/69b1fa2ec4381dae57f525b02804d5eb9af87af2) | `69b1fa2` | `jscomp/runtime/js_math.ml`, `caml_int32.ml` |
| [js_of_ocaml](https://github.com/ocsigen/js_of_ocaml/tree/f5f09a4f2df5608b7f68535f0c23cad34be0dd88) | `f5f09a4` | `runtime/js/ints.js`, `int64.js`, `compiler/lib/generate.ml`, `README.md` |
| [elm/core](https://github.com/elm/core/tree/65cea00afa0de03d7dda0487d964a305fc3d58e3) | `65cea00` | `src/Elm/Kernel/Basics.js`, `src/Basics.elm` |
| [gren core](https://github.com/gren-lang/core/tree/3fe20b3ecb987ef4ef62f9902311cc845b089222) | `3fe20b3` | `src/Gren/Kernel/Basics.js`, `src/Basics.gren` |
| [gleam stdlib](https://github.com/gleam-lang/stdlib/tree/ac093e4de6ef17312a947f8b721347ceea3132c7) | `ac093e4` | `src/gleam/int.gleam`, `float.gleam`, `src/gleam_stdlib.mjs` |
| [gleam](https://github.com/gleam-lang/gleam/tree/2e7275f340c2abc613688f25f2a011532be0c0e7) | `2e7275f` | `compiler-core/templates/prelude.mjs`, `changelog/v1.6.md` |
| [Fable](https://github.com/fable-compiler/Fable/tree/af0db791b4b8190cceb1d7c874c31c08c5496023) | `af0db79` | `src/Fable.Transforms/Replacements.fs`, `Replacements.Util.fs`, `src/fable-library-ts/BigInt.ts` |
| [Scala.js](https://github.com/scala-js/scala-js/tree/1a85b53f7e41a789db2e637a6b7e4fbe72e72300) | `1a85b53` | `linker/shared/.../emitter/CoreJSLib.scala`, `FunctionEmitter.scala`, `RuntimeLong.scala`, `javalib/.../Math.scala` |
| [Kotlin](https://github.com/JetBrains/kotlin/tree/6af940e82644145c400872a27768422b911af845) | `6af940e` | `compiler/ir/backend.js/.../NumberOperatorCallsTransformer.kt`, `libraries/stdlib/js/runtime/numberConversion.kt`, `libraries/stdlib/js/src/kotlin/math.kt` |
| [Dart SDK](https://github.com/dart-lang/sdk/tree/ea7f0523df162923438705fb67c94846a7f88498) | `ea7f052` | `sdk/lib/_internal/js_runtime/lib/js_number.dart`, `math_patch.dart`, `sdk/lib/math/math.dart` |
| [Haxe](https://github.com/HaxeFoundation/haxe/tree/573579a88f1b107138214d2d167159d9341a87ef) | `573579a` | `std/js/_std/Std.hx`, `std/haxe/Int32.hx` |
| [ClojureScript](https://github.com/clojure/clojurescript/tree/164d88d43d25807c54e18ec8e5ef98106c7b12e5) | `164d88d` | `src/main/cljs/cljs/core.cljs` |
| [Idris 2](https://github.com/idris-lang/Idris2/tree/debd433958c2005d42a98d0dc35c5a4648183edf) | `debd433` | `src/Compiler/ES/Codegen.idr`, `support/js/support.js`, `libs/prelude/Prelude/Num.idr` |
| [Nim](https://github.com/nim-lang/Nim/tree/194567aadfd16be50c86dbf37f72fb8f1756e8ff) | `194567a` | `lib/system/jssys.nim`, `compiler/jsgen.nim`, `lib/pure/math.nim` |
| [MoonBit core](https://github.com/moonbitlang/core/tree/f5efa52d13bccdbea6c136e0cb2bb5b41068184b) | `f5efa52` | `builtin/double_to_int.mbt` |
| [GHC](https://gitlab.haskell.org/ghc/ghc) | master | `compiler/GHC/StgToJS/Prim.hs`, `libraries/ghc-internal/src/GHC/Internal/Real.hs` |

### Documentation

- Gleam tour: [ints](https://tour.gleam.run/basics/ints/), [floats](https://tour.gleam.run/basics/floats/)
- [ReScript primitive types](https://rescript-lang.org/docs/manual/primitive-types/)
- [Melange data types](https://melange.re/v5.0.0/data-types-and-runtime-rep.html)
- [Fable compatibility](https://fable.io/docs/javascript/compatibility.html)
- Kotlin: [interop](https://kotlinlang.org/docs/js-to-kotlin-interop.html), [project setup](https://kotlinlang.org/docs/js-project-setup.html), [`Double.toInt`](https://kotlinlang.org/api/core/kotlin-stdlib/kotlin/-double/to-int.html)
- Dart: [number representation](https://dart.dev/resources/language/number-representation), [`int`](https://api.dart.dev/dart-core/int-class.html), [informal int64 spec](https://github.com/dart-lang/sdk/blob/2.15.1/docs/language/informal/int64.md)
- Haxe: [overflow](https://haxe.org/manual/types-overflow.html), [operators](https://haxe.org/manual/expression-operators-binops.html), [`Std`](https://api.haxe.org/Std.html), [`Math`](https://api.haxe.org/Math.html)
- GHC: [JS backend FFI](https://downloads.haskell.org/ghc/latest/docs/users_guide/javascript.html), [IOG primitive types](https://github.com/input-output-hk/engineering/blob/2fb070c861c099d0352edb8ca3e250f501e28e57/blog/2022-07-20-js-backend-prim-types.md), [commit-log document](https://mail.haskell.org/pipermail/ghc-commits/2022-August/048143.html)
- [AssemblyScript types](https://www.assemblyscript.org/types.html)
- [GWT compatibility](https://www.gwtproject.org/doc/latest/DevGuideCodingBasicsCompatibility.html)
- [Swift Advanced Operators](https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide/AdvancedOperators.md)
- Rust: [RFC 560](https://rust-lang.github.io/rfcs/0560-integer-overflow.html), [1.45 release](https://blog.rust-lang.org/2020/07/16/Rust-1.45.0/)
- [Roc `Num`](https://www.roc-lang.org/builtins/Num)
- [V8 pointer compression](https://v8.dev/blog/pointer-compression)
- [Scala.js 1.20.2](https://www.scala-js.org/news/2026/01/05/announcing-scalajs-1.20.2/)
- [typing-is-hard, Elm](https://3fx.ch/typing-is-hard.html#elm)

### Issues

- Elm: [#960](https://github.com/elm/core/issues/960), [#721](https://github.com/elm/core/issues/721), [#1003](https://github.com/elm/core/issues/1003), [#1079](https://github.com/elm/core/issues/1079), [#1142](https://github.com/elm/core/issues/1142), [#1150](https://github.com/elm/core/issues/1150)
- Gren: [core#140](https://github.com/gren-lang/core/issues/140), [compiler#383](https://github.com/gren-lang/compiler/issues/383)
- [PureScript prelude#60](https://github.com/purescript/purescript-prelude/issues/60)
- [ReScript #1760](https://github.com/rescript-lang/rescript/issues/1760)
- [Gleam #2853](https://github.com/gleam-lang/gleam/issues/2853)
- [Fable #1541](https://github.com/fable-compiler/Fable/issues/1541)
- Scala.js: [#3544](https://github.com/scala-js/scala-js/pull/3544), [#5205](https://github.com/scala-js/scala-js/pull/5205)
- Kotlin: [#6382](https://github.com/JetBrains/kotlin/pull/6382), [#6450](https://github.com/JetBrains/kotlin/pull/6450)
- Dart: [#43325](https://github.com/dart-lang/sdk/issues/43325), [#43389](https://github.com/dart-lang/sdk/issues/43389), [#46852](https://github.com/dart-lang/sdk/issues/46852), [#64491](https://github.com/dart-lang/sdk/issues/64491), [language#3197](https://github.com/dart-lang/language/issues/3197)
- [Idris #801](https://github.com/idris-lang/Idris2/issues/801)
- [Nim #6752](https://github.com/nim-lang/Nim/issues/6752)
- MoonBit: [#4622](https://github.com/moonbitlang/core/issues/4622), [#4612](https://github.com/moonbitlang/core/issues/4612)
- [Rust #10184](https://github.com/rust-lang/rust/issues/10184)
- [TC39 proposal-bigint#117](https://github.com/tc39/proposal-bigint/issues/117)

### Performance

- [Fast 64-Bit Integers for the JavaScript Platform](https://lively-kernel.org/lively4S2/testdir/ecoop18-paper22.pdf)
- [Fast 64-bit integers for Scala.js](https://chara.epfl.ch/~doeraene/presentations/jslongs-vmm2017)
- [Regehr, Efficient Integer Overflow Checking in LLVM](https://blog.regehr.org/archives/1384)
- [Dan Luu, integer overflow](https://danluu.com/integer-overflow/)