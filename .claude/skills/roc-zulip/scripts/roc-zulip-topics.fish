#!/usr/bin/env fish
# List topics in a Roc Zulip channel, newest activity first.
#
# Usage: roc-zulip-topics.fish <channel-name-or-id> [--grep PATTERN] [--limit N] [--json]

source (status dirname)/_common.fish

argparse 'g/grep=' 'l/limit=' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -lt 1
    echo "usage: roc-zulip-topics.fish <channel-name-or-id> [--grep PATTERN] [--limit N] [--json]"
    echo "example: roc-zulip-topics.fish 'compiler development' --grep incremental"
    exit 0
end

set -l channel $argv[1]
set -l stream_id (_rz_channel_id $channel)
or exit 1

set -l json (_rz_get users/me/$stream_id/topics | string collect)
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

# max_id ascends with recency, so sorting by it gives newest-first.
set -l lines (printf '%s' $json | jq -r '.topics | sort_by(-.max_id) | .[] | "\(.max_id)\t\(.name)"')

if set -q _flag_grep
    set lines (printf '%s\n' $lines | string match -ir -- ".*$_flag_grep.*")
end

if set -q _flag_limit
    set lines $lines[1..(math "min($_flag_limit, "(count $lines)")")]
end

echo "# $channel (id $stream_id) — "(count $lines)" topics, newest first"
echo "# last-msg-id  topic"
for l in $lines
    set -l id (string split -f1 \t -- $l)
    set -l name (string split -f2 \t -- $l)
    printf '%-12s %s\n' $id $name
end
