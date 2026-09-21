#!/usr/bin/env fish
# Find the Hacker News discussions of an article, given its URL.
#
# Usage:
#   hn-url.fish <article-url> [--limit N] [--all] [--json]
#
# Examples:
#   hn-url.fish https://lukeplant.me.uk/blog/posts/why-im-leaving-elm/
#   hn-url.fish overreacted.io/the-two-reacts/ --all
#
# Popular articles get submitted many times and nearly all of those attempts
# sink without a comment. Results are ordered by comment count so the thread
# that actually happened comes first; --all shows the dead ones too.

source (status dirname)/_common.fish

argparse 'n/limit=' 'a/all' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -lt 1
    echo "usage: hn-url.fish <article-url> [--limit N] [--all] [--json]"
    echo "  -n --limit N   submissions to consider (default: 50)"
    echo "  -a --all       include submissions with no comments"
    echo "  -j --json      raw API response"
    exit 0
end

set -l url $argv[1]
set -l limit 50
set -q _flag_limit; and set limit $_flag_limit

# Pass 1: match against the indexed url field, exactly as given.
set -l json (_hn_get search \
    "query=$url" \
    'restrictSearchableAttributes=url' \
    'tags=story' \
    "hitsPerPage=$limit" | string collect)
or exit 1

# Pass 2: if that found nothing, retry on the bare host+path. Submissions differ
# in scheme, www., trailing slash and utm_* parameters; the index keeps them
# verbatim, so the trimmed form matches more of them.
set -l bare (string replace -r '^https?://' '' -- $url | string replace -r '^www\.' '' | string replace -r '[?#].*$' '' | string replace -r '/$' '')
if test (printf '%s' $json | jq -r '.nbHits') -eq 0; and test "$bare" != "$url"
    echo "# no exact url match; retrying on $bare"
    set json (_hn_get search \
        "query=$bare" \
        'restrictSearchableAttributes=url' \
        'tags=story' \
        "hitsPerPage=$limit" | string collect)
    or exit 1
end

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

set -l keep '.hits'
set -q _flag_all; or set keep '[.hits[] | select((.num_comments // 0) > 0)]'

set -l total (printf '%s' $json | jq -r '.nbHits')
set -l shown (printf '%s' $json | jq -r "$keep | length")

echo "# $url — $total submissions, showing $shown, most-discussed first"
if test $shown -eq 0
    echo "# no discussion found."
    echo "# Try the bare host+path, or search the title instead: hn-search.fish '<title>'"
    exit 0
end
echo

printf '%s' $json | _hn_jq "$keep | sort_by(-(.num_comments // 0)) | .[] | story_line"

echo
set -l best (printf '%s' $json | jq -r "$keep | sort_by(-(.num_comments // 0)) | .[0].objectID")
echo "# read the main thread: hn-item.fish $best"
