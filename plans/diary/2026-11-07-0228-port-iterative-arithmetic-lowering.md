## 2026-11-07 02:28 CET — Port the iterative arithmetic lowering (#2180)

**What I did**

Ported #1779 from the deleted workers-hostfree branch: `Lower.operatorExpr` walks a saturated
arithmetic subtree with an explicit `ArithmeticFrame` stack, sharing `orderValues`, `exprOverride`
and `finishExpr` with the recursive path; plus the backend.md note and `run/WideArithmetic`
and `run/ArithmeticOperandOrder`. Master's Debug beni segfaults on WideArithmetic in dev and
release (2 001 frames each of `exprValue`, `callExpr`, `operatorCall`, `orderedExprs`); the
fixed Debug beni builds both and they print `4095`. No emit golden moved and page sizes are
byte-identical to master. The patch applied to master without conflicts.

**What I learned**

The gates' corpus runs the ReleaseSafe beni, whose frames are small enough that WideArithmetic
passes on master too; the red proof for this fixture is the Debug beni.
