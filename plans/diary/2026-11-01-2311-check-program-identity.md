## 2026-11-01 23:11 CET — Check program identity

**What I did**

Compared the expanded entry annotation with the platform-owned nominal type.
Added a compiler-boundary regression for a same-named application Program.

**What I learned**

Current master accepted the shadow type (exit 0); the regression expects
main_not_program and no output. Alias expansion already retains enough type
information to make the comparison without worker infrastructure.
