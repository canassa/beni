## 2026-09-20 21:16 CEST — a `hackernews` skill: search and retrieve HN threads

**What I did**

- Read `references/talks/` end to end — both `notes.md` and both auto-caption `transcript.md`,
  about 85 000 words — after the owner asked for the talks in depth. No repo change from the
  reading itself; the argument and the beni-facing readings were already captured by the session
  that landed them.
- Built `.claude/skills/hackernews/`, modelled on `roc-zulip`: `SKILL.md` plus three fish scripts
  and two support files in `scripts/`.
  - `hn-search.fish` — full-text over stories or comments, with `--type`, `--by-date`,
    `--min-points`, `--min-comments`, `--after`/`--before`, `--author`, `--story`, `--in`,
    `--loose`, `--json`.
  - `hn-item.fish` — a story plus its entire comment tree, or a comment plus its replies, with
    `--depth`/`--top`, `--limit`, `--grep`, `--width`; accepts a pasted `item?id=` URL.
  - `hn-url.fish` — the HN discussion(s) of an article URL, ordered by comment count.
  - `_common.fish` (request, retry, error shapes, date→epoch, the exact-phrase rule) and `hn.jq`
    (HTML cleaning, wrapping, tree flattening, output formats).
- Registered it in CLAUDE.md's Skills paragraph, next to `roc-zulip`.
- Verified every flag and every error path against the live API, and fixed two bugs found that way:
  `--in title` sent a non-searchable attribute and errored, and an author- or story-only search
  printed an empty header.

**What I learned**

- **Algolia's typo tolerance makes an unquoted HN query useless.** `query=elm&tags=story` returns
  5 496 hits, matching `Elon` and any URL containing the letters; `query="elm"` returns 1 087 real
  ones. Relevance ranking hides this on `/search` and exposes it completely on `/search_by_date`,
  so a chronological search that looks like noise is a quoting bug. The scripts quote by default
  and `--loose` opts out. `restrictSearchableAttributes=title` is *not* a substitute — it still
  returns 75 479 hits, because the typo match happens inside the title too.
- Only `title`, `url`, `author`, `story_text` and `comment_text` are searchable. `story_title` is
  returned on every comment record but is not indexed, and naming it is an API error — returned and
  indexed are different sets.
- **Comments carry no score** (`points` is always null, because HN does not publish them), so no
  comment can honestly be described as highly upvoted. Any result set caps at 1 000 hits however
  you page, while `nbHits` still reports the true total; date windows are the only way past it.
- `/items/<id>` returns a whole nested tree in one request, at any size, and works on comment ids
  too — so reading a 432-comment thread is one call, not a crawl.
- A popular article has many submissions and almost all are dead: "Why I'm Leaving Elm" has four,
  drawing 432, 87, 55 and 0 comments. Sorting by comment count is what makes `hn-url.fish` useful
  rather than merely correct.
- Putting every regex in `hn.jq` and loading it with `jq -L` avoids the fish→JSON→jq triple
  escaping that `roc-zulip/scripts/_common.fish` carries a warning comment about.
