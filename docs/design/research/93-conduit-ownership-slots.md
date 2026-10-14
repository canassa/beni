# 93 — Conduit's four errors lists: checker limits, resolved

*2026-10-14. Native/self-hosted `zorg`, Node 24.19.0, macOS. The application
sources are unchanged. Research 82 and 88's distinction between a proven
alias, a position refusal and a precision limit governs this classification.*

All four original errors are checker limits. The unchanged application now
checks on browser-direct, with **26 demands accepted, none rejected**. Its
full ownership report and enforcing check are in `ownership/Conduit/`.

| Original path | Evidence | Fix |
|---|---|---|
| `model#Article.0.errors` | ArticlePage appends errors from owned HTTP delivery; Page.viewErrors renders them, and its dismiss button sends a crossing constructor | separate render retention from event retention; preserve constructor callback result paths |
| `model#Home.0.feed#Loaded.0#Model.0.errors` | Feed.update appends favorite failures; Feed.viewArticles uses the same rendering helper, mapped through Home and Main | the same opaque slots survive imported helpers, rows and message mapping |
| `model#Profile.1.errors` | ProfilePage appends follow failures; its dismiss message carries no errors list | exclude its proven render slot from entry event payloads |
| `model#Profile.1.feed#Loaded.0#Model.0.errors` | the profile's Feed is a separate page model with the same update/render behavior | preserve the separate model constructor positions through callback summaries |

None of these handlers stores or sends the errors container. The List String
For rows receive crossing strings, and the dismiss messages carry no list.
This differs from Bike Wars' retained trail operands and Sternhalma's shared
Board.init: those are actual surviving aliases or top-level shared data, and
the checker still rejects them. No List.copy or application rewrite was added.

## 1. Two precision losses

Markup previously used one conservative result containing every rendered
operand. The entry treated every retained cell as an event payload. Thus a
list rendered by For looked like a list sent by a button. The new opaque
`render` and `events` paths implement Change 9's slot distinction: the full
markup value still retains both for ordinary alias/escape/later-read checks;
only the event projection at the entry excludes known render-only data.
Unknown values and wildcard paths remain conservative.

Removing that false payload exposed a second approximation: constructor
callbacks such as Main.Home in updateWith were represented as unknown
functions. Their result could retain the whole argument anywhere, conflating
separate page positions. The existing exact constructor row now travels as a
zero-capture class. Each potentially list-bearing argument remains under its
own constructor position, including through imported helpers. This does not
make a borrowed argument owned. In particular, existing command-tagger need
checks still run even when their constructor callback's calls are unseen.

The dated amendment in ownership-checker.md specifies both rules and their
soundness arguments before the implementation. Both are listed in §26.7,
including their unmodelled Lean-oracle risks. Summary blocks advance from
version 3 to 4 to encode the new paths and invalidate old rule sets.

## 2. Accepted cases and rejected twins

Four paired browser pages, ConduitArticleErrors, ConduitHomeFeedErrors,
ConduitProfileErrors and ConduitProfileFeedErrors, isolate the four nested
shapes. An owned response seeds the errors list; two clicks append to it;
a generic viewErrors renders it. All four fail with list_may_be_shared on the
saved pre-fix master binary and check successfully with the fix. Both platforms
run development/release against one captured golden, with differential value
fuzz; all four also pass in Chrome.

Each has a rejected build twin that retains the same nested list in a view
message. Home's twin adds a capturing handler. Further twins cover a mapped
message retaining the list, a For row carrying a list element, and a handler
returned by a helper with the list captured. ConduitRetainedMarkup holds a
render-only markup value across an edit: it remains rejected, proving that the
render slot is excluded only from the event projection, not general alias
checks. Full diagnostic goldens pin the eight refusals.

## 3. Other verdicts

Every pre-existing demand verdict in the ownership corpus is unchanged.
Only its markup result summaries acquire the new paths. The existing
ViewEventPayload, OwnedSend and HttpAnswer refusals remain, including the
constructor taggers that retain borrowed lists.

The pending-browser audit finds additional instances of the same limits:

- HttpCancel, HttpFailures, HttpProgress and HttpRequestShape lose their
  render-only payload rejection and are promoted unchanged.
- HttpDefect has the same rendered List String shape and is promoted unchanged.
- HttpMultipart's false rendered-list payload had also flowed through a
  different message's headers into the command capture, producing escaped.
  The event slot still retains the real header lists; it excludes the rendered
  log list, so the model's log is no longer spuriously escaped. It is promoted
  unchanged.
- ApiItems.log, ApiLogin.log and ValueCommands.items/log lose their render-only
  entry rejections. Their separate callback/decoder limits remain pinned;
  each build now has one list_may_be_shared diagnostic rather than two.

The other pending signatures, including BikeWars, RandomValues, reentrant
send and the full editing TodoMVC, are unchanged. No global borrowing or
ownership requirement was relaxed.

## 4. The separate stop

Conduit's ownership is now in the corpus, but its three original browser
scripts cannot yet move into the runnable direct corpus. Building the unchanged
application reaches **not_implemented at Main.beni:257:18**: the document view
returns helper-computed documents in its branches, a shape direct's program
hook does not yet compile. This is a lowering gap, not sharing or an owner
choice. Reader, Editor and Tour retain their original sources, scripts,
goldens and budgets in pending, now pinned to that diagnostic (CK-225).

The source was not wrapped or inlined by hand to pass it. The document helper
lowering belongs to the continuing Conduit slice. Its actual direct script
parity, size and timing measurements remain open.

## 5. Validation

Native/self-hosted zorg only; LLVM was not used. The four paired cases pass
happy-dom, Chrome and value fuzz. Six promoted HTTP pages pass all paired
builds and fuzz. Hash recording verifies 32 Conduit-related and 52 HTTP-related
program runs with no failed JavaScript run. The filtered pending audit matches
all remaining signatures. Unfiltered gates report **1,295 passed, 15 skipped**
and only the four authorized macOS baseline failures: two case-folding cases
and two driver cache-pruning CPU budgets.
