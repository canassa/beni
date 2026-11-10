## 2026-11-10 17:08 CET — Share navigation host operations

**What I did**

- Added `browser-base`'s private `Browser.Address`, with the host work that both
  `Browser.Navigation` modules duplicated. The facades keep `Key`, `Error` and `UrlRequest`.
- Inline gained `eachUrlRequest` and `eachUrlChange`. They are pinned by
  `browser/prerender/BaseNavigation`, which failed before.
- Added the refusal `build/bad/prerender/BaseNavigationInView`.

**What I learned**

- A facade cannot re-export another module's constructors, and programs match
  `Navigation.BadUrl`. So the shared module either returns its own type, which the facade
  translates, or takes the facade's constructors. Taking them was the smaller choice: +8–23 brotli
  bytes against +37–48 for translating.
- On inline, `Listen.on` with an entry costs 48–70 brotli bytes more on a link page than the
  platform's own `live` guard, for the same behaviour. Measure before moving listeners.
