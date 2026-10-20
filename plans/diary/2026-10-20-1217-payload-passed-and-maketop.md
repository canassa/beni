## 2026-10-20 12:17 UTC — one makeTop path, and a payload passed on

**What I did**

The site cap had its own copy of the escape. It cleared the sites and
marked the summary dead, and it left out the rest of `makeTop`. That
rest sets the three flags `top` carries, walks the copy successors, and
joins `top` into each load cell of the escaped sites. `makeTop` now
returns only when the var is already `top` and holds no sites, so the
cap calls that one function. The unit test joins 1 001 sites into a
limited member binding that is already `top`, with one load cell and
one copy successor. The binding, the load cell and the successor are
`top`, the three flags are set, and every site is escaped. The same
join without `limited` still keeps the sites.

`run/PayloadPassed` is the two shapes the reassignment fixture did not
pin. `fromMembers` assigns a second member read and prints that
record's `drop`, which is 6. `fromCall` assigns `Host.same` and prints
9. `handed` passes the binding to `Host.readDrop`, and the field is
read only in that host function. It prints 9. Development keeps
`r = held.item`, `r = Host.same r` and `Host.readDrop r`. Release
inlines the two loops and still reads `drop` after each assignment.
Both builds print the same three lines. No field that is read was
dropped, so the join of a later `top` did not need a second change.

**What I learned**

`makeTop` used to return as soon as `top` was set. That is why the cap
grew a second copy. The empty site list is the state where the return
is safe. A member binding is `top` while it still holds sites, and
those sites are the ones the cap has to escape.
