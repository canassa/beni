#!/usr/bin/env fish
# Retrieve a story with its whole comment tree, or a comment with its replies.
#
# Usage:
#   hn-item.fish <id> [--depth N] [--limit N] [--width N] [--grep PATTERN]
#                     [--top] [--json]
#
# Examples:
#   hn-item.fish 22821447                    # a story and every comment on it
#   hn-item.fish 22821447 --top              # top-level comments only
#   hn-item.fish 22821447 --grep 'type sys'  # only comments matching a pattern
#   hn-item.fish 9952100                     # a comment and its replies
#
# One request returns the entire tree, however deep — there is no paging.

source (status dirname)/_common.fish

argparse 'd/depth=' 'n/limit=' 'w/width=' 'g/grep=' 't/top' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -lt 1
    echo "usage: hn-item.fish <id> [options]"
    echo "  -d --depth N      stop at nesting depth N (top level is 1)"
    echo "  -t --top          same as --depth 1"
    echo "  -n --limit N      print at most N comments (default: all)"
    echo "  -w --width N      wrap text at N columns, 0 disables (default: 96)"
    echo "  -g --grep PATTERN case-insensitive regex; print only matching comments"
    echo "  -j --json         raw API response (the full nested tree)"
    echo
    echo "Ids come from hn-search.fish or hn-url.fish, or from a"
    echo "news.ycombinator.com/item?id=<id> link."
    exit 0
end

set -l id $argv[1]
if not string match -qr '^[0-9]+$' -- $id
    # Accept a pasted HN URL as well as a bare id.
    set -l from_url (string replace -rf '.*[?&]id=([0-9]+).*' '$1' -- $id)
    if test -n "$from_url"
        set id $from_url
    else
        _hn_die "'$id' is not an item id or an item URL"; exit 1
    end
end

set -l maxdepth -1
set -q _flag_depth; and set maxdepth $_flag_depth
set -q _flag_top; and set maxdepth 1

set -l width 96
set -q _flag_width; and set width $_flag_width

set -l json (_hn_get "items/$id" | string collect)
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

printf '%s' $json | _hn_jq 'item_header'

# Flatten the tree, optionally filter, optionally truncate, then render.
set -l filter "comments($maxdepth)"
if set -q _flag_grep
    set filter "$filter | select(.text | test(\$pat; \"i\"))"
end

set -l body (printf '%s' $json | jq -L (status dirname) -r --arg pat "$_flag_grep" --argjson w $width \
    "include \"hn\"; $filter | comment_block(\$w)" | string collect)

if test -z "$body"
    if set -q _flag_grep
        echo "# no comment matches /$_flag_grep/i"
    else
        echo "# no comments"
    end
    exit 0
end

# --limit counts comments, not lines; blocks are separated by a blank line.
if set -q _flag_limit
    set -l kept (printf '%s\n' $body | awk -v n=$_flag_limit '
        /^ *▸ / { c++ } c > n { exit } { print }')
    set -l total (printf '%s\n' $body | grep -c '^ *▸ ')
    printf '%s\n' $kept
    test $total -gt $_flag_limit; and echo "# showing $_flag_limit of $total comments — raise --limit for the rest"
else
    printf '%s\n' $body
end
