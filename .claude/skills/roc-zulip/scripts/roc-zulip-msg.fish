#!/usr/bin/env fish
# Show one message in full, with its permalink — use this to cite a source.
#
# Usage: roc-zulip-msg.fish <message-id> [--context N] [--json]

source (status dirname)/_common.fish

argparse 'c/context=' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -lt 1
    echo "usage: roc-zulip-msg.fish <message-id> [--context N] [--json]"
    echo "  --context N  also show N messages either side of it"
    exit 0
end

set -l id $argv[1]
set -l ctx 0
set -q _flag_context; and set ctx $_flag_context

set -l json
if test $ctx -gt 0
    # Anchor on the message and take N either side, within the same narrow.
    set json (_rz_get messages \
        anchor=$id num_before=$ctx num_after=$ctx apply_markdown=false \
        "narrow="(_rz_narrow) | string collect)
else
    set json (_rz_get messages \
        anchor=$id num_before=0 num_after=0 apply_markdown=false \
        "narrow="(_rz_narrow (_rz_term_id $id)) | string collect)
end
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

set -l count (printf '%s' $json | jq '.messages | length')
if test $count -eq 0
    echo "roc-zulip: message $id not found, or not in a web-public channel" >&2
    exit 1
end

printf '%s' $json | jq -r '.messages[] | [.stream_id, .display_recipient, .subject, (.id|tostring), .sender_full_name, ((.timestamp|gmtime|strftime("%Y-%m-%d %H:%M"))), .content] | @tsv' \
| while read -l -d \t sid chan topic mid sender ts content
    set -l marker '──'
    test "$mid" = "$id"; and set marker '►►'
    echo "$marker #$chan › $topic"
    echo "   $sender · "$ts"Z · id $mid"
    echo "   "(_rz_link $sid $chan $topic $mid)
    printf '%s\n\n' (string replace -a '\n' \n -- $content)
end
