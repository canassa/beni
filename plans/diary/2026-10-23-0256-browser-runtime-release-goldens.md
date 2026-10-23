## 2026-10-23 02:56 CEST — Browser runtime release goldens

**What I did**

The first full gate for #319's runtime half passed the ownership and browser
behavior checks, with five bundled-runtime release emit goldens still stale.
Updated EmptyPage, HolesPage, TemplateOneFlag, HttpSendTracked and
HttpSendUntracked through locked targeted runs. Both release emit subsets
passed. The complete emit change list is twelve DOM goldens plus those five
bundled-runtime shapes. The locked run-hash refresh passed as well.

**What I learned**

Even an empty page's release shape changes when the runtime stops treating
the same block as unchanged: its patch call now survives reachability. Tea's
Http emit fixtures also bundle the shared browser renderer, so their runtime
shape changes with the same rule. No additional console or DOM transcript
changes were needed.
