#!/usr/bin/env fish
# Full-text search across Roc Zulip, newest first, one line per hit.
#
# Usage:
#   roc-zulip-search.fish <terms...> [--channel C] [--sender S] [--limit N] [--full] [--json]
#
# Examples:
#   roc-zulip-search.fish incremental compilation
#   roc-zulip-search.fish 'type inference' --channel 'compiler development'
#   roc-zulip-search.fish arena --channel performance --full

source (status dirname)/_common.fish

argparse 'c/channel=' 's/sender=' 'l/limit=' 'f/full' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -lt 1
    echo "usage: roc-zulip-search.fish <terms...> [--channel C] [--sender S] [--limit N] [--full] [--json]"
    echo "  --full   print whole messages instead of one-line excerpts"
    exit 0
end

set -l query (string join ' ' $argv)
set -l limit 40
set -q _flag_limit; and set limit $_flag_limit
test $limit -gt 1000; and set limit 1000

set -l terms (_rz_term_search $query)
set -q _flag_channel; and set terms $terms (_rz_term_channel $_flag_channel)
set -q _flag_sender; and set terms $terms (_rz_term_sender $_flag_sender)

set -l json (_rz_get messages \
    anchor=newest num_before=$limit num_after=0 apply_markdown=false \
    "narrow="(_rz_narrow $terms) | string collect)
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

set -l count (printf '%s' $json | jq '.messages | length')
echo "# \"$query\" — $count hits"(set -q _flag_channel; and echo " in #$_flag_channel")", newest last"

if test $count -eq 0
    echo "# nothing found. Anonymous search only covers web-public channels."
    exit 0
end

if set -q _flag_full
    printf '%s' $json | jq -r $RZ_JQ_MSG
else
    printf '%s' $json | jq -r $RZ_JQ_HIT
end

echo "# read a hit in context: roc-zulip-read.fish <channel> --topic '<topic>'"
echo "# permalink for a hit:   roc-zulip-msg.fish <id>"
