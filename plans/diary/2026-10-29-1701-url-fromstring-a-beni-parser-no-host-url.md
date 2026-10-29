## 2026-10-29 17:01 CET — Url.fromString: a beni parser, no host URL

**What I did** (#1177, part of #1160). `core/Url.beni`'s `fromString` called the host's
WHATWG `URL`, which no embeddable engine has (research 108 §10 item 1), so a prerendered
`application` could not get its `Url` in the build. It is now the URL Standard's basic URL
parser for `http` and `https` with no base, written in beni over ECMAScript only: two trims and a
split for the input, one regular expression for scheme / authority / path / query / fragment, the
standard's port, host (percent-decoding, forbidden code points, ends-in-a-number, IPv4 in every
radix, IPv6 with `::` and an IPv4 tail, serialisation), dot segments and the three percent-encode
sets, and a Punycode decoder for `xn--` labels. The contract is `boundary.md` §9.8.13 (a), its
second amendment (dated, nothing renumbered), with a pointer from §9.8.10 (b) and `prerender.md`
§7.3. The platforms' callers (`Browser.Navigation.currentUrl`, the link guard, `Inline.address`)
did not change: they hand it `location.href` and `a.href`. `Browser.Navigation.resolve`
(relative resolution for `pushUrl`, browser only, against `location`) still uses the host's
`URL`; it is not `fromString` and not on a prerender path.

New fixture `run/UrlWhatwg/`: 101 WPT inputs (urltestdata.json, four hosts of toascii.json,
wpt c48d58747e1f) whose expected output `tests/oracle/url-whatwg.mjs` writes from Node 24's
`URL`. A probe platform deletes `globalThis.URL` before the program parses anything: on master's
core the program stops at its first case with `TypeError: Cannot read properties of undefined
(reading 'parse')`; on the branch it prints the oracle's output byte for byte. Every `run/Url*`
expected output and every `browser/` transcript is unchanged; only run hashes and
`core.v2.unchecked` moved.

**What I learned.**
- A differential run is the way to write this: the new parser and Node's `URL` over every input
  of urltestdata.json, toascii.json and ~8000 generated URL-shaped inputs (random hosts, ports,
  paths, Punycode labels). It found the one thing a reading did not: `encodeURIComponent`
  leaves `'` alone, so the special-query set's `'` needs its own `%27`.
- The only disagreements left are refusals (a host that is Unicode once percent-decoded, an
  `xn--` label of a right-to-left script) and one acceptance (`xn--wsg`, a code point UTS #46
  maps but NFKC and lower-casing do not). Both need UTS #46's tables: #1179.
- Size: the first version walked `List Int` code points and pulled half of `core/List`'s trie
  code into the page (+3.3 kB brotli on `browser/inline/Router`). Strings, ECMAScript string
  methods and a few regular expressions brought it to +1.7 kB (3 884 → 5 615 brotli, release).
- Node's `URL` (Ada) consumes a Punycode delimiter that is the label's first character, where
  RFC 3492 and ICU do not (`xn---czpk`): the parser follows Node, the oracle.
- `Js.global "URL"` compiles to a bare `URL` under `--release`, a `ReferenceError` once the
  global is deleted; the probe reads `globalThis.URL` instead.
