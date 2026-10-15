import Ownership.Syntax

namespace Ownership.Question

/-- The continuation belongs to the current definition. A call is an ordinary
    Expr, so a question inside its callee cannot return from the caller. Explicit
    ANF binders are checked for freshness by the ordinary core type checker. -/
inductive Body where
  | finish (value : Expr)
  | letE (name : Var) (rhs : Expr) (rest : Body)
  | question (operand : Expr) (temporary error success : Var) (rest : Body)
  | branch (condition : Atom) (zero nonzero : Body)
  deriving Repr, BEq, Inhabited

/-- CPS lowering of `?`: evaluate once, forward the complete Err payload out
    of this definition, or bind Ok and run the rest. The result success type
    is the definition's, not the operand's. There is no ambient return flag
    which an inner callback or recursive call could accidentally overwrite. -/
def lower (resultSuccess : Ty) : Body → Expr
  | .finish e => e
  | .letE v rhs rest => .letE v rhs (lower resultSuccess rest)
  | .question operand tmp err ok rest => .letE tmp operand <|
      .resultCase (.var tmp) err ok (.prim (.err resultSuccess) [.var err]) (lower resultSuccess rest)
  | .branch c a b => .branch c (lower resultSuccess a) (lower resultSuccess b)

end Ownership.Question
