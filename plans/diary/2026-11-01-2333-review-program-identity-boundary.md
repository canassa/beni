## 2026-11-01 23:33 CET — Review Program identity boundary

**What I did**

Expanded the manifest's platform type through aliases before comparing it to
main. Limited the package-shadowing diagnostic to a resolved expected type.
Moved the regression into corpus projects and added alias/missing-type cases.
Updated the boundary contract and rewrapped the developer skill text.

**What I learned**

Comparing only the initial manifest TypeId rejects a genuine Program alias.
A missing platform type cannot be impersonated, so it needs the ordinary
main_not_program message instead of blaming a local module's name.
