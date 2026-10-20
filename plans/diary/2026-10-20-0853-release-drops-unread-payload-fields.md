## 2026-10-20 08:53 UTC — release drops unread payload fields

**What I did**

Reproduced canassa/beni#452 on `upstream/master` at `4f88c6671`. A release
build of a tagged schema whose caller reads one payload field returned
`{a:{c:g,b:f}}`. The plain record in the same program returned `{b:e}`.
The host key was still tested. Node printed the kept integer.

The unread field was already marked unread. `keyUnread` refused it because
the payload object had escaped. The pattern binds the payload with a member
read of the constructor slot. That slot's points-to set is the constructor
and `Result`'s `Err` list. The list is not an object, so the read is `top`
and still names the payload. Joining that value into a capped local escaped
the payload, and every field stayed.

A local whose initialiser is a member read now keeps the read's sites
beside `top`, the same way a load cell does. The flag is taken from the
statement, before any join, so the two fact-3 walks agree. A spread of
that local still folds the sites, so every field of a spread record stays.
A use that cannot name a field still escapes them.

`emit/release/app/PayloadUnreadField` shows the unread payload field gone
and a field that is read still present. `run/PayloadUnreadField` checks the
integer, a bad host value, `==`, `Debug.toString`, `Schema.write`, a record
update, two readers of one schema, and a nested payload.

**What I learned**

Setting the uncapped flag only after the value was already `top` made the
two walks escape different sites. The safety build then stopped on
`ValidatorParse`, `SchemaReaderTest`, `SchemaSharedValidators`,
`QuestionPositions`, `UndeterminedUnderValueEvidence` and
`UserEqInsideRecord`. The flag has to be a fact about the statement.

`SchemaReaderTest` and `SchemaSharedValidators` kept unread fields for the
same reason. Their release goldens now omit those fields. The host keys
are still tested. Release hashes moved for `browser/inline/ResearchS2`,
`browser/inline/ResearchS3` and `SchemaDescribeDeclared`'s library build.
Their transcripts did not.
