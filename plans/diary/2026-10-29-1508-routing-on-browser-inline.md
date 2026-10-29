## 2026-10-29 15:08 CET — routing on browser-inline

**What I did**

- Specified (`browser-inline.md` §10) and built `Tea.document`, `Tea.application` and
  `Browser.Navigation` on `browser-inline`, for client-rendered pages (#1163, part of #1160).
  Same signatures as `browser-tea`; the refusal tagger of a navigation command is `sync`, and
  there are no `each` forms, both because the platform has no task kernel.
- The write-set pass reads an application's subscriptions as `subscriptions ρ` plus the
  platform's `Navigation.onUrlRequest` / `onUrlChange` applied to the record's fields, and reads
  `init` and keys through platform functions so `Navigation.pushUrl` is seen as its `perform`.
- A subscription whose tagger's key splits again on the value (`ClickedLink (Browser.Internal
  url)`) now goes through the dispatcher as the message (interface 1.21).
- Fixed a silent wrong answer on master (#1167): the dispatcher handed a deep key's handler the
  whole message (`1[object Object]`).
- Constant `href`s compile (checked by `safeUrl`'s rule at build time).
- Pages: `browser/inline/{Router, NavigateCommands, LinkGuard, DocumentTitle, ApplicationNotHttp,
  DispatchDeepKey}`; `browser/tea/InlineRouter` and `InlineNavigateCommands` are the same sources
  on `browser-tea`. All pass in happy-dom and headless Chrome.

**What I learned**

- A `foreign` constructor costs a page bytes in a development build even when nothing calls it:
  the sibling `.js` is copied whole. `document` and `application` are therefore beni declarations
  with a body no call reaches.
- Editing any platform `.beni` file changes every dev run hash of that platform, because source
  maps embed the sources; the JavaScript did not move.
- `browser-inline` refused every URL attribute, so no link could be written before this slice.
- P1 (#1173) landed first with interface 1.20, so this slice's additions are 1.21.
