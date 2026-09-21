---
name: hackernews
description: Search Hacker News and retrieve whole comment threads from the command line — find stories or comments by full text, find the HN discussion of any article URL, and pull a story's entire reply tree. No login needed. Use when researching how practitioners reacted to a language, framework or design decision, when the user asks about Hacker News, HN threads or "what did HN say about X", or when a design note needs citable primary-source evidence of what people who shipped something actually reported.
---

# Hacker News

HN is where people who *shipped* a technology complain about it in public, at length, with their
names attached. For this repo — an Elm-like language compiled to JavaScript — it is the main
searchable record of what using Elm, TEA, signals, SSR and friends was like in practice, including
the arguments that never made it into anyone's design document. It is the counterpart to
[`references/talks/`](../../../references/talks/README.md) (one person's prepared argument) and to
the `roc-zulip` skill (a peer project's engineering log): **HN is the users talking back.**

## Access: no credentials required

Verified 2026-09-20. Everything runs against Algolia's public index of HN. No key, no cookie, no
headers, no login — plain `GET` over HTTPS.

```bash
# the minimal working call, for reference
curl -sS -G 'https://hn.algolia.com/api/v1/search' \
  --data-urlencode 'query="the elm architecture"' --data-urlencode 'tags=comment'
```

Two endpoints do all the work: `/search` (by relevance) and `/search_by_date` (chronological) for
finding things, and `/items/<id>` for retrieving a whole thread.

## Scripts

All in `scripts/`, all fish, all take `--help`. They need only `curl` and `jq`.

| Script | Use |
|---|---|
| `hn-search.fish <terms...> [--type story\|comment\|all] [--limit N] [--by-date] [--min-points N] [--after D] [--before D] [--author U] [--story ID] [--in title\|text\|all] [--loose]` | Full-text search over stories or comments |
| `hn-item.fish <id> [--depth N] [--top] [--limit N] [--grep P] [--width N]` | A story plus its entire comment tree, or a comment plus its replies |
| `hn-url.fish <article-url> [--all]` | Find the HN discussion(s) of an article, most-discussed first |

Every script also takes `--json` to emit the raw API response for further `jq` work, and
`hn-item.fish` accepts a pasted `news.ycombinator.com/item?id=…` URL as well as a bare id.

Shared code is `scripts/_common.fish`; every regex and output format lives in `scripts/hn.jq`,
loaded via `jq -L`. Keeping the regexes out of fish strings is deliberate — a backslash otherwise
has to survive fish quoting, JSON quoting and jq's regex parser, which is how the equivalent line
in `roc-zulip/scripts/_common.fish` earned its warning comment.

### Typical research flow

```fish
# 1. what did HN make of this article?
./scripts/hn-url.fish https://lukeplant.me.uk/blog/posts/why-im-leaving-elm/

# 2. read the thread that actually happened
./scripts/hn-item.fish 22821447 --top --limit 20

# 3. drill into one theme across the whole thread, at any depth
./scripts/hn-item.fish 22821447 --grep 'custom element|port|interop'

# 4. or go the other way: find the theme first, across all of HN
./scripts/hn-search.fish 'the elm architecture' --type comment --limit 40
./scripts/hn-search.fish elm --min-points 100 --type story
```

## Facts worth knowing

These are all verified against the live API, and most of them cost an hour to find.

- **Queries are searched as an exact phrase by default, and they must be.** Algolia's typo
  tolerance is aggressive: an unquoted `elm` matches `Elon` (one edit away) and any URL containing
  the letters, so `query=elm&tags=story` reports **5 496** hits of which most are junk.
  `query="elm"` reports **1 087**, and they are about Elm. `--loose` turns the quoting off.
- **Restricting the searched fields does not fix that.** `restrictSearchableAttributes=title` alone
  still returns 75 479 hits for `elm`, because the typo match happens inside the title too.
  Quoting is the load-bearing fix; `--in title` is a refinement on top of it, not a substitute.
- **`--by-date` is where this bites hardest.** Relevance ranking hides the noise by pushing true
  matches to the top, so `/search` looks fine while `/search_by_date` returns near-garbage. If a
  chronological search looks wrong, the query was not quoted.
- **Only five fields are searchable**: `title`, `url`, `author`, `story_text`, `comment_text`.
  `story_title` and `text` look like they should work — `story_title` is right there on every
  comment record — but naming either in `restrictSearchableAttributes` returns
  `attribute … is not in searchableAttributes setting`. They are returned, not indexed.
- **Comments have no score.** `points` is `null` on every comment record, because HN does not
  publish comment scores. There is no way to sort or filter comments by how well they did — only
  by date, by relevance, and by which story they are on. Do not claim a comment was "highly
  upvoted"; you cannot know that.
- **Any result set is capped at 1 000 hits**, however you page: `hitsPerPage` clamps to 1000, and
  `page × hitsPerPage` past 1000 returns nothing at all (`nbPages: 0`). `nbHits` still reports the
  true total. To get past the cap, split the range with `--after`/`--before`.
- **`/items/<id>` returns the entire nested tree in one request** — no paging, no depth limit. A
  400-comment thread is a single call. It works on comment ids too, returning that comment and its
  replies, which is how you read a subthread.
- **Comment records are denormalised.** A search hit for a comment carries `story_id`,
  `story_title`, `story_url` and `parent_id`, so you can report what a comment was replying to
  without a second request.
- **Useful `tags` values:** `story`, `comment`, `(story,comment)` as an OR-group, `author_<user>`,
  `story_<id>` (all comments on one story), plus `front_page`, `ask_hn`, `show_hn`, `poll`.
  Comma-separated tags are ANDed.
- **Dates come in two forms.** `created_at` is ISO-8601 for display; `created_at_i` is epoch
  seconds and is the one `numericFilters` understands (`created_at_i>1704067200`).
- **A popular article is submitted many times.** "Why I'm Leaving Elm" has four submissions; one
  drew 432 comments and the rest drew 87, 55 and 0. `hn-url.fish` sorts by comment count for
  exactly this reason — the first result is rarely the one you want.
- **Errors are `{"error":"Not Found","status":404}`** for a bad or deleted id. Deleted and dead
  items are simply absent from the index; `hn-item.fish` also skips tree nodes with no author or
  no text, which is what deletion looks like from inside a thread.
- **No rate-limit headers are returned**, so there is nothing to back off against. Prefer one
  request with a large `--limit` over a loop of small ones.
- If you ever need live front-page ordering or item fields Algolia omits, the official Firebase
  API (`hacker-news.firebaseio.com/v0/item/<id>.json`) is the fallback, but it has no search and
  needs one request per item. Algolia is the right tool for everything these scripts do.

## When citing Hacker News in design docs

Cite the comment, not the site, and link it. Format:

```
"pcwalton" on HN, "Why I'm Leaving Elm", 2020-04-09
https://news.ycombinator.com/item?id=22821447
```

**HN is evidence of what objections exist and how common they are — not evidence that they are
correct.** It is heavily selected for people with a grievance, a decade of it is stale, and a
confident comment about a compiler is still an anonymous comment about a compiler. Three rules:

1. **Separate the technical criticism from the social one.** Most "why I left X" threads mix a
   language complaint with a governance complaint. Only the first is design input.
2. **Check the date against the thing being criticised.** Elm threads from 2016 and from after
   0.19's native-module lockdown are describing different languages.
3. **Quote it as a report, not a fact** — "several commenters on HN reported X", not "X is true" —
   unless the code, the docs or a measurement confirms it. Same standard
   [`references/talks/README.md`](../../../references/talks/README.md) sets for talks: somebody's
   argument, cited so a decision sheet can say where a claim came from, and never normative.
