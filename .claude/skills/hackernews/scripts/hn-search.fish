#!/usr/bin/env fish
# Search Hacker News stories or comments.
#
# Usage:
#   hn-search.fish <terms...> [--type story|comment|all] [--limit N] [--by-date]
#                             [--min-points N] [--min-comments N]
#                             [--after YYYY-MM-DD] [--before YYYY-MM-DD]
#                             [--author USER] [--story ID] [--in title|text|all]
#                             [--loose] [--json]
#
# Examples:
#   hn-search.fish 'the elm architecture' --type comment
#   hn-search.fish elm --min-points 100 --limit 30
#   hn-search.fish hydration --type comment --after 2023-01-01
#   hn-search.fish signals --story 43734911 --type comment
#
# The query is searched as an exact phrase by default — see --loose.

source (status dirname)/_common.fish

argparse 't/type=' 'n/limit=' 'd/by-date' 'p/min-points=' 'c/min-comments=' \
    'a/after=' 'b/before=' 'A/author=' 's/story=' 'i/in=' 'l/loose' 'j/json' 'h/help' -- $argv
or exit 1

# A bare query is the normal case, but --author or --story alone are valid too.
set -l no_query (test (count $argv) -eq 0; and not set -q _flag_author; and not set -q _flag_story; and echo yes)
if set -q _flag_help; or test -n "$no_query"
    echo "usage: hn-search.fish <terms...> [options]"
    echo "  -t --type story|comment|all   what to search (default: story)"
    echo "  -n --limit N                  hits to return, max $HN_MAX_HITS (default: 20)"
    echo "  -d --by-date                  newest first instead of most relevant"
    echo "  -p --min-points N             stories only"
    echo "  -c --min-comments N           stories only"
    echo "  -a --after / -b --before D    date window, YYYY-MM-DD"
    echo "  -A --author USER              only this user"
    echo "  -s --story ID                 only comments on this story"
    echo "  -i --in title|text|all        which fields to match (default: all)"
    echo "  -l --loose                    allow fuzzy matching (see note below)"
    echo "  -j --json                     raw API response"
    echo
    echo "By default the query is quoted into an exact phrase. Without that,"
    echo "Algolia's typo tolerance matches 'elm' against 'Elon' and any URL"
    echo "containing 'elm', which makes --by-date results largely noise."
    exit 0
end

# ---------------------------------------------------------------- build query

set -l type story
set -q _flag_type; and set type $_flag_type
switch $type
    case story comment all
    case '*'
        _hn_die "unknown --type '$type' (want story, comment or all)"; exit 1
end

set -l limit 20
set -q _flag_limit; and set limit $_flag_limit
if not string match -qr '^[0-9]+$' -- $limit
    _hn_die "--limit wants a number"; exit 1
end
test $limit -gt $HN_MAX_HITS; and set limit $HN_MAX_HITS
test $limit -lt 1; and set limit 1

set -l query (string join ' ' $argv)
set -q _flag_loose; or set query (_hn_phrase $query)

# tags: story / comment / both, plus optional author and story scoping
set -l tags
switch $type
    case story
        set tags story
    case comment
        set tags comment
    case all
        set tags '(story,comment)'
end
set -q _flag_author; and set tags $tags "author_$_flag_author"
if set -q _flag_story
    set tags $tags "story_$_flag_story"
    # story_<id> only ever matches comments; asking for stories too is a no-op.
    test $type = story; and echo "# note: --story implies comments; use --type comment"
end

# numericFilters
set -l nf
set -q _flag_min_points; and set nf $nf "points>$_flag_min_points"
set -q _flag_min_comments; and set nf $nf "num_comments>$_flag_min_comments"
if set -q _flag_after
    set -l e (_hn_epoch $_flag_after); or exit 1
    set nf $nf "created_at_i>$e"
end
if set -q _flag_before
    set -l e (_hn_epoch $_flag_before); or exit 1
    set nf $nf "created_at_i<$e"
end

# which fields to match in
set -l restrict
if set -q _flag_in
    switch $_flag_in
        # Valid attributes are title, url, author, story_text, comment_text.
        # story_title and text are NOT searchable and return an API error.
        case title
            set restrict 'restrictSearchableAttributes=title'
        case text
            set restrict 'restrictSearchableAttributes=comment_text,story_text'
        case all
        case '*'
            _hn_die "unknown --in '$_flag_in' (want title, text or all)"; exit 1
    end
end

set -l endpoint search
set -q _flag_by_date; and set endpoint search_by_date

# ------------------------------------------------------------------- request

set -l json (_hn_get $endpoint \
    "query=$query" \
    "tags="(string join ',' $tags) \
    "hitsPerPage=$limit" \
    (_hn_numeric $nf) \
    $restrict | string collect)
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

# -------------------------------------------------------------------- render

set -l total (printf '%s' $json | jq -r '.nbHits')
set -l shown (printf '%s' $json | jq -r '.hits | length')
set -l order (set -q _flag_by_date; and echo "newest first"; or echo "most relevant first")

# An author- or story-only search has no query text, so describe it instead.
set -l parts
test -n "$query"; and set parts $parts $query
set -q _flag_author; and set parts $parts "by $_flag_author"
set -q _flag_story; and set parts $parts "on story $_flag_story"
test (count $parts) -eq 0; and set parts everything

echo "# "(string join ' ' $parts)" — $total hits, showing $shown ($type, $order)"
test $total -gt $HN_MAX_HITS; and echo "# Algolia caps any result set at $HN_MAX_HITS; narrow with --after/--before to see past that."
echo

if test $shown -eq 0
    echo "# nothing matched. Try --loose, or fewer words — the query is an exact phrase by default."
    exit 0
end

printf '%s' $json | _hn_jq '.hits[] | hit_line'

echo
echo "# read a thread:  hn-item.fish <id>"
echo "# search within:  hn-search.fish <terms> --type comment --story <id>"
