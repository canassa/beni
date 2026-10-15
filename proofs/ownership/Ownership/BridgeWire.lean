import Ownership.Syntax

/-! A small data-only reader for the bridge's own JSON arrays. No elaboration,
    evaluation of input code, compiler imports, or permissive fallback. -/
namespace Ownership.BridgeWire
inductive Value where
  | text (s : String) | number (n : Nat) | flag (b : Bool) | array (xs : List Value)
  deriving Repr, Inhabited

def spaces (cs : List Char) := cs.dropWhile Char.isWhitespace

def stringValue : Nat → List Char → String → Except String (String × List Char)
  | 0, _, _ => .error "wire string fuel"
  | _+1, '"' :: rest, out => .ok (out, rest)
  | n+1, '\\' :: c :: rest, out => do
    let c ← match c with
      | 'n' => pure '\n' | 'r' => pure '\r' | 't' => pure '\t'
      | '\\' => pure '\\' | '"' => pure '"'
      | _ => throw "unsupported wire escape"
    stringValue n rest (out.push c)
  | n+1, c :: rest, out =>
    if c.toNat < 32 then throw "wire string control character"
    else stringValue n rest (out.push c)
  | _, [], _ => .error "unterminated wire string"

mutual
 def parseValue : Nat → List Char → Except String (Value × List Char)
  | 0, _ => .error "wire nesting fuel"
  | n+1, input =>
    match spaces input with
    | '[' :: rest => do
      let (xs, tail) ← parseArray n rest
      pure (.array xs, tail)
    | '"' :: rest => do
      let (s, tail) ← stringValue (rest.length+1) rest ""
      pure (.text s, tail)
    | 't' :: 'r' :: 'u' :: 'e' :: rest => pure (.flag true, rest)
    | 'f' :: 'a' :: 'l' :: 's' :: 'e' :: rest => pure (.flag false, rest)
    | cs => do
      let digits := cs.takeWhile Char.isDigit
      if digits.isEmpty then throw "expected wire value"
      if digits.length > 1 && digits.head? == some '0' then throw "wire leading zero"
      let some k := String.ofList digits |>.toNat? | throw "wire number"
      pure (.number k, cs.drop digits.length)
 def parseArray : Nat → List Char → Except String (List Value × List Char)
  | 0, _ => .error "wire array fuel"
  | n+1, input =>
    match spaces input with
    | ']' :: rest => pure ([], rest)
    | cs => do
      let (v, tail) ← parseValue n cs
      match spaces tail with
      | ']' :: rest => pure ([v], rest)
      | ',' :: rest =>
        if (spaces rest).head? == some ']' then throw "trailing wire comma"
        let (vs, tail) ← parseArray n rest
        pure (v :: vs, tail)
      | _ => throw "expected wire comma or closing bracket"
end

def parse (s : String) : Except String Value := do
  let (v, rest) ← parseValue (s.length+1) s.toList
  if !(spaces rest).isEmpty then throw "trailing wire input"
  pure v

private def array : Value → Except String (List Value)
  | .array xs => pure xs | _ => throw "expected wire array"
private def text : Value → Except String String
  | .text s => pure s | _ => throw "expected wire text"
private def nat : Value → Except String Nat
  | .number n => pure n | _ => throw "expected wire natural"
private def itemAt (xs : List Value) (n : Nat) := xs[n]?.toExcept "short wire node"
private def tag (v : Value) : Except String (String × List Value) := do
  let xs ← array v
  pure (← text (← itemAt xs 0), xs.drop 1)

def ty : Nat → Value → Except String Ty
  | 0, _ => throw "wire type depth"
  | n+1, v => do
    let (k, xs) ← tag v
    match k, xs with
    | "int", [] => pure .int
    | "result", [e,a] => pure (.result (← ty n e) (← ty n a))
    | "chain", [t] => pure (.chain (← ty n t))
    | "list", [t] => pure (.list (← ty n t))
    | "builder", [t] => pure (.builder (← ty n t))
    | "record", [ts] => pure (.record (← (← array ts).mapM (ty n)))
    | "fn", [ps,r] => pure (.fn (← (← array ps).mapM (ty n)) (← ty n r))
    | _, _ => throw "unknown wire type"

def atom : Nat → Value → Except String Atom
  | 0, _ => throw "wire atom depth"
  | n+1, v => do
    let (k, xs) ← tag v
    match k, xs with
    | "int", [x] =>
      let some i := (← text x).toInt? | throw "wire integer"
      pure (.int i)
    | "var", [x] => pure (.var (← nat x))
    | "field", [a,i] => pure (.field (← atom n a) (← nat i))
    | _, _ => throw "unknown wire atom"

def prim (v : Value) : Except String Prim := do
  let (k, xs) ← tag v
  match k, xs with
  | "ok", [t] => pure (.ok (← ty 256 t))
  | "err", [t] => pure (.err (← ty 256 t))
  | "end-chain", [t] => pure (.endChain (← ty 256 t))
  | "link", [] => pure .link
  | "private-root", [] => pure .privateRoot
  | "literal", [t] => pure (.literal (← ty 256 t))
  | "builder", [t] => pure (.builder (← ty 256 t))
  | "owned", [.flag b] => pure (.owned b)
  | "add", [] => pure .add | "sub", [] => pure .sub | "eq", [] => pure .eq | "lt", [] => pure .lt
  | "record", [] => pure .record | "length", [] => pure .length | "at", [] => pure .at
  | "set", [] => pure .set | "push", [] => pure .push | "copy", [] => pure .copy
  | "prepend", [] => pure .prepend | "events", [] => pure .events | "shared", [] => pure .shared
  | "put", [] => pure .put | "close", [] => pure .close
  | _, _ => throw "unknown wire primitive"

def expr : Nat → Value → Except String Expr
  | 0, _ => throw "wire expression depth"
  | n+1, v => do
    let (k, xs) ← tag v
    let a := atom 256
    let args := fun v => do (← array v).mapM a
    match k, xs with
    | "atom", [v] => pure (.atom (← a v))
    | "let", [i,r,b] => pure (.letE (← nat i) (← expr n r) (← expr n b))
    | "prim", [p,vs] => pure (.prim (← prim p) (← args vs))
    | "closure", [i,vs] => pure (.closure (← nat i) (← args vs))
    | "app", [f,vs] => pure (.app (← a f) (← args vs))
    | "recur", [vs] => pure (.recur (← args vs))
    | "entry", [i,r,m,b] => pure (.entry (← expr n i) (← args r) (← nat m) (← expr n b))
    | "result-case", [s,e,k,x,y] => pure (.resultCase (← a s) (← nat e) (← nat k) (← expr n x) (← expr n y))
    | "chain-case", [s,h,t,x,y] => pure (.chainCase (← a s) (← nat h) (← nat t) (← expr n x) (← expr n y))
    | "branch", [c,x,y] => pure (.branch (← a c) (← expr n x) (← expr n y))
    | "focus", [s,i,x,b] => pure (.focus (← a s) (← a i) (← nat x) (← expr n b))
    | "traverse", [k,s,z,i,x,acc,b] =>
      let k ← match ← text k with
        | "list" => pure Source.list | "range" => pure .range | "model" => pure .model
        | _ => throw "unknown wire traversal"
      pure (.traverse k (← a s) (← a z) (← nat i) (← nat x) (← nat acc) (← expr n b))
    | _, _ => throw "unknown wire expression"

def decl (v : Value) : Except String Decl := do
  let xs ← array v
  unless xs.length == 6 do throw "wire declaration arity"
  let name ← text (← itemAt xs 0)
  let parameters ← (← array (← itemAt xs 1)).mapM (ty 256)
  let captures ← (← array (← itemAt xs 2)).mapM (ty 256)
  let result ← ty 256 (← itemAt xs 3)
  let body ← expr 2000 (← itemAt xs 4)
  pure { name, parameters, captures, result, body }

def program (s : String) : Except String Program := do
  let .array [ds,main] ← parse s | throw "expected [declarations, main]"
  let declarations ← (← array ds).mapM decl
  let main ← expr 2000 main
  let p : Program := { declarations, main }
  let _ ← typecheck p
  pure p

#guard (parse "[] trailing").isOk == false
#guard (parse "[1,,2]").isOk == false
#guard (parse "[1,]").isOk == false
#guard (parse "[01]").isOk == false
#guard (parse "[\"a\nb\"]").isOk == false
#guard (parse "[\"unterminated]").isOk == false
#guard (program "[[],[\"atom\",[\"int\",\"7\"]]]").isOk
#guard (program "[[],[\"atom\",[\"var\",7]]]").isOk == false
end Ownership.BridgeWire
