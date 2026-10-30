# Preserve IEEE signed zero under negation

## What I did

While implementing the WebGPU prerequisites requested after research merge
`cea5d5734` (#1277 runtime, #1278 inputs; offline WGSL tools remain #1276),
#1282 exposed loss of the sign in `(-0.0)`. The runtime lead isolated this
correctness fix from all held architecture/API work on a branch of master.

Prefix minus desugars to `Basics.negate`. Both the direct operator lowering and
the first-class beni body subtracted from positive zero, which cannot produce
negative zero from positive zero. Direct calls now use the existing unary JS IR
operator; the beni body multiplies by `(0 - 1)` without recursively invoking
prefix desugaring. No JavaScript runtime/helper or new privileged intrinsic was
added.

A self-contained black-box fixture uses native DataView f64 words as its oracle.
It covers literal, named, first-class and callback negation, native negative
zero, underflow, finite/infinite/NaN values, and one evaluation of an impure
operand. That test exposed development printing of nested negation as invalid
`--0.0`/`--42.5`; development output now brackets unary-minus operands, while
release retains its token separator. The backend contract and public skill
reference describe the corrected behavior.

Validation: the installed compiler was built in Debug (`c98552a1802b49307705e467e9ed0003`).
Focused development/release native-word checks pass. The corpus hash recording
found the existing deliberate positive-infinity expectation in `OperatorsInPlace`;
it now expects negative infinity, and focused recording verifies both builds.
The two corresponding operator-emission lines were updated explicitly. The core
ownership catalog was verified to change only by three +2 source-line offsets
from the expanded negate documentation. The unfiltered `zig build gates` passed.
After that pass, a filtered recording of the affected scenario tests verified
35 runs and updated the 31 changed scenario hashes, without replaying the whole
corpus merely to update its index. The final gate also checks that index.

## What I learned

Testing only decimal output misses signed-zero defects: Number string conversion
prints both zeros alike. Testing only release missed a separate development
printer adjacency defect. Native bit observations and both output modes are
necessary evidence for this boundary.
