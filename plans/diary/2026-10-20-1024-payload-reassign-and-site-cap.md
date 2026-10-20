## 2026-10-20 10:24 UTC — payload reassignment and the site cap

**What I did**

Closed the review notes on the payload-field change.

`run/PayloadReassign` binds a loop local to a `Result` payload and then
assigns another record. The release worker has `let d=c.a` and later
`d={e:4}`. Node prints 4. The host record's `drop` is 9, so the printed
field is the one read after the assignment. `emit/release/app/PayloadReassign`
pins that literal.

`run/PayloadUnreadField` already covers the kept paths. `eqLine` is `==`,
`shown` is `Debug.toString` of the payload binding, `printed` is
`Schema.write`, and `updated` is the record update.

Fact 3 does not split payloads by the tag test. That limit is #507,
named in `backend.md` and here. The 09:19 entry did not name it.

A member binding is already `top` when the set crosses 1 000 sites.
`makeTop` returned immediately, and the new test found 1 001 sites still
held. The cap now escapes those sites. The same join without `limited`
keeps them.

**What I learned**

Setting `top` and escaping the sites are different steps. The first is
what lets an unread field drop. The cap has to do the second after the
first has already happened.
