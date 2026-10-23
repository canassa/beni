## 2026-10-23 03:47 UTC — an arm's handler asks the runtime

**What I did.** #610 wrote each handler inside an eager arm as its own listener with the arm
test in place, `a[10].addEventListener("input",b=>{if(!!a[8].$a.parentNode)return;f(…,b)})`.
The same test now lives once in `Inline.on`, handed the arms' elements, so the site is
`p(a[10],…,"input",a[8])` (#844, part 2). A handler with a flag or a captured argument keeps
its listener. Measured alone on master, unique-components N 16→64, seeds 1–3: 262.4 → 261.4
B/widget. Removing the test outright priced 2.0 on seed 1; an array for every site, even of one
element, recovered only 0.2, so one arm is passed bare.

**What I learned.** `browser/inline/` had no page with a plain handler in a hidden arm clicked
from the host; `ArmListenerHidden` is one, with a nested arm and a piece. The fixture platform
keeps the buttons at insert time, since a hidden arm's button is out of the page.
