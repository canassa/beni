## 2026-10-21 15:23 CEST — a parameter's last read takes any literal

**What I did.** Issue #601, the follow-up to #589. Of the four programs that grew after #589, only
`BasicsEqOwnEq` had lost a fact. A read `a.a` that is `"step"` used to be a binding read once, which
takes any literal. Folded into an expression, the read met fact 4's five-byte limit. A read of a
property of a parameter now folds whatever the literal's length when it is the parameter's only
mention, so the parameter and its argument go. `BasicsEqOwnEq` is 1 387 brotli bytes again. Five
other programs and two pages got smaller, and one moved a declaration (+2 brotli, same raw). The
dashboard is unchanged.

**What I learned.** The other three programs lost nothing: their text is shorter and brotli codes
it in a few more bytes. Chasing those bytes would mean making the output longer. The lead in the
issue, reporting a dropped key as a change, does recover `ApiAndRoutes`' trimmed parameter, but
the release total grows by 167 raw bytes. Dropping the same kind of parameter in `SchemaValidator`
makes `y` small, and `inlineSmall` writes it at every call, larger each time. That is the inliner's
size model, and it is the real wall.
