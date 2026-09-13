# check/good

Modules and projects that resolve cleanly, and the interface each one
produces (`docs/design/checker.md` §3, §7). Two claims per fixture:

- `beni check <fixture>` exits 0 with **no diagnostic at all** — the names
  resolved against this project and against the embedded core package;
- `beni dump --stage=interface <fixture>` equals the `.iface` golden — what
  the module now offers its dependents.

Two shapes:

| Shape | The compiler runs | Compared against |
|---|---|---|
| `X.beni` | `check X.beni`, then `dump --stage=interface X.beni` | `X.iface` |
| `X/` (a directory) | `check X`, then `dump --stage=interface X` | `X/_expected.iface` |

A directory is a **project**: every `.beni` under it is a module of the
package `app`, and the golden is every module's interface concatenated in
path order. That is where cross-module resolution — imports, `exposing`
lists, qualified names, the topological order — is actually exercised.

A fixture under `core/` is run with `--core`, so `foreign` and the
`equatable` marker are legal (`language.md` §5.4, checker.md Appendix B).

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`; check the blessed
golden against the fixture's intent comment before committing it.

M2b adds the inferred scheme of every value to these goldens, so expect one
churn of the whole directory when it lands. That is the point of keeping the
interface dump narrow: the churn is readable.
