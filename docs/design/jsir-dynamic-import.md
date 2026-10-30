# Dynamic module import in JsIr

Specified 2026-10-30 before implementation. This is an internal JavaScript IR expression, not Beni syntax or a new language feature. It supports the already selected staged worker bootstrap and the generated static UI measurement driver.

Append `dynamic_import` to Node.Tag so every existing tag value stays unchanged. Its lhs is one expression operand, evaluated once as the module specifier; rhs is zero. Print emits exactly `import(expr)` with call precedence and call nesting weight in both printer paths. A sequence operand is parenthesized as `import((a,b))`, never interpreted as multiple arguments. An identifier called import remains escaped: it cannot impersonate this expression.

Verification requires a valid expression child and unused rhs zero. Operand walking, height, copying, renaming and use collection retain the operand. Dynamic imports may evaluate modules and reject, so optimization treats them conservatively as effectful and potentially throwing. An unused import expression is never discarded as pure, moved across effects, or value-numbered as a repeatable read. No source lowering creates this node yet.

JsIr is process-owned intermediate state, not a persisted interface/cache payload; output records persist emitted files rather than this node table. Appending the tag does not change current stored formats or checked interfaces. Existing tags remain numerically stable. Compiler source/build identity invalidates cached emitted output normally.

Validation includes verifier malformed-child checks; both printer modes; operand traversal/copying; effect classification; and actual Node execution of a generated dynamic import of a JsIr-generated module exporting a known value. Node syntax checking alone cannot detect a mistakenly escaped `$import` call. The static measurement driver and browser loops are generated with JsIr/Print; no handwritten JavaScript source or generated application modification is introduced.

The recursive printer uses a conservative 128-level prefix before its existing explicit work stack. Adding expression cases can grow Debug stack frames even on older expression trees; the unchanged 800-level regression must still fit its 1 MiB stack. Earlier fallback changes no printed bytes and introduces no input-depth limit.
