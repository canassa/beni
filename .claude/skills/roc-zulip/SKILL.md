---
name: roc-zulip
description: Query the Roc programming language's Zulip chat (roc.zulipchat.com) from the command line — list channels, browse topics, full-text search, read threads, and get citable permalinks. No login needed for public channels. Use when researching how Roc's compiler works or what its team decided and why, or whenever the user asks about Roc Zulip, roc-lang chat, or wants primary-source evidence from Roc's community discussions.
---

# Roc Zulip

Roc is a fast-compiling ML-family language whose compiler is written in **Zig** (it moved off
Rust). Its Zulip is the primary source for compiler design decisions that are documented nowhere
else — incremental compilation, the type solver, arena strategy, the Zig rewrite. For this repo
(a fast Elm-like → JS compiler in Zig) it is the closest thing to a peer project's engineering log.

## Access: no credentials required

Verified 2026-09-12. Anonymous reads work, but only under two exact conditions:

1. The path must be **`/json/...`** — `/api/v1/...` returns `401` without credentials, always.
2. The narrow must include **`{"operator":"channels","operand":"web-public"}`**.

No cookie, no CSRF header, no API key. The scripts handle both rules for you.

```bash
# the minimal working call, for reference
curl -sS -G 'https://roc.zulipchat.com/json/messages' \
  --data-urlencode 'anchor=newest' --data-urlencode 'num_before=5' --data-urlencode 'num_after=0' \
  --data-urlencode 'narrow=[{"operator":"channels","operand":"web-public"}]'
```

**Optional credentials.** Set `ZULIP_EMAIL` and `ZULIP_API_KEY` and every script switches to
`/api/v1` with basic auth and drops the web-public term, which also reaches private channels and
enables the real `/json/streams` channel listing. Get a key at Gear → Personal settings →
Account & privacy → Manage your API key. You do not need this for ordinary research.

## Scripts

All in `scripts/`, all fish, all take `--help`. They need only `curl` and `jq`.

| Script | Use |
|---|---|
| `roc-zulip-channels.fish [--sample N]` | List channels by recent activity |
| `roc-zulip-topics.fish <channel> [--grep P] [--limit N]` | List topics, newest first |
| `roc-zulip-search.fish <terms...> [--channel C] [--sender S] [--full]` | Full-text search |
| `roc-zulip-read.fish <channel> [--topic T] [--limit N] [--links]` | Read a thread |
| `roc-zulip-msg.fish <id> [--context N]` | One message + permalink, for citation |

Every script also takes `--json` to emit the raw API response for further `jq` work.

### Typical research flow

```fish
./scripts/roc-zulip-search.fish 'incremental compilation' --channel 'compiler development'
./scripts/roc-zulip-topics.fish 'compiler development' --grep incremental
./scripts/roc-zulip-read.fish 'compiler development' --topic 'casual conversation' --limit 100
./scripts/roc-zulip-msg.fish 585347163          # get a permalink to cite
```

Paging backwards through a long thread: `read` prints
`# older messages exist — continue with: --before <id>` when there is more.

## Channels

Discovered by sampling recent traffic, so this list covers active channels; quiet ones may be
missing. Re-run `roc-zulip-channels.fish` rather than trusting these ids forever.

| id | channel | relevance here |
|---|---|---|
| 395097 | **compiler development** | The main one. Incremental compilation, backends, LSP, the Zig rewrite. |
| 463735 | **performance** | Runtime and compile-time performance work. |
| 304641 | ideas | Language design proposals (Roc's documented idea → proposal → implementation path). |
| 316715 | contributing | Onboarding, build setup, codebase orientation. |
| 463736 | bugs | |
| 302903 | platform development | Roc's platform/host ABI. |
| 304902 | show and tell | |
| 231634 | beginners | |
| 397893 | announcements | Releases, milestones. |

## Facts worth knowing

- **Use `channel`/`channels`, not `stream`/`streams`,** in narrows. Roc's server is at Zulip
  feature level 511, well past the 9.0 rename. (Permalink *URLs* still use either.)
- **`apply_markdown=false`** returns raw Markdown instead of rendered HTML — the scripts always
  set this, which is what you want for terminal reading and quoting.
- **1000 messages max per request.** `found_oldest` in the response tells you whether more exist.
- **Timestamps are epoch seconds, UTC.** Scripts render them as `YYYY-MM-DD HH:MM`Z.
- **`/json/streams` needs auth** — that's why channel discovery works by aggregating
  `display_recipient` over recent messages instead.
- **`/json/users/me/<stream_id>/topics` works anonymously**, despite the `me` in the path.
- Rate limit is 100 requests per window per IP unauthenticated; the headers come back on every
  response (`x-ratelimit-remaining`). Batch with large `num_before` rather than looping.

## When citing Roc Zulip in design docs

Use a permalink from `roc-zulip-msg.fish`, and quote the speaker by name with the date. Format:

```
Richard Feldman, #compiler development › wasm memory, 2026-08-16
https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/wasm.20memory/near/616818382
```

Chat is not documentation: it is people thinking out loud, and a message may be speculation,
outdated, or later reversed. Prefer a later message over an earlier one on the same question, and
say "a Roc contributor said in chat" rather than "Roc does X" unless the code or docs confirm it.
