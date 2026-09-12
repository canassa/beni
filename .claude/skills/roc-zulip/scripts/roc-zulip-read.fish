#!/usr/bin/env fish
# Read messages from a Roc Zulip channel or topic, oldest-to-newest.
#
# Usage:
#   roc-zulip-read.fish <channel> [--topic TOPIC] [--limit N] [--before ID] [--links] [--json]
#
# Examples:
#   roc-zulip-read.fish 'compiler development' --limit 50
#   roc-zulip-read.fish ideas --topic 'pure apps'
#   roc-zulip-read.fish performance --limit 200 --links

source (status dirname)/_common.fish

argparse 't/topic=' 'l/limit=' 'b/before=' 'L/links' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -lt 1
    echo "usage: roc-zulip-read.fish <channel> [--topic TOPIC] [--limit N] [--before ID] [--links] [--json]"
    echo "  --limit N    messages to fetch, newest N (default 50, max 1000)"
    echo "  --before ID  page backwards: fetch messages older than this id"
    echo "  --links      print a permalink under each message"
    exit 0
end

set -l channel $argv[1]
set -l limit 50
set -q _flag_limit; and set limit $_flag_limit
test $limit -gt 1000; and set limit 1000

set -l terms (_rz_term_channel $channel)
if set -q _flag_topic
    set terms $terms (_rz_term_topic $_flag_topic)
end

set -l anchor newest
set -q _flag_before; and set anchor $_flag_before

set -l json (_rz_get messages \
    anchor=$anchor num_before=$limit num_after=0 apply_markdown=false \
    "narrow="(_rz_narrow $terms) | string collect)
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

set -l count (printf '%s' $json | jq '.messages | length')
if test $count -eq 0
    echo "roc-zulip: no messages found. Check the channel name with roc-zulip-channels.fish" >&2
    exit 1
end

set -l oldest (printf '%s' $json | jq -r '.messages[0].id')
set -l found_oldest (printf '%s' $json | jq -r '.found_oldest')

if set -q _flag_links
    printf '%s' $json | jq -r '.messages[] | [.stream_id, .display_recipient, .subject, (.id|tostring), .sender_full_name, ((.timestamp|gmtime|strftime("%Y-%m-%d %H:%M"))), .content] | @tsv' \
    | while read -l -d \t sid chan topic id sender ts content
        echo "── #$chan › $topic"
        echo "   $sender · "$ts"Z · id $id"
        echo "   "(_rz_link $sid $chan $topic $id)
        printf '%s\n\n' (string replace -a '\n' \n -- $content)
    end
else
    printf '%s' $json | jq -r $RZ_JQ_MSG
end

echo "# $count messages"(set -q _flag_topic; and echo " in topic '$_flag_topic'")" from #$channel"
if test "$found_oldest" != true
    echo "# older messages exist — continue with: --before $oldest"
end
