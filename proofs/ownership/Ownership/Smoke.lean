import Ownership.Library
import Ownership.Semantics

namespace Ownership.Smoke

def tiny : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1]) (.prim .push [.var 0, .int 2])
}

def initializer (sharing : Bool) : Decl := {
  name := "nestedInitializer"
  parameters := [.int]
  result := .list (.list .int)
  body := .letE 1 (.prim (.literal .int) [.int 0]) <|
    .letE 2 (if sharing then .atom (.var 1) else .prim (.literal .int) [.int 0]) <|
    .prim (.literal (.list .int)) [.var 1, .var 2]
}

def nested (sharing : Bool) : Program := {
  declarations := [Library.initialize (.list (.list .int)), initializer sharing]
  main := .letE 0 (.closure 0 []) <|
    .letE 1 (.closure 1 []) <|
    .letE 2 (.app (.var 0) [.int 1, .var 1]) <|
    .focus (.var 2) (.int 0) 3 <|
      .focus (.var 3) (.int 0) 4 <|
        .prim .push [.var 4, .int 9]
}

def run : IO Bool := do
  let mut ok := true
  for (name, p, accepted) in [("push", tiny, true), ("distinct nested", nested false, true),
      ("shared nested", nested true, false)] do
    let verdict := check p
    IO.println s!"{name}: {repr verdict}"
    if verdict.isOk != accepted then ok := false
    if verdict.isOk then
      let a := ValueSemantics.run p
      let b := InPlaceSemantics.run p
      if !(match a, b with | .ok x, .ok y => x == y | _, _ => false) then
        IO.println s!"value={repr a}\nin-place={repr b}"
        ok := false
  let old := check (nested true) { oldFreshRule := true }
  IO.println s!"old rule: {repr old}"
  if !old.isOk then ok := false
  pure ok

end Ownership.Smoke
