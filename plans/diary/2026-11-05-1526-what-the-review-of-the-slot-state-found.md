## 2026-11-05 15:26 CET — What the review of the slot state found

**What I did.** Answered the three passes of #2009's adversarial review. A callback that moves an object between slots now
counts as an edit of what it moves (`Contents.moved`), and a call's own escape of the whole cell excuses that write.

**What I learned.** My earlier entry stated the invariant too weakly. Two slots being two objects is not enough: a slot's
object must also be the one its name says. A swap holds no duplicate, so the store rule missed it, and removing the take's
guard on that argument turned a hole master already had into a regression. The names stay right for what is read after a
move, because they move together, so only a holder from before matters. An escape marks a name and does not follow its
object, which is why a move of escaped contents must stay refused, even where the cell is only read after. A blanket
exemption for a helper's own escape would have been unsound: it holds only because a whole-cell escape leaves every name
escaped.
